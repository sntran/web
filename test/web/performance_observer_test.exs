defmodule Web.PerformanceObserverTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Web.AsyncContext.Variable
  alias Web.DOMException
  alias Web.Performance
  alias Web.PerformanceObserver
  alias Web.PerformanceObserverEntryList
  alias Web.TypeError

  doctest Web.PerformanceObserver
  doctest Web.PerformanceObserverEntryList

  # The entries are the state of the test process.
  setup do
    Performance.clear_marks()
    Performance.clear_measures()
  end

  # An observer whose callback sends the names of its entries and its
  # options to the test.
  defp observer do
    test = self()

    PerformanceObserver.new(fn list, observer, options ->
      send(
        test,
        {:callback, observer, names(PerformanceObserverEntryList.get_entries(list)), options}
      )
    end)
  end

  # An observer whose callback waits for `:continue`. While it waits, the
  # next task waits in the mailbox of the callback process.
  defp waiting_observer do
    test = self()

    PerformanceObserver.new(fn list, _observer, options ->
      names = names(PerformanceObserverEntryList.get_entries(list))
      send(test, {:waiting, self(), names, options})

      receive do
        :continue -> :ok
      end
    end)
  end

  defp names(entries), do: Enum.map(entries, & &1.name)

  defp next_callback do
    assert_receive {:callback, _observer, names, options}, 5_000
    {names, options}
  end

  # Waits until the callback process did each task that it has, and the
  # server each message that it has.
  defp settle(%PerformanceObserver{address: server}) do
    %{runner: runner} = :sys.get_state(server)
    :sys.get_state(runner)
    :sys.get_state(server)
  end

  defp wait_for_stop(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  # Runs `fun` in a new process, and returns its result.
  defp in_process(fun) do
    task = Task.async(fun)
    Task.await(task)
  end

  # ---------------------------------------------------------------------------
  # The constructor and the static attribute
  # ---------------------------------------------------------------------------

  describe "new" do
    test "takes a function with 0 to 3 arguments" do
      for callback <- [fn -> :ok end, fn _list -> :ok end, fn _list, _obs -> :ok end] do
        assert %PerformanceObserver{} = PerformanceObserver.new(callback)
      end

      assert_raise TypeError, ~r/The callback must be a function with 0 to 3/, fn ->
        PerformanceObserver.new(fn _a, _b, _c, _d -> :ok end)
      end

      assert_raise TypeError, fn -> PerformanceObserver.new(:not_a_function) end
    end

    test "a callback with fewer arguments gets the first ones" do
      test = self()
      one = PerformanceObserver.new(fn list -> send(test, {:one, list}) end)
      two = PerformanceObserver.new(fn list, observer -> send(test, {:two, list, observer}) end)
      none = PerformanceObserver.new(fn -> send(test, :none) end)

      for observer <- [one, two, none], do: PerformanceObserver.observe(observer, type: "mark")
      mark = Performance.mark("a")

      assert_receive {:one, %PerformanceObserverEntryList{} = list}, 5_000
      assert PerformanceObserverEntryList.get_entries(list) == [mark]
      assert_receive {:two, %PerformanceObserverEntryList{}, ^two}, 5_000
      assert_receive :none, 5_000
    end

    test "supported_entry_types is in alphabetical order, and is the same each time" do
      types = PerformanceObserver.supported_entry_types()
      assert types == ["mark", "measure"]
      assert types == Enum.sort(Enum.uniq(types))
      assert PerformanceObserver.supported_entry_types() == types
    end
  end

  # ---------------------------------------------------------------------------
  # The callback
  # ---------------------------------------------------------------------------

  describe "the callback" do
    test "gets the entry list, the observer, and the options" do
      observer = observer()
      :ok = PerformanceObserver.observe(observer, entry_types: ["mark", "measure"])
      Performance.mark("mark1")

      assert_receive {:callback, ^observer, ["mark1"], options}, 5_000
      assert options == %{dropped_entries_count: 0}
    end

    test "runs in the callback process of the observer, not in the call of mark" do
      test = self()
      observer = PerformanceObserver.new(fn -> send(test, {:callback_process, self()}) end)
      PerformanceObserver.observe(observer, type: "mark")

      Performance.mark("a")
      assert_receive {:callback_process, pid}, 5_000
      assert pid != self()
      assert pid == :sys.get_state(observer.address).runner
    end

    test "only the first callback after observe has the dropped entries count" do
      observer = observer()
      PerformanceObserver.observe(observer, type: "mark")
      Performance.mark("a")
      assert next_callback() == {["a"], %{dropped_entries_count: 0}}

      Performance.mark("b")
      assert next_callback() == {["b"], %{}}

      # A new call of observe sets the flag again, also with the same type.
      PerformanceObserver.observe(observer, type: "mark")
      Performance.mark("c")
      assert next_callback() == {["c"], %{dropped_entries_count: 0}}
    end

    test "a task with no entry does not clear the dropped entries count" do
      observer = waiting_observer()
      PerformanceObserver.observe(observer, type: "mark")
      Performance.mark("a")
      assert_receive {:waiting, runner, ["a"], %{dropped_entries_count: 0}}, 5_000

      # The next task waits behind the callback. take_records takes its
      # entries, thus the task finds no entry, and no callback runs.
      PerformanceObserver.observe(observer, type: "mark")
      Performance.mark("b")
      assert names(PerformanceObserver.take_records(observer)) == ["b"]
      send(runner, :continue)
      settle(observer)
      refute_received {:waiting, _runner, _names, _options}

      # The next callback is the first after the call of observe.
      Performance.mark("c")
      assert_receive {:waiting, ^runner, ["c"], %{dropped_entries_count: 0}}, 5_000
      send(runner, :continue)
    end

    test "gets the entries in the sequence of their start times" do
      Performance.mark("late", start_time: 20.0)
      Performance.mark("early", start_time: 10.0)
      Performance.mark("same", start_time: 10.0)

      observer = observer()
      PerformanceObserver.observe(observer, type: "mark", buffered: true)
      assert {["early", "same", "late"], _options} = next_callback()
    end

    test "runs in the empty context of AsyncContext" do
      test = self()
      variable = Variable.new(name: "request")

      Variable.run(variable, "req-1", fn ->
        :ok = :logger.update_process_metadata(%{request_id: "req-1"})

        observer =
          PerformanceObserver.new(fn ->
            metadata =
              case :logger.get_process_metadata() do
                :undefined -> %{}
                metadata -> metadata
              end

            send(test, {:context, Variable.get(variable), metadata[:request_id]})
          end)

        PerformanceObserver.observe(observer, type: "mark")
        Performance.mark("a")
      end)

      assert_receive {:context, nil, nil}, 5_000
    end

    test "a callback that throws goes to the log, and the observer continues" do
      test = self()

      observer =
        PerformanceObserver.new(fn list ->
          case names(PerformanceObserverEntryList.get_entries(list)) do
            ["bad"] -> raise "the callback failed"
            names -> send(test, {:names, names})
          end
        end)

      PerformanceObserver.observe(observer, type: "mark")

      log =
        capture_log(fn ->
          Performance.mark("bad")
          settle(observer)
        end)

      assert log =~ "The callback of a PerformanceObserver failed."
      assert log =~ "the callback failed"

      Performance.mark("good")
      assert_receive {:names, ["good"]}, 5_000
    end

    test "can call each function of the observer" do
      test = self()

      observer =
        PerformanceObserver.new(fn list, observer ->
          case names(PerformanceObserverEntryList.get_entries(list)) do
            ["from test"] ->
              # The callback process is a new observed process.
              PerformanceObserver.observe(observer, type: "measure")
              Performance.measure("from callback")
              send(test, {:records, PerformanceObserver.take_records(observer)})
              Performance.measure("next")

            names ->
              send(test, {:names, names})
              PerformanceObserver.disconnect(observer)
          end
        end)

      PerformanceObserver.observe(observer, type: "mark")
      Performance.mark("from test")

      assert_receive {:records, [%Performance.Measure{name: "from callback"}]}, 5_000
      assert_receive {:names, ["next"]}, 5_000
    end

    test "a callback that makes an entry of the observed type runs again" do
      test = self()

      observer =
        PerformanceObserver.new(fn list, observer ->
          [entry] = PerformanceObserverEntryList.get_entries(list)
          send(test, {:entry, entry.name})

          if entry.name == "start" do
            PerformanceObserver.observe(observer, type: "mark")
          end

          if String.length(entry.name) < 8, do: Performance.mark(entry.name <> "!")
        end)

      PerformanceObserver.observe(observer, type: "mark")
      Performance.mark("start")

      for name <- ["start", "start!", "start!!"], do: assert_receive({:entry, ^name}, 5_000)
    end
  end

  # ---------------------------------------------------------------------------
  # observe
  # ---------------------------------------------------------------------------

  describe "observe" do
    test "with no options or with an empty list raises TypeError" do
      observer = observer()

      assert_raise TypeError, ~r/must have :entry_types or :type/, fn ->
        PerformanceObserver.observe(observer)
      end

      assert_raise TypeError, fn ->
        PerformanceObserver.observe(observer, entry_type: ["mark"])
      end

      assert_raise TypeError, fn -> PerformanceObserver.observe(observer, %{type: "mark"}) end
    end

    test "entry_types must be a list, and cannot have other options" do
      observer = observer()

      assert_raise TypeError, ~r/must be a list/, fn ->
        PerformanceObserver.observe(observer, entry_types: "mark")
      end

      assert_raise TypeError, ~r/cannot have other options/, fn ->
        PerformanceObserver.observe(observer, type: "mark", entry_types: ["measure"])
      end

      # A member that is present, also with the value false.
      assert_raise TypeError, fn ->
        PerformanceObserver.observe(observer, entry_types: ["mark"], buffered: false)
      end

      # A member with the value nil is not present.
      assert :ok = PerformanceObserver.observe(observer, entry_types: ["mark"], type: nil)
    end

    test "an observer observes with entry_types or with type, not with the two" do
      multiple = observer()
      PerformanceObserver.observe(multiple, entry_types: ["mark"])

      exception =
        assert_raise DOMException, fn ->
          PerformanceObserver.observe(multiple, type: "measure")
        end

      assert exception.name == "InvalidModificationError"

      single = observer()
      PerformanceObserver.observe(single, type: "mark")

      exception =
        assert_raise DOMException, fn ->
          PerformanceObserver.observe(single, entry_types: ["measure"])
        end

      assert exception.name == "InvalidModificationError"
    end

    test "the observer type of a call that aborts stays" do
      observer = observer()

      capture_log(fn -> PerformanceObserver.observe(observer, type: "resource") end)

      assert_raise DOMException, fn ->
        PerformanceObserver.observe(observer, entry_types: ["mark"])
      end
    end

    test "entry_types replaces the options of the call before" do
      observer = observer()
      PerformanceObserver.observe(observer, entry_types: ["mark"])
      PerformanceObserver.observe(observer, entry_types: ["measure"])
      Performance.mark("mark1")
      Performance.measure("measure1")

      assert {["measure1"], _options} = next_callback()
    end

    test "type adds its type to the types of the calls before" do
      observer = observer()
      PerformanceObserver.observe(observer, type: "mark")
      PerformanceObserver.observe(observer, type: "measure")
      Performance.mark("mark1")
      Performance.measure("measure1")

      assert names(PerformanceObserver.take_records(observer)) == ["mark1", "measure1"]
    end

    test "a second call with the same type takes the place of the first" do
      Performance.mark("early")
      observer = observer()
      PerformanceObserver.observe(observer, type: "mark")
      PerformanceObserver.observe(observer, type: "mark", buffered: true)

      assert {["early"], _options} = next_callback()

      %{registrations: registrations} = :sys.get_state(observer.address)
      assert [%{type: "mark", buffered: true}] = registrations[self()].options
    end

    test "with buffered gets the entries before the call, and later entries" do
      for i <- 1..3, do: Performance.mark("before #{i}")
      Performance.measure("measure before")

      observer = observer()
      PerformanceObserver.observe(observer, type: "mark", buffered: true)
      assert {["before 1", "before 2", "before 3"], _options} = next_callback()

      Performance.mark("after")
      assert {["after"], _options} = next_callback()
    end

    test "with buffered and no entry queues a task with no callback" do
      observer = observer()
      PerformanceObserver.observe(observer, type: "mark", buffered: true)
      settle(observer)
      refute_received {:callback, _observer, _names, _options}
      refute :sys.get_state(observer.address).task_queued
    end

    test "ignores an unsupported type, and writes a warning" do
      observer = observer()

      log =
        capture_log(fn ->
          PerformanceObserver.observe(observer, entry_types: ["mark", "resource"])
        end)

      assert log =~ ~s(ignores the entry types ["resource"])

      log =
        capture_log(fn ->
          assert :ok = PerformanceObserver.observe(observer, entry_types: ["navigation"])
        end)

      assert log =~ "does not observe"

      # The call with no supported type changed nothing: the options of
      # the call before stay.
      Performance.mark("a")
      assert {["a"], _options} = next_callback()
    end

    test "with an empty list or an unsupported type does not observe" do
      for options <- [[entry_types: []], [type: "marks"]] do
        observer = observer()

        log = capture_log(fn -> assert :ok = PerformanceObserver.observe(observer, options) end)
        assert log =~ "does not observe"

        assert :sys.get_state(observer.address).registrations == %{}
      end
    end

    test "converts atoms and numbers to the text of a type" do
      observer = observer()
      PerformanceObserver.observe(observer, entry_types: [:mark])
      Performance.mark("a")
      assert {["a"], _options} = next_callback()

      assert_raise TypeError, ~r/A name must be a string/, fn ->
        PerformanceObserver.observe(observer(), type: {:not, :text})
      end
    end

    test "observes the process that calls it" do
      observer = observer()
      test = self()

      pid =
        spawn(fn ->
          PerformanceObserver.observe(observer, type: "mark")
          send(test, :observed)

          receive do
            :mark -> Performance.mark("other process")
          end

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :observed, 5_000

      # The entry of the test process does not go to the observer.
      Performance.mark("test process")
      send(pid, :mark)
      assert {["other process"], _options} = next_callback()
      settle(observer)
      refute_received {:callback, _observer, _names, _options}
      send(pid, :stop)
    end

    test "an observer can observe two processes" do
      observer = observer()
      test = self()

      pids =
        for name <- ["first", "second"] do
          spawn(fn ->
            PerformanceObserver.observe(observer, type: "mark")
            send(test, {:observed, self()})

            receive do
              :mark -> Performance.mark(name)
            end

            send(test, {:marked, self()})
          end)
        end

      for pid <- pids, do: assert_receive({:observed, ^pid}, 5_000)
      for pid <- pids, do: send(pid, :mark)
      for pid <- pids, do: assert_receive({:marked, ^pid}, 5_000)

      names =
        Stream.repeatedly(&next_callback/0)
        |> Stream.flat_map(&elem(&1, 0))
        |> Enum.take(2)

      assert Enum.sort(names) == ["first", "second"]
    end

    test "a process lists an observer one time, and forgets an observer that stopped" do
      first = in_process(fn -> observer() end)
      wait_for_stop(first.address)
      second = observer()

      Process.put({Web.Internal.PerformanceObserver, :observers}, [
        {first.address, first.token}
      ])

      PerformanceObserver.observe(second, type: "mark")
      PerformanceObserver.observe(second, type: "measure")

      assert Process.get({Web.Internal.PerformanceObserver, :observers}) == [
               {second.address, second.token}
             ]
    end
  end

  # A pid of a node that is not connected.
  defp remote_pid do
    name = "remote@host"
    :erlang.binary_to_term(<<131, 88, 119, byte_size(name), name::binary, 1::32, 0::32, 1::32>>)
  end

  describe "an observer of a different node" do
    test "stays in the list of the process" do
      remote = {remote_pid(), make_ref()}
      Process.put({Web.Internal.PerformanceObserver, :observers}, [remote])
      local = observer()

      assert :ok = PerformanceObserver.observe(local, type: "mark")

      assert Process.get({Web.Internal.PerformanceObserver, :observers}) == [
               remote,
               {local.address, local.token}
             ]
    end
  end

  # ---------------------------------------------------------------------------
  # take_records and disconnect
  # ---------------------------------------------------------------------------

  describe "take_records" do
    test "returns the entries that no callback got, and empties the buffer" do
      observer = waiting_observer()
      assert PerformanceObserver.take_records(observer) == []
      PerformanceObserver.observe(observer, entry_types: ["mark"])
      assert PerformanceObserver.take_records(observer) == []

      Performance.mark("first")
      assert_receive {:waiting, runner, ["first"], _options}, 5_000

      # The callback waits: the next entries stay in the buffer.
      Performance.mark("b", start_time: 2.0)
      Performance.mark("a", start_time: 1.0)
      assert names(PerformanceObserver.take_records(observer)) == ["b", "a"]
      assert PerformanceObserver.take_records(observer) == []

      # The next task finds no entry: no callback.
      send(runner, :continue)
      settle(observer)
      refute_received {:waiting, _runner, _names, _options}
    end
  end

  describe "disconnect" do
    test "an observer that was not connected is no change" do
      observer = observer()
      assert :ok = PerformanceObserver.disconnect(observer)
      assert :ok = PerformanceObserver.disconnect(observer)

      # The observer still works.
      PerformanceObserver.observe(observer, type: "mark")
      Performance.mark("a")
      assert {["a"], _options} = next_callback()
    end

    test "drops the entries before it, and no callback gets them" do
      observer = observer()
      PerformanceObserver.observe(observer, entry_types: ["mark", "measure"])
      %{runner: runner} = :sys.get_state(observer.address)
      true = :erlang.suspend_process(runner)

      # The task waits in the mailbox of the callback process.
      Performance.mark("before disconnect")
      PerformanceObserver.disconnect(observer)
      assert PerformanceObserver.take_records(observer) == []
      Performance.mark("after disconnect")

      :erlang.resume_process(runner)
      settle(observer)
      refute_received {:callback, _observer, _names, _options}
    end

    test "entries before it are not delivered after a new observe" do
      observer = observer()
      PerformanceObserver.observe(observer, entry_types: ["mark"])
      %{runner: runner} = :sys.get_state(observer.address)
      true = :erlang.suspend_process(runner)

      Performance.mark("before disconnect")
      PerformanceObserver.disconnect(observer)
      PerformanceObserver.observe(observer, entry_types: ["mark"])
      Performance.mark("after observe")

      true = :erlang.resume_process(runner)
      assert {["after observe"], _options} = next_callback()
    end

    test "forgets the types of the calls before it" do
      observer = observer()
      PerformanceObserver.observe(observer, type: "mark")
      PerformanceObserver.disconnect(observer)
      PerformanceObserver.observe(observer, type: "measure")
      Performance.mark("a")
      Performance.measure("b")

      assert {["b"], _options} = next_callback()
    end

    test "from a different process stops the entries of each process" do
      observer = observer()
      PerformanceObserver.observe(observer, type: "mark")
      in_process(fn -> PerformanceObserver.disconnect(observer) end)

      # The test process still lists the observer. The server drops the
      # entry, because the process has no options.
      assert [{_pid, _token}] = Process.get({Web.Internal.PerformanceObserver, :observers})
      Performance.mark("a")
      settle(observer)
      refute_received {:callback, _observer, _names, _options}
      assert PerformanceObserver.take_records(observer) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Lifetime
  # ---------------------------------------------------------------------------

  describe "lifetime" do
    test "the observer stops with its owner" do
      {observer, runner} =
        in_process(fn ->
          observer = observer()
          {observer, :sys.get_state(observer.address).runner}
        end)

      wait_for_stop(observer.address)
      wait_for_stop(runner)

      # The functions have no effect.
      assert :ok = PerformanceObserver.observe(observer, type: "mark")
      assert :ok = PerformanceObserver.disconnect(observer)
      assert PerformanceObserver.take_records(observer) == []
      Performance.mark("a")
    end

    test "a task that did not start does not run after the stop of the owner" do
      test = self()

      owner =
        spawn(fn ->
          send(test, {:observer, PerformanceObserver.new(fn -> send(test, :ran) end)})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:observer, observer}, 5_000
      %{runner: runner} = :sys.get_state(observer.address)
      PerformanceObserver.observe(observer, type: "mark")
      true = :erlang.suspend_process(runner)

      # The task waits in the mailbox of the callback process.
      Performance.mark("a")
      assert %{task_queued: true} = :sys.get_state(observer.address)

      send(owner, :stop)
      wait_for_stop(observer.address)
      true = :erlang.resume_process(runner)
      wait_for_stop(runner)
      refute_received :ran
    end

    test "the entries of an observed process that stopped stay" do
      observer = waiting_observer()

      in_process(fn ->
        PerformanceObserver.observe(observer, type: "mark")
        Performance.mark("first")
      end)

      assert_receive {:waiting, runner, ["first"], _options}, 5_000

      pid =
        spawn(fn ->
          PerformanceObserver.observe(observer, type: "mark")
          Performance.mark("last words")
        end)

      wait_for_stop(pid)
      wait_until(fn -> not Map.has_key?(:sys.get_state(observer.address).registrations, pid) end)

      send(runner, :continue)
      assert_receive {:waiting, runner, ["last words"], _options}, 5_000
      send(runner, :continue)
    end

    test "a handle with a token that is not correct has no effect" do
      observer = observer()
      PerformanceObserver.observe(observer, type: "mark")
      forged = %PerformanceObserver{address: observer.address, token: make_ref()}

      assert :ok = PerformanceObserver.observe(forged, type: "measure")
      assert PerformanceObserver.take_records(forged) == []
      assert :ok = PerformanceObserver.disconnect(forged)

      # An entry with the wrong token, and a message with no meaning.
      send(observer.address, {:queue_entry, make_ref(), self(), Performance.Mark.new("x")})
      send(observer.address, :unknown)

      Performance.mark("a")
      assert {["a"], _options} = next_callback()
      assert [%{type: "mark"}] = :sys.get_state(observer.address).registrations[self()].options
    end
  end

  # Examines a condition of a different process until it is true.
  defp wait_until(condition, attempts \\ 500) do
    cond do
      condition.() ->
        :ok

      attempts > 0 ->
        Process.sleep(1)
        wait_until(condition, attempts - 1)

      true ->
        flunk("the condition did not become true")
    end
  end

  # ---------------------------------------------------------------------------
  # The entry list
  # ---------------------------------------------------------------------------

  defp entry do
    gen all(
          type <- member_of([:mark, :measure]),
          name <- member_of(["a", "b", "c"]),
          start <- integer(0..5)
        ) do
      case type do
        :mark -> Performance.Mark.new(name, start_time: start * 1.0)
        :measure -> %Performance.Measure{name: name, start_time: start * 1.0, duration: 1.0}
      end
    end
  end

  describe "PerformanceObserverEntryList" do
    property "filters by name and type, and sorts by the start time with a stable sort" do
      check all(entries <- list_of(entry(), max_length: 12)) do
        list = %PerformanceObserverEntryList{entries: entries}
        # The position of each entry in the list breaks a tie.
        sorted = entries |> Enum.with_index() |> Enum.sort_by(fn {e, i} -> {e.start_time, i} end)
        sorted = Enum.map(sorted, &elem(&1, 0))

        assert PerformanceObserverEntryList.get_entries(list) == sorted

        for type <- ["mark", "measure"], name <- ["a", "b", "c"] do
          assert PerformanceObserverEntryList.get_entries_by_type(list, type) ==
                   Enum.filter(sorted, &(&1.entry_type == type))

          assert PerformanceObserverEntryList.get_entries_by_name(list, name) ==
                   Enum.filter(sorted, &(&1.name == name))

          assert PerformanceObserverEntryList.get_entries_by_name(list, name, type) ==
                   Enum.filter(sorted, &(&1.name == name and &1.entry_type == type))
        end
      end
    end

    test "converts an atom to the text of a name or a type" do
      mark = Performance.Mark.new("a")
      list = %PerformanceObserverEntryList{entries: [mark]}

      assert PerformanceObserverEntryList.get_entries_by_type(list, :mark) == [mark]
      assert PerformanceObserverEntryList.get_entries_by_name(list, :a, :mark) == [mark]

      assert_raise TypeError, fn ->
        PerformanceObserverEntryList.get_entries_by_name(list, [1])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The dictionary PerformanceObserverInit
  # ---------------------------------------------------------------------------

  # A value of a member: not there, nil (not present), or a value.
  defp init do
    gen all(
          entry_types <-
            one_of([
              constant(:absent),
              constant(nil),
              list_of(member_of(["mark", "measure", "x"]), max_length: 3)
            ]),
          type <- one_of([constant(:absent), constant(nil), member_of(["mark", "measure", "x"])]),
          buffered <- one_of([constant(:absent), constant(nil), boolean()])
        ) do
      [entry_types: entry_types, type: type, buffered: buffered]
      |> Enum.reject(fn {_key, value} -> value == :absent end)
    end
  end

  # The steps 2 to 4 of observe(options): the result of each call, and the
  # observer type after it.
  defp expected(options, observer_type) do
    present = for {key, value} <- options, value != nil, do: key

    case options_kind(present) do
      :type_error -> {:type_error, observer_type}
      kind -> observer_type(kind, observer_type)
    end
  end

  # The steps 2 and 3.
  defp options_kind(present) do
    cond do
      :entry_types in present and length(present) > 1 -> :type_error
      :entry_types in present -> :multiple
      :type in present -> :single
      true -> :type_error
    end
  end

  # The step 4.
  defp observer_type(kind, :undefined), do: {:ok, kind}
  defp observer_type(kind, kind), do: {:ok, kind}
  defp observer_type(_kind, observer_type), do: {:invalid, observer_type}

  property "observe checks its options as the steps of the Standard" do
    check all(calls <- list_of(init(), min_length: 1, max_length: 4), max_runs: 60) do
      observer = PerformanceObserver.new(fn -> :ok end)

      Enum.reduce(calls, :undefined, fn options, observer_type ->
        {result, observer_type} = expected(options, observer_type)

        case result do
          :type_error ->
            assert_raise TypeError, fn -> PerformanceObserver.observe(observer, options) end

          :invalid ->
            exception =
              assert_raise DOMException, fn -> PerformanceObserver.observe(observer, options) end

            assert exception.name == "InvalidModificationError"

          :ok ->
            capture_log(fn -> assert :ok = PerformanceObserver.observe(observer, options) end)
        end

        assert :sys.get_state(observer.address).observer_type == observer_type
        observer_type
      end)
    end
  end
end
