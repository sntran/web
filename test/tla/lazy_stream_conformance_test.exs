defmodule Web.TLA.LazyStreamConformanceTest do
  # Compares the copies of a real `Web.Internal.LazyStream` with the
  # specification `tla/LazyStream.tla`.
  #
  # The first property makes a random list of commands. Each operation is
  # an operation of a new copy in a new process, as in the specification. A
  # copy that got the stream process keeps it: a later command reads it, or
  # stops the copy. A command can also kill the stream process. The test does
  # each command on the real copies and on the specification, and it
  # compares the results and the two states. A second property does the
  # same with the array on a second node.
  #
  # The tests of "a copy that stops during a stream read" stop a copy, its
  # starter, or the stream process at each step of a stream read, at a known
  # time. An abort signal holds a call of a step and tells it to the test:
  # the real code asks the signal before the start of the stream process,
  # and the stream process asks it during its start, after it registered
  # itself. The next copy must get the bytes. Other tests of that group: a
  # copy that got the process keeps it after a stop of its owner, a copy
  # that disturbed the process takes the bytes before a stop, and a start
  # of a stream process after a start that continued with no starter ends
  # with no crash report.
  #
  # The last property lets three processes do an operation on their copies
  # at the same time. The test cannot control the steps of the processes,
  # thus it checks the properties of the specification on the results.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Web.AbortSignal
  alias Web.Internal.LazyStream
  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultReader
  alias Web.Test.SpecModel
  alias Web.Uint8Array

  @operations [:take, :take_chunks, :cancel, :tee, :proxy, :process, :read, :state]

  # The values of the cell: see `Web.Internal.LazyStream`.
  @cell %{
    0 => "readable",
    1 => "consumed",
    2 => "canceled",
    3 => "locked",
    4 => "starting",
    5 => "process",
    6 => "starting_closed",
    7 => "taken"
  }

  # The model of the random commands has one copy for each operation.
  @names Enum.map(1..8, &"c#{&1}")
  @all_ops {~s(Ops = {"consumed", "canceled", "locked", "read"}),
            ~s(Ops = {"consumed", "canceled", "locked", "read", "state"})}
  @model_config [
    {~s(Copies = {"a", "b"}), "Copies = {#{Enum.map_join(@names, ", ", &inspect/1)}}"},
    {"Kills = 1", "Kills = 20"},
    {"StreamKills = 0", "StreamKills = 20"},
    @all_ops
  ]

  # The model of the tests of a stop: a process can kill a starter or a
  # stream process one time.
  @stop_config [{"StreamKills = 0", "StreamKills = 1"}]

  # The operation of the specification for each operation of the test.
  @spec_operation %{
    take: "locked",
    take_chunks: "consumed",
    cancel: "canceled",
    tee: "locked",
    proxy: "locked",
    process: "read",
    read: "read",
    state: "state"
  }

  defp command do
    frequency([
      {8, tuple({constant(:operation), member_of(@operations)})},
      {2, constant(:read_held)},
      {2, constant(:stop_holder)},
      {1, constant(:kill_stream)}
    ])
  end

  property "the copies do each operation as the specification permits" do
    check all(commands <- list_of(command(), max_length: 8), max_runs: 150) do
      run_commands(commands, LazyStream.new({:bytes, "hello"}, nil), node())
    end
  end

  describe "with the array on a second node" do
    @describetag :cluster

    # The node stops when the process of the test stops.
    setup do
      {_peer, node} = Web.TestCluster.start_peer()
      %{node: node}
    end

    property "the copies do each operation as the specification permits", %{node: node} do
      check all(commands <- list_of(command(), max_length: 8), max_runs: 30) do
        # An agent on the second node keeps one copy there. Thus the VM
        # keeps the array.
        {:ok, agent} =
          :erpc.call(node, Agent, :start, [LazyStream, :new, [{:bytes, "hello"}, nil]])

        lazy = :erpc.call(node, Agent, :get, [agent, Function, :identity, []])
        assert node(lazy.ref) == node

        try do
          run_commands(commands, lazy, node)
        after
          :erpc.call(node, Agent, :stop, [agent])
        end
      end
    end
  end

  # The copies are on this node. The array is on `node`.
  defp run_commands(commands, lazy, node) do
    system = %{lazy: lazy, node: node, copies: %{}, holders: [], given: 0}
    model = SpecModel.start("LazyStream", @model_config)

    try do
      Enum.reduce(commands, {model, system}, fn command, {model, system} ->
        {model, system} = run(command, model, system)
        assert_same_state(model, system)
        {model, system}
      end)
    after
      Enum.each(system.copies, fn {_name, pid} -> Process.exit(pid, :kill) end)
    end
  end

  # A function on the node of the array.
  defp on_node(%{node: node}, module, function, args) when node == node(),
    do: apply(module, function, args)

  defp on_node(%{node: node}, module, function, args),
    do: :erpc.call(node, module, function, args)

  # ---------------------------------------------------------------------------
  # The real copies
  # ---------------------------------------------------------------------------

  # A process with a copy of the struct. It does its operation, and then it
  # keeps the stream process that it got, and its reader, until it stops.
  defp start_copy(lazy, operation) do
    test = self()

    spawn(fn ->
      result = operate(operation, lazy)
      send(test, {:result, self(), result})
      held_loop(test, result)
    end)
  end

  defp held_loop(test, result) do
    receive do
      :read ->
        {:ok, pid} = result
        send(test, {:result, self(), read(%ReadableStream{controller_pid: pid})})
        held_loop(test, result)
    end
  end

  defp operate(:take, lazy), do: LazyStream.take(lazy)
  defp operate(:take_chunks, lazy), do: LazyStream.take_chunks(lazy)
  defp operate(:tee, lazy), do: LazyStream.tee(lazy)
  defp operate(:proxy, lazy), do: LazyStream.proxy(lazy)
  defp operate(:process, lazy), do: LazyStream.process(lazy, self())
  defp operate(:state, lazy), do: LazyStream.state(lazy)
  defp operate(:read, lazy), do: read(%ReadableStream{lazy: lazy})

  # A cancel of a stream process cancels that process, as
  # `ReadableStream.cancel/1` does.
  defp operate(:cancel, lazy) do
    case LazyStream.cancel(lazy) do
      {:process, pid} -> await(ReadableStream.cancel(%ReadableStream{controller_pid: pid}))
      result -> result
    end
  end

  # A stream read: a reader, and all the chunks. The copy keeps the lock.
  defp read(stream) do
    reader = ReadableStream.get_reader(stream)
    read_all(reader)
  rescue
    error in Web.TypeError -> {:raised, error.message}
  end

  defp read_all(reader) do
    case Web.await(ReadableStreamDefaultReader.read(reader)) do
      %{done: true} -> []
      %{value: chunk} -> [Uint8Array.to_binary(chunk) | read_all(reader)]
    end
  end

  defp await(promise) do
    Web.await(promise)
  catch
    :exit, %Web.TypeError{message: message} -> {:raised, message}
  end

  defp receive_result(pid) do
    receive do
      {:result, ^pid, result} -> result
    after
      2_000 -> flunk("the copy #{inspect(pid)} gave no result")
    end
  end

  # ---------------------------------------------------------------------------
  # One command, on the real copies and on the specification
  # ---------------------------------------------------------------------------

  # Each operation is the operation of a new copy.
  defp run({:operation, operation}, model, system) do
    case Enum.find(@names, &(not Map.has_key?(system.copies, &1))) do
      nil ->
        {model, system}

      name ->
        pid = start_copy(system.lazy, operation)
        result = receive_result(pid)
        system = %{system | copies: Map.put(system.copies, name, pid)}
        model = model |> SpecModel.step!("Begin", [name, @spec_operation[operation]])
        model = settle(model, name, operation)
        check_result(model, name, operation, result)
        {model, system |> record_holder(name, model) |> record_bytes(result)}
    end
  end

  # The last copy that got the stream process reads it.
  defp run(:read_held, model, system) do
    case system.holders do
      [] ->
        {model, system}

      [name | holders] ->
        pid = system.copies[name]
        send(pid, :read)
        result = receive_result(pid)
        model = model |> SpecModel.step!("Lock", [name]) |> read_step(name)
        check_result(model, name, :read, result)
        {model, record_bytes(%{system | holders: holders}, result)}
    end
  end

  # The last copy that got the stream process stops. The lifetime rules
  # stop the stream process of an owner that stopped: the test kills it, thus
  # the stop comes at a known time.
  defp run(:stop_holder, model, system) do
    case system.holders do
      [] ->
        {model, system}

      [name | holders] ->
        kill(system.copies[name])
        model = SpecModel.step!(model, "CopyStop", [name])
        system = %{system | holders: holders}

        if SpecModel.enabled?(model, "StreamStop") do
          kill(stream_pid(system))
          {SpecModel.step!(model, "StreamStop"), system}
        else
          {model, system}
        end
    end
  end

  defp run(:kill_stream, model, system) do
    if SpecModel.enabled?(model, "StreamKill") do
      kill(stream_pid(system))
      {SpecModel.step!(model, "StreamKill"), system}
    else
      {model, system}
    end
  end

  # The steps that the real operation does in the copy and in its starter. A
  # stream read stops before the read: the copy keeps the stream process. A
  # copy that reads, enumerates, or tees a stream process gets the process
  # in the result of these functions, and does not read it.
  defp settle(model, name, operation) do
    actions = for action <- ~w(Eval Register Decide New Check Wake), do: {action, [name]}

    actions =
      if operation == :read, do: actions ++ [{"Lock", [name]}, {"Read", [name]}], else: actions

    model = SpecModel.settle(model, actions)

    if operation in [:take, :take_chunks, :tee, :proxy] and
         SpecModel.enabled?(model, "Drop", [name]),
       do: SpecModel.step!(model, "Drop", [name]),
       else: model
  end

  # The chunks come after the lock and the disturb, when the stream process
  # did not stop.
  defp read_step(model, name) do
    if SpecModel.enabled?(model, "Read", [name]),
      do: SpecModel.step!(model, "Read", [name]),
      else: model
  end

  defp check_result(model, name, operation, result) do
    model_result =
      if SpecModel.get(model, "cpc")[name] == "lock",
        do: "lock",
        else: SpecModel.get(model, "result")[name]

    assert model_result in results(operation, result),
           "#{operation} of the copy #{name} gave #{inspect(result)}, " <>
             "and the specification gives #{model_result}"
  end

  # The results of the specification that a real result can be. The real
  # functions give one value for some states.
  defp results(:take, {:ok, "hello"}), do: ["ok"]
  defp results(:take, :used), do: ["consumed", "canceled", "gone"]
  defp results(:take_chunks, {:ok, [_chunk]}), do: ["ok"]
  defp results(:tee, {:ok, [_branch, _other]}), do: ["ok"]
  defp results(:proxy, {:ok, %LazyStream{}}), do: ["ok"]
  defp results(:cancel, :ok), do: ["ok", "consumed", "canceled", "gone"]
  defp results(:cancel, {:raised, _message}), do: ["locked"]
  defp results(:process, {:ok, pid}) when is_pid(pid), do: ["lock"]
  defp results(:process, {:error, :already_locked}), do: ["locked"]
  defp results(:process, {:error, :released}), do: ["released"]
  defp results(:read, ["hello"]), do: ["bytes"]
  defp results(:read, []), do: ["closed", "locked"]
  defp results(:read, {:raised, "ReadableStream is already locked"}), do: ["locked", "closed"]
  defp results(:read, {:raised, _not_available}), do: ["released", "failed"]
  defp results(_operation, {:process, pid}) when is_pid(pid), do: ["process"]

  defp results(_operation, state) when state in [:readable, :consumed, :canceled, :locked, :gone],
    do: [to_string(state)]

  # A copy that has the stream process keeps it for a later command.
  defp record_holder(system, name, model) do
    if SpecModel.get(model, "cpc")[name] == "lock",
      do: %{system | holders: [name | system.holders]},
      else: system
  end

  # The operations that took the bytes.
  defp record_bytes(system, result) do
    if took_bytes?(result), do: %{system | given: system.given + 1}, else: system
  end

  defp took_bytes?(["hello"]), do: true
  defp took_bytes?({:ok, value}), do: not is_pid(value)
  defp took_bytes?(_result), do: false

  defp kill(nil), do: :ok

  defp kill(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
  end

  # ---------------------------------------------------------------------------
  # The comparison of the two states
  # ---------------------------------------------------------------------------

  defp assert_same_state(model, system) do
    state = SpecModel.to_map(model)
    assert @cell[on_node(system, :atomics, :get, [system.lazy.ref, 1])] == state["cell"]
    assert if(stream_pid(system), do: 1, else: 0) == state["live"]
    assert system.given == state["given"]
  end

  # The registry removes the key some time after the stop: the process
  # must be alive.
  defp stream_pid(system) do
    case on_node(system, Registry, :lookup, [LazyStream.registry(), system.lazy.ref]) do
      [{pid, _value}] -> if on_node(system, Process, :alive?, [pid]), do: pid
      [] -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # A copy that stops during a stream read
  # ---------------------------------------------------------------------------

  describe "a copy that stops during a stream read" do
    test "a second copy reads the bytes after a stop of the first copy after the state starting" do
      check_stop(:starting, :copy)
    end

    test "the copy reads the bytes after a stop of its starter after the state starting" do
      check_stop(:starting, :starter)
    end

    test "a second copy reads the bytes while the first copy is suspended after the state starting" do
      check_stop(:starting, :suspend)
    end

    test "a second copy reads the bytes after a stop of the first copy in the start of the process" do
      check_stop(:registered, :copy)
    end

    test "the copy reads the bytes after a stop of its starter in the start of the process" do
      check_stop(:registered, :starter)
    end

    test "a second copy reads the bytes while the first copy is suspended in the start of the process" do
      check_stop(:registered, :suspend)
    end

    test "a second copy reads the bytes after a stop of the first copy that got the process" do
      check_stop(:got_process, :copy)
    end

    test "a second copy reads the bytes after a stop of the process before a read" do
      check_stop(:got_process, :stream)
    end

    test "a second copy reads the bytes after a stop of the first copy that locked the process" do
      check_stop(:locked, :copy)
    end

    test "a second copy gets no bytes after a stop of the first copy that read them" do
      check_stop(:read, :copy)
    end

    test "a second copy gets no bytes after a stop of the first copy that disturbed the process" do
      check_stop(:disturbed, :copy)
    end

    test "a second copy that got the process reads the bytes after a stop of the owner" do
      check_keep()
    end

    test "a start of a stream process after a start that continued ends with no crash report" do
      log = capture_log(fn -> check_second_start() end)
      refute log =~ "already_registered"
      refute log =~ "MatchError"
    end
  end

  # The steps of the start: the call of the signal that the abort signal
  # holds.
  defp check_stop(step, victim) when step in [:starting, :registered] do
    pause = if step == :starting, do: 1, else: 2
    lazy = LazyStream.new({:bytes, "hello"}, holding_signal([pause]))
    first = start_copy(lazy, :read)

    # At the first call, the starter examines the signal. At the second
    # call, the stream process subscribes to it in its start, after it
    # registered itself. The process that started it is its parent.
    assert_receive {:held, caller, from}, 2_000
    starter = if step == :starting, do: caller, else: parent(caller)

    reader = stop_in_start(victim, first, starter, lazy)
    GenServer.reply(from, :ok)
    assert receive_result(reader) == ["hello"]

    # The starter of the copy that stopped stopped the stream process that
    # it started: no reader can keep it.
    if victim == :copy, do: refute(Process.alive?(first_stream(step, caller)))

    assert_model(model_stop(step, victim), lazy, if(reader == first, do: "a", else: "b"), "bytes")
    if victim == :suspend, do: :erlang.resume_process(first)
  end

  # The steps after the start: the first copy tells the step.
  defp check_stop(step, victim) do
    lazy = LazyStream.new({:bytes, "hello"}, nil)
    test = self()

    first =
      spawn(fn ->
        {:ok, pid} = LazyStream.process(lazy, self())
        stream = %ReadableStream{controller_pid: pid}

        case step do
          :got_process ->
            :ok

          :locked ->
            ReadableStream.get_reader(stream)

          # The steps of "consume body" and of a pipe: a lock, and the
          # disturb, before the first read.
          :disturbed ->
            ReadableStream.get_reader(stream)
            :ok = Web.Stream.call(pid, :disturb, :ok)

          :read ->
            assert read(stream) == ["hello"]
        end

        send(test, {:at_step, pid})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:at_step, pid}, 2_000

    case victim do
      :copy -> kill(first)
      :stream -> kill(pid)
    end

    # The lifetime rules stop a process whose owner stopped.
    wait_until(fn -> not Process.alive?(pid) end)
    second = start_copy(lazy, :read)

    if step in [:read, :disturbed] do
      assert {:raised, "The stream is not available" <> _} = receive_result(second)
      assert_model(model_stop(step, victim), lazy, "b", "released")
    else
      assert receive_result(second) == ["hello"]
      assert_model(model_stop(step, victim), lazy, "b", "bytes")
    end
  end

  # Stops the first copy, or its starter, or suspends the first copy.
  # Returns the copy that reads. A second copy waits for the end of the
  # starter that has the key.
  defp stop_in_start(:starter, first, starter, _lazy) do
    kill(starter)
    first
  end

  defp stop_in_start(victim, first, _starter, lazy) do
    if victim == :copy, do: kill(first), else: :erlang.suspend_process(first)
    second = start_copy(lazy, :read)
    wait_until(fn -> waits_for_down?(second) end)
    second
  end

  # The stream process of the first start: the caller of the second call of
  # the signal, after the first call of the starter.
  defp first_stream(:starting, _caller), do: subscriber(2)
  defp first_stream(:registered, caller), do: caller

  # Copy a gets the stream process and owns it. Copy b gets it also, and
  # takes its lock after the stop of a. The lifetime rules stop a process
  # whose owner failed and that has no lock, but b keeps it.
  defp check_keep do
    lazy = LazyStream.new({:bytes, "hello"}, nil)
    test = self()

    owner =
      spawn(fn ->
        {:ok, pid} = LazyStream.process(lazy, self())
        send(test, {:at_step, pid})
        Process.sleep(:infinity)
      end)

    assert_receive {:at_step, pid}, 2_000

    second =
      spawn(fn ->
        {:ok, ^pid} = LazyStream.process(lazy, self())
        send(test, :got_process)

        receive do
          :read -> send(test, {:result, self(), read(%ReadableStream{controller_pid: pid})})
        end

        # The copy keeps its lock.
        Process.sleep(:infinity)
      end)

    assert_receive :got_process, 2_000
    kill(owner)

    # The stream process handles the stop of its owner before this call.
    _disturbed? = Web.Stream.call(pid, :disturbed?, :gone)
    send(second, :read)
    assert receive_result(second) == ["hello"]

    model =
      "LazyStream"
      |> SpecModel.start(@stop_config)
      |> SpecModel.step!("Begin", ["a", "read"])
      |> SpecModel.settle(internal("a", false))
      |> SpecModel.step!("Begin", ["b", "read"])
      |> SpecModel.settle(internal("b", false))
      |> SpecModel.step!("CopyStop", ["a"])

    refute SpecModel.enabled?(model, "StreamStop")
    model = model |> SpecModel.step!("Lock", ["b"]) |> SpecModel.step!("Read", ["b"])
    assert_model(model, lazy, "b", "bytes")
    kill(second)
  end

  # Copy b starts a stream read, and a process kills b and its starter
  # before the start of the stream process. That start continues with no
  # starter: the test starts a stream process with the key in its place,
  # while the starter of copy a waits before its own start.
  defp check_second_start do
    lazy = LazyStream.new({:bytes, "hello"}, holding_signal([1, 2]))
    copy_b = start_copy(lazy, :read)
    assert_receive {:held, starter_b, from_b}, 2_000
    kill(copy_b)
    kill(starter_b)

    copy_a = start_copy(lazy, :process)
    assert_receive {:held, _starter_a, from_a}, 2_000

    continued =
      Web.ReadableStream.__new__(%{type: "bytes"}, [high_water_mark: 0], registry_key: lazy.ref)

    GenServer.reply(from_b, :ok)
    GenServer.reply(from_a, :ok)
    assert receive_result(copy_a) == {:ok, continued.controller_pid}

    model =
      "LazyStream"
      |> SpecModel.start(@stop_config)
      |> SpecModel.step!("Begin", ["b", "read"])
      |> steps("b", ~w(Eval Register Decide))
      |> SpecModel.step!("CopyStop", ["b"])
      |> SpecModel.step!("StarterStop", ["b", true])
      |> SpecModel.step!("Begin", ["a", "read"])
      |> steps("a", ~w(Eval Register Decide))
      |> SpecModel.step!("OrphanStart")
      |> SpecModel.settle(internal("a", false))

    assert SpecModel.get(model, "cpc")["a"] == "lock"
    refute SpecModel.get(model, "crashed")
    assert @cell[:atomics.get(lazy.ref, 1)] == SpecModel.get(model, "cell")

    assert length(Registry.lookup(LazyStream.registry(), lazy.ref)) ==
             SpecModel.get(model, "live")
  end

  # The specification does the same steps, and its result and its state
  # agree.
  defp assert_model(model, lazy, reader, expected) do
    assert SpecModel.get(model, "result")[reader] == expected
    assert SpecModel.get(model, "given") == 1
    assert @cell[:atomics.get(lazy.ref, 1)] == SpecModel.get(model, "cell")
    live = Registry.lookup(LazyStream.registry(), lazy.ref)
    assert length(live) == SpecModel.get(model, "live")
  end

  defp model_stop(step, victim) do
    "LazyStream"
    |> SpecModel.start(@stop_config)
    |> SpecModel.step!("Begin", ["a", "read"])
    |> model_until(step)
    |> model_stop_at(step, victim)
    |> model_read(victim)
  end

  defp model_until(model, :starting), do: steps(model, "a", ~w(Eval Register Decide))
  defp model_until(model, :registered), do: steps(model, "a", ~w(Eval Register Decide New))

  defp model_until(model, :read), do: SpecModel.settle(model, internal("a", true))

  defp model_until(model, :disturbed),
    do: model |> SpecModel.settle(internal("a", false)) |> SpecModel.step!("Lock", ["a"])

  defp model_until(model, _got_process_or_locked),
    do: SpecModel.settle(model, internal("a", false))

  # The lifetime rules stop the stream process of an owner that stopped,
  # and a stream process after its end.
  defp model_stop_at(model, :read, :copy), do: SpecModel.step!(model, "StreamStop")

  defp model_stop_at(model, step, :copy) when step in [:got_process, :locked, :disturbed],
    do: model |> SpecModel.step!("CopyStop", ["a"]) |> SpecModel.step!("StreamStop")

  defp model_stop_at(model, _step, :copy), do: SpecModel.step!(model, "CopyStop", ["a"])

  defp model_stop_at(model, _step, :starter),
    do: SpecModel.step!(model, "StarterStop", ["a", false])

  defp model_stop_at(model, _step, :stream), do: SpecModel.step!(model, "StreamKill")
  defp model_stop_at(model, _step, :suspend), do: model

  defp model_read(model, :starter), do: SpecModel.settle(model, internal("a", true))

  # A suspended copy does no step: its starter continues.
  defp model_read(model, :suspend) do
    model
    |> SpecModel.step!("Begin", ["b", "read"])
    |> SpecModel.settle([{"New", ["a"]}, {"Check", ["a"]} | internal("b", true)])
  end

  defp model_read(model, _copy_or_stream) do
    model
    |> SpecModel.step!("Begin", ["b", "read"])
    |> SpecModel.settle(internal("a", true) ++ internal("b", true))
  end

  defp steps(model, name, actions),
    do: Enum.reduce(actions, model, &SpecModel.step!(&2, &1, [name]))

  defp internal(name, read?) do
    actions = for action <- ~w(Eval Register Decide New Check Wake), do: {action, [name]}
    if read?, do: actions ++ [{"Lock", [name]}, {"Read", [name]}], else: actions
  end

  # An abort signal that does not abort. Its process holds the calls of a
  # subscription with a number in `pauses`, and tells them to the test,
  # which answers them later. The process answers each other call at once.
  defp holding_signal(pauses) do
    test = self()
    pid = spawn_link(fn -> signal_loop(test, pauses, 1) end)
    %AbortSignal{pid: pid, ref: make_ref()}
  end

  defp signal_loop(test, pauses, number) do
    receive do
      {:"$gen_call", from, {:subscribe, caller}} ->
        if number in pauses do
          send(test, {:held, caller, from})
        else
          send(test, {:subscribed, number, caller})
          GenServer.reply(from, :ok)
        end

        signal_loop(test, pauses, number + 1)

      {:"$gen_cast", {:unsubscribe, _pid}} ->
        signal_loop(test, pauses, number)
    end
  end

  defp subscriber(number) do
    assert_receive {:subscribed, ^number, pid}
    pid
  end

  # The process waits for the end of a starter.
  defp waits_for_down?(pid) do
    Process.info(pid, :current_function) == {:current_function, {LazyStream, :await_down, 1}}
  end

  defp parent(pid) do
    {:dictionary, dictionary} = Process.info(pid, :dictionary)
    {:"$ancestors", [parent | _ancestors]} = List.keyfind(dictionary, :"$ancestors", 0)
    parent
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(5) && wait_until(fun, attempts - 1)
    end
  end

  # ---------------------------------------------------------------------------
  # Copies at the same time
  # ---------------------------------------------------------------------------

  property "copies in different processes at the same time give the bytes one time" do
    check all(operations <- list_of(member_of(@operations), length: 3), max_runs: 200) do
      lazy = LazyStream.new({:bytes, "hello"}, nil)
      test = self()

      # Each process waits for the message :go, and then does its operation.
      procs =
        for operation <- operations do
          spawn(fn ->
            send(test, {:ready, self()})

            receive do
              :go -> send(test, {:result, self(), operation, operate(operation, lazy)})
            end

            receive do
              :stop -> :ok
            end
          end)
        end

      for pid <- procs, do: assert_receive({:ready, ^pid})
      Enum.each(procs, &send(&1, :go))
      results = for pid <- procs, do: assert_receive({:result, ^pid, _operation, _result})

      try do
        check_results(lazy, Enum.map(results, fn {:result, _pid, op, result} -> {op, result} end))
      after
        Enum.each(procs, &Process.exit(&1, :kill))
      end
    end
  end

  # The properties of the specification on the results of operations at the
  # same time.
  defp check_results(lazy, results) do
    pids = results |> Enum.flat_map(&found_pid/1) |> Enum.uniq()

    # OneProcess: all the copies find one stream process.
    assert length(pids) <= 1
    assert length(Registry.lookup(LazyStream.registry(), lazy.ref)) <= 1

    # NoGoneWhileBytes: no stream process stopped, thus no copy gets
    # "gone".
    refute Enum.any?(results, fn {_operation, result} ->
             result in [:gone, {:error, :released}] or
               match?({:raised, "The stream" <> _}, result)
           end)

    # BytesOnce: the operations that took the bytes, and the reads of the
    # stream process.
    taken = Enum.count(results, fn {_operation, result} -> took_bytes?(result) end)
    assert taken <= 1

    # The state of the cell agrees: a claim or a read took the bytes, and a
    # cancel took nothing.
    case @cell[:atomics.get(lazy.ref, 1)] do
      state when state in ["consumed", "locked", "taken"] -> assert taken <= 1
      state when state in ["canceled", "process"] -> assert taken == 0
      "readable" -> assert taken == 0 and pids == []
    end
  end

  defp found_pid({_operation, {tag, pid}}) when tag in [:ok, :process] and is_pid(pid), do: [pid]
  defp found_pid(_result), do: []
end
