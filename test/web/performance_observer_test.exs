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

  # The test process is a global object: the entries are its state.
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

  # The first message of the mailbox, with no pattern.
  defp next_message do
    receive do
      message -> message
    after
      5_000 -> flunk("no message")
    end
  end

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

  # The options list of the registered performance observer of an observer.
  defp options(%PerformanceObserver{address: server, token: token}) do
    {^token, options} = List.keyfind(:sys.get_state(server).registered, token, 0)
    options
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

    test "the dropped entries count is 0: mark and measure have no buffer limit" do
      # The registry gives other types a limit of 150 or 250 entries.
      for i <- 1..1_000, do: Performance.mark("before #{i}", start_time: i * 1.0)
      observer = observer()
      for i <- 1..1_000, do: Performance.measure("after #{i}", start: 0, end: i)

      # One task takes the entries of the two calls.
      %{runner: runner} = :sys.get_state(observer.address)
      true = :erlang.suspend_process(runner)
      PerformanceObserver.observe(observer, type: "mark", buffered: true)
      PerformanceObserver.observe(observer, type: "measure", buffered: true)
      true = :erlang.resume_process(runner)

      assert {names, %{dropped_entries_count: 0}} = next_callback()
      assert length(names) == 2_000
      assert length(Performance.get_entries()) == 2_000
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
              # The callback acts for the global object of the observer.
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

      assert [%{type: "mark", buffered: true}] = options(observer)
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

        assert :sys.get_state(observer.address).registered == []
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

    test "from a different process registers the observer in its global object" do
      # The mark goes to the server with the observer: no message from the
      # test process can come after the call of the other process.
      Performance.mark("before", start_time: 1.0)
      observer = observer()

      # The other process is a different global object. The buffered
      # entries are the entries of the global object of the observer.
      in_process(fn ->
        Performance.mark("other process", start_time: 2.0)
        PerformanceObserver.observe(observer, type: "mark", buffered: true)
        Performance.mark("other process again")
      end)

      assert {["before"], _options} = next_callback()
      Performance.mark("after")
      assert {["after"], _options} = next_callback()
      settle(observer)
      refute_received {:callback, _observer, _names, _options}
    end

    test "observes only its global object" do
      observer = observer()
      PerformanceObserver.observe(observer, type: "mark")
      in_process(fn -> Performance.mark("other process") end)
      Performance.mark("test process")

      assert {["test process"], _options} = next_callback()
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

    test "from a different process stops the observation" do
      observer = observer()
      PerformanceObserver.observe(observer, type: "mark")
      in_process(fn -> PerformanceObserver.disconnect(observer) end)

      Performance.mark("a")
      settle(observer)
      refute_received {:callback, _observer, _names, _options}
      assert PerformanceObserver.take_records(observer) == []
      assert :sys.get_state(observer.address).registered == []
    end
  end

  # ---------------------------------------------------------------------------
  # Lifetime
  # ---------------------------------------------------------------------------

  describe "lifetime" do
    test "the observer stops with its global object" do
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

    test "a task that did not start does not run after the stop of the global object" do
      test = self()

      global =
        spawn(fn ->
          observer = PerformanceObserver.new(fn -> send(test, :ran) end)
          PerformanceObserver.observe(observer, type: "mark")
          send(test, {:observer, observer})

          receive do
            :mark -> Performance.mark("a")
          end

          send(test, :marked)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:observer, observer}, 5_000
      %{runner: runner} = :sys.get_state(observer.address)
      true = :erlang.suspend_process(runner)

      # The task waits in the mailbox of the callback process.
      send(global, :mark)
      assert_receive :marked, 5_000
      assert %{task_queued: true} = :sys.get_state(observer.address)

      send(global, :stop)
      wait_for_stop(observer.address)
      true = :erlang.resume_process(runner)
      wait_for_stop(runner)
      refute_received :ran
    end

    test "a callback that runs after the stop of its global object completes" do
      test = self()

      callback = fn list, _observer ->
        send(test, {:waiting, self(), names(PerformanceObserverEntryList.get_entries(list))})

        receive do
          :continue -> :ok
        end

        # The timeline stopped with its global object: no effect, and a read
        # gives no entry.
        Performance.mark("too late")
        :ok = Performance.clear_marks("last")

        measure =
          try do
            Performance.measure("too late", "last")
          rescue
            error in DOMException -> error.name
          end

        send(test, {:entries, Performance.get_entries(), measure})
      end

      global =
        spawn(fn ->
          observer = PerformanceObserver.new(callback)
          PerformanceObserver.observe(observer, type: "mark")
          Performance.mark("last")
          send(test, {:observer, observer})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:observer, observer}, 5_000
      assert_receive {:waiting, runner, ["last"]}, 5_000
      send(global, :stop)
      wait_for_stop(observer.address)

      send(runner, :continue)
      assert_receive {:entries, [], "SyntaxError"}, 5_000
      wait_for_stop(runner)
    end

    test "a handle with a token that is not correct has no effect" do
      observer = observer()
      PerformanceObserver.observe(observer, type: "mark")
      forged = %PerformanceObserver{address: observer.address, token: make_ref()}

      assert :ok = PerformanceObserver.observe(forged, type: "measure")
      assert PerformanceObserver.take_records(forged) == []
      assert :ok = PerformanceObserver.disconnect(forged)

      # A message with no meaning.
      send(observer.address, :unknown)

      Performance.mark("a")
      assert {["a"], _options} = next_callback()
      assert [%{type: "mark"}] = options(observer)
    end
  end

  # ---------------------------------------------------------------------------
  # The global object
  # ---------------------------------------------------------------------------

  describe "the global object" do
    test "a mark of the callback is an entry of the global object of the observer" do
      test = self()

      observer =
        PerformanceObserver.new(fn list ->
          names = names(PerformanceObserverEntryList.get_entries(list))
          send(test, {:names, names})
          if names == ["from test"], do: Performance.mark("from callback")
        end)

      PerformanceObserver.observe(observer, type: "mark")
      Performance.mark("from test")

      # The observer gets the entry of the callback, and the test process
      # has it.
      assert_receive {:names, ["from test"]}, 5_000
      assert_receive {:names, ["from callback"]}, 5_000
      assert names(Performance.get_entries()) == ["from test", "from callback"]
    end

    test "the functions of Performance in the callback act on the timeline of the global object" do
      test = self()

      observer =
        PerformanceObserver.new(fn ->
          before = names(Performance.get_entries())
          measure = Performance.measure("in callback", "start")
          Performance.clear_marks("start")

          send(test, {
            :callback,
            before,
            measure.start_time,
            names(Performance.get_entries_by_type("mark")),
            names(Performance.get_entries_by_name("in callback", "measure")),
            Performance.now()
          })
        end)

      Performance.mark("start", start_time: 5.0)
      PerformanceObserver.observe(observer, type: "mark")
      Performance.mark("other", start_time: 6.0)

      assert_receive {:callback, ["start", "other"], 5.0, ["other"], ["in callback"], now},
                     5_000

      # The time origin is the same for each global object.
      assert now <= Performance.now()
      assert names(Performance.get_entries()) == ["in callback", "other"]
    end

    test "an observer that the callback makes belongs to the global object" do
      test = self()

      first =
        PerformanceObserver.new(fn list, first ->
          names = names(PerformanceObserverEntryList.get_entries(list))

          if names == ["foo"] do
            second = PerformanceObserver.new(fn list -> send(test, {:second, list}) end)
            PerformanceObserver.observe(second, type: "mark", buffered: true)
            PerformanceObserver.disconnect(first)
          end
        end)

      PerformanceObserver.observe(first, entry_types: ["mark"])
      Performance.mark("foo")
      assert_receive {:second, list}, 5_000
      assert names(PerformanceObserverEntryList.get_entries(list)) == ["foo"]

      Performance.mark("bar")
      assert_receive {:second, list}, 5_000
      assert names(PerformanceObserverEntryList.get_entries(list)) == ["bar"]
    end

    test "the callbacks of a task run in the sequence of the registrations" do
      test = self()

      [first, second] =
        for name <- [:first, :second] do
          PerformanceObserver.new(fn list ->
            send(test, {name, names(PerformanceObserverEntryList.get_entries(list))})
          end)
        end

      PerformanceObserver.observe(second, type: "mark")
      PerformanceObserver.observe(first, type: "mark")
      %{runner: runner} = :sys.get_state(first.address)
      true = :erlang.suspend_process(runner)
      Performance.mark("a")
      true = :erlang.resume_process(runner)

      # The callbacks run in the same process: their messages come in the
      # sequence of the callbacks.
      assert [next_message(), next_message()] == [{:second, ["a"]}, {:first, ["a"]}]
    end

    test "the callback process has no task in its mailbox while a callback runs" do
      observer = waiting_observer()
      PerformanceObserver.observe(observer, type: "mark")
      Performance.mark("a")
      assert_receive {:waiting, runner, ["a"], _options}, 5_000

      # The flag goes up, and the task waits in the server.
      Performance.mark("b")
      assert %{task_queued: true, task_running: true} = :sys.get_state(observer.address)
      assert Process.info(runner, :message_queue_len) == {:message_queue_len, 0}

      send(runner, :continue)
      assert_receive {:waiting, ^runner, ["b"], _options}, 5_000
      send(runner, :continue)
    end

    test "the reads and the writes of the timeline need no answer of the server" do
      observer = observer()
      true = :erlang.suspend_process(observer.address)

      try do
        Performance.mark("start", start_time: 1.0)
        assert Performance.measure("from start", "start").start_time == 1.0
        assert names(Performance.get_entries()) == ["start", "from start"]
        assert names(Performance.get_entries_by_name("start", "mark")) == ["start"]
        assert :ok = Performance.clear_marks("start")
        assert names(Performance.get_entries_by_type("mark")) == []
      after
        true = :erlang.resume_process(observer.address)
      end
    end

    test "an entry gets to an observer one time, also when observe comes before its queue step" do
      observer = observer()
      %{table: table, runner: runner} = :sys.get_state(observer.address)
      true = :erlang.suspend_process(runner)

      # A different process wrote the entry to the table. Its message to
      # the server is on its way.
      writer = spawn(fn -> :ok end)
      mark = Performance.Mark.new("on its way", start_time: 1.0)
      key = :erlang.unique_integer([:monotonic])
      true = :ets.insert(table, {key, mark, writer})

      # The buffered entries are the entries after their queue step.
      PerformanceObserver.observe(observer, type: "mark", buffered: true)
      assert PerformanceObserver.take_records(observer) == []

      # The queue step gives the entry to the observer.
      GenServer.cast(observer.address, {:queue, writer, key, mark})
      assert PerformanceObserver.take_records(observer) == [mark]
      assert %{queued: %{^writer => ^key}} = :sys.get_state(observer.address)
      true = :erlang.resume_process(runner)
    end

    test "the first observer keeps the earlier entries of the process" do
      Performance.mark("early", start_time: 1.0)
      Performance.measure("measure", start: 0.5, end: 1.5)

      observer = observer()
      assert names(Performance.get_entries()) == ["measure", "early"]
      assert Performance.measure("from early", "early").start_time == 1.0

      PerformanceObserver.observe(observer, type: "mark", buffered: true)
      assert {["early"], _options} = next_callback()
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

        assert :sys.get_state(observer.address).observers[observer.token].observer_type ==
                 observer_type

        observer_type
      end)
    end
  end
end
