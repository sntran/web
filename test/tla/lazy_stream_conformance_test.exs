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
  # The tests of "the steps of the actors in a known sequence" do the steps
  # of a claim or of a starter with the step functions of the code, in the
  # sequence of a counterexample of a Bug value of the specification. The
  # steps of the other copies, starters, and stream processes come between
  # them, and the test compares the two states after each step. Other tests
  # of that group look at the state during a start, and after a start that
  # stopped.
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
      held_loop(test, lazy, result)
    end)
  end

  # The copy reads the process that it got with the lock step of the
  # library: a process that stopped before its first read gives a new ask.
  defp held_loop(test, lazy, result) do
    receive do
      :read ->
        {:ok, pid} = result
        send(test, {:result, self(), read_held(lazy, pid)})
        held_loop(test, lazy, result)
    end
  end

  defp read_held(lazy, pid) do
    stream = %ReadableStream{lazy: lazy}

    reader =
      ReadableStream.__lock__(stream, pid, &ReadableStream.__reader__/1, fn ->
        {:ok, ReadableStream.get_reader(stream)}
      end)

    case reader do
      {:ok, reader} -> read_all(reader)
      {:error, :released} -> {:raised, "The stream is not available"}
      {:error, :already_locked} -> {:raised, "ReadableStream is already locked"}
    end
  rescue
    error in Web.TypeError -> {:raised, error.message}
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
        model = model |> SpecModel.step!("Lock", [name]) |> read_step(name) |> read_again(name)
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
    actions = internal(name, operation == :read)

    model = SpecModel.settle(model, actions)

    if operation in [:take, :take_chunks, :tee, :proxy] and
         SpecModel.enabled?(model, "Drop", [name]),
       do: SpecModel.step!(model, "Drop", [name]),
       else: model
  end

  # A copy whose process stopped before its first read asks again.
  defp read_again(model, name) do
    if SpecModel.get(model, "cpc")[name] == "ask",
      do: SpecModel.settle(model, internal(name, true)),
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

  # ---------------------------------------------------------------------------
  # A kill of the stream process between the keep and the lock
  # ---------------------------------------------------------------------------

  # Each path that takes the lock of a stream process, its operation in the
  # specification, and its bytes.
  @form_body "--b\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nhello\r\n--b--\r\n"
  @lock_paths [
    get_reader: "read",
    byob_reader: "read",
    values: "read",
    enum: "read",
    pipe_to: "read",
    pipe_through: "read",
    proxy: "read",
    form_data: "read",
    tee: "locked",
    text: "locked",
    cancel: "canceled"
  ]

  describe "a kill of the stream process after the keep of a copy and before its lock" do
    for {path, operation} <- @lock_paths do
      test "the path #{path} asks again and gets the bytes" do
        check_kill_before_lock(unquote(path), unquote(operation))
      end
    end

    test "the error stays when the bytes went to a reader" do
      lazy = LazyStream.new({:bytes, "hello"}, nil)
      {:ok, pid} = LazyStream.process(lazy, self())
      assert read(%ReadableStream{controller_pid: pid}) == ["hello"]
      kill_after_keep(pid)

      copy = start_copy(lazy, :read)
      assert_receive {:kept, ^pid}, 2_000
      kill(pid)
      assert {:raised, "The stream is not available" <> _} = receive_result(copy)

      model =
        @stop_config
        |> start_model()
        |> SpecModel.step!("Begin", ["a", "read"])
        |> SpecModel.settle(internal("a", true))
        |> SpecModel.step!("Begin", ["b", "read"])
        |> SpecModel.settle(internal("b", false))
        |> SpecModel.step!("StreamKill")
        |> SpecModel.settle(internal("b", true))

      assert SpecModel.get(model, "result")["b"] == "failed"
      assert @cell[:atomics.get(lazy.ref, 1)] == SpecModel.get(model, "cell")
    end
  end

  describe "a kill of the stream process after the keep, when a different copy started a new one" do
    test "the lock step asks again, and gets the new process" do
      lazy = LazyStream.new({:bytes, "hello"}, nil)
      {:ok, pid} = LazyStream.process(lazy, self())
      kill_after_keep(pid)

      # The copy waits for the answer of its lock. The test suspends it, kills
      # the process, and a different copy starts a new stream process. Then
      # the copy finds that its process stopped.
      copy = start_copy(lazy, :read)
      assert_receive {:kept, ^pid}, 2_000
      wait_until(fn -> calls?(copy) end)
      true = :erlang.suspend_process(copy)
      kill(pid)
      other = start_copy(lazy, :process)
      assert {:ok, new_pid} = receive_result(other)
      true = :erlang.resume_process(copy)
      assert receive_result(copy) == ["hello"]
      assert LazyStream.state(lazy) == {:process, new_pid}

      model =
        [{~s(Copies = {"a", "b"}), ~s(Copies = {"a", "b", "c"})} | @stop_config]
        |> start_model()
        |> SpecModel.step!("Begin", ["a", "read"])
        |> SpecModel.settle(internal("a", false))
        |> SpecModel.step!("Begin", ["b", "read"])
        |> SpecModel.settle(internal("b", false))
        |> SpecModel.step!("StreamKill")
        |> SpecModel.step!("Begin", ["c", "read"])
        |> SpecModel.settle(internal("c", false))
        |> SpecModel.settle(internal("b", true))

      assert SpecModel.get(model, "result")["b"] == "bytes"
      assert @cell[:atomics.get(lazy.ref, 1)] == SpecModel.get(model, "cell")
      kill(other)
    end

    test "a cancel after a read resolves, and the bytes stay taken" do
      lazy = LazyStream.new({:bytes, "hello"}, nil)
      {:ok, pid} = LazyStream.process(lazy, self())
      assert read(%ReadableStream{controller_pid: pid}) == ["hello"]
      kill_after_keep(pid)

      test = self()

      copy =
        spawn(fn ->
          result = Web.await(ReadableStream.cancel(%ReadableStream{lazy: lazy}))
          send(test, {:result, self(), result})
        end)

      assert_receive {:kept, ^pid}, 2_000
      kill(pid)
      assert receive_result(copy) == :ok
      assert LazyStream.state(lazy) == :gone
    end
  end

  # The process waits for the answer of a call.
  defp calls?(pid) do
    Process.info(pid, :current_function) == {:current_function, {:gen, :do_call, 4}}
  end

  # The test gets the stream process, as the copy "a" of the specification.
  # A copy "b" does the path: the stream process stops after it answered the
  # keep of that copy, before the lock.
  defp check_kill_before_lock(path, operation) do
    bytes = if path == :form_data, do: @form_body, else: "hello"
    lazy = LazyStream.new({:bytes, bytes}, nil)
    {:ok, pid} = LazyStream.process(lazy, self())

    # An enumeration and a proxy first claim the bytes, and get the process
    # with a keep. Then the reader of the enumeration, or the pipe of the
    # proxy, asks for the process with a second keep, and takes its lock.
    kill_after_keep(pid, if(path in [:enum, :proxy], do: 2, else: 1))

    test = self()

    copy =
      spawn(fn ->
        send(test, {:result, self(), lock_path(path, %ReadableStream{lazy: lazy})})
        Process.sleep(:infinity)
      end)

    assert_receive {:kept, ^pid}, 2_000
    kill(pid)
    assert receive_result(copy) == path_result(path)

    model =
      @stop_config
      |> start_model()
      |> SpecModel.step!("Begin", ["a", "read"])
      |> SpecModel.settle(internal("a", false))
      |> SpecModel.step!("Begin", ["b", operation])
      |> SpecModel.settle(internal("b", false))
      |> SpecModel.step!("StreamKill")
      |> SpecModel.settle(internal("b", true))

    expected = if operation == "read", do: "bytes", else: "ok"
    assert SpecModel.get(model, "result")["b"] == expected
    assert @cell[:atomics.get(lazy.ref, 1)] == SpecModel.get(model, "cell")
    kill(copy)
  end

  defp start_model(config), do: SpecModel.start("LazyStream", config)

  defp lock_path(:get_reader, stream), do: stream |> ReadableStream.get_reader() |> read_text()

  defp lock_path(:byob_reader, stream),
    do: stream |> ReadableStream.get_reader(mode: "byob") |> read_byob([])

  defp lock_path(:values, stream), do: stream |> ReadableStream.values() |> iterate([])
  defp lock_path(:enum, stream), do: Enum.map_join(stream, &Uint8Array.to_binary/1)

  defp lock_path(:pipe_to, stream) do
    test = self()

    sink =
      Web.WritableStream.new(%{write: fn chunk, _controller -> send(test, {:sink, chunk}) end})

    :ok = Web.await(ReadableStream.pipe_to(stream, sink))
    sink_text([])
  end

  defp lock_path(:pipe_through, stream) do
    stream
    |> ReadableStream.pipe_through(Web.TransformStream.new())
    |> ReadableStream.get_reader()
    |> read_text()
  end

  defp lock_path(:proxy, stream),
    do: Web.await(Web.Response.text(%Web.Response{body: Web.Body.__proxy__(stream)}))

  defp lock_path(:form_data, stream),
    do: stream |> Web.FormData.parse("b") |> Web.FormData.get("a")

  defp lock_path(:tee, stream) do
    stream
    |> ReadableStream.tee()
    |> Enum.map(&(&1 |> ReadableStream.get_reader() |> read_text()))
  end

  defp lock_path(:text, stream), do: Web.await(Web.Response.text(%Web.Response{body: stream}))

  # The cancel takes the bytes: a later read gets no chunk.
  defp lock_path(:cancel, stream) do
    :ok = Web.await(ReadableStream.cancel(stream))
    stream |> ReadableStream.get_reader() |> read_text()
  end

  defp path_result(:tee), do: ["hello", "hello"]
  defp path_result(:cancel), do: ""
  defp path_result(_path), do: "hello"

  defp read_text(reader), do: reader |> read_all() |> Enum.join()

  defp read_byob(reader, acc) do
    view = Uint8Array.new(Web.ArrayBuffer.new(16))

    case Web.await(Web.ReadableStreamBYOBReader.read(reader, view)) do
      %{done: true} -> acc |> Enum.reverse() |> Enum.join()
      %{value: chunk} -> read_byob(reader, [Uint8Array.to_binary(chunk) | acc])
    end
  end

  defp iterate(iterator, acc) do
    case Web.await(Web.ReadableStreamAsyncIterator.next(iterator)) do
      %{done: true} -> acc |> Enum.reverse() |> Enum.join()
      %{value: chunk} -> iterate(iterator, [Uint8Array.to_binary(chunk) | acc])
    end
  end

  defp sink_text(acc) do
    receive do
      {:sink, chunk} -> sink_text([Uint8Array.to_binary(chunk) | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join()
    end
  end

  # The stream process stops after its answer to the keep number `count` of
  # a copy, before the lock of that copy. A debug function of the process
  # (`:sys.install/2`) holds the process after that answer, and tells it to
  # the test, which kills the process. The keep of the test itself came
  # before.
  defp kill_after_keep(pid, count \\ 1) do
    test = self()

    # The state of the function is the number of keeps to wait for.
    hook = fn
      left, {:in, {{:call, {from, _tag}}, {:keep, _keeper}}, _state}, _process
      when is_integer(left) and from != test ->
        if left == 1, do: :keep_in, else: left - 1

      :keep_in, {:out, _reply, _to}, _process ->
        send(test, {:kept, self()})

        receive do
          :never -> :done
        end

      state, _event, _process ->
        state
    end

    :ok = :sys.install(pid, {hook, count})
  end

  # ---------------------------------------------------------------------------
  # A start that continues after a kill of its starter
  # ---------------------------------------------------------------------------

  describe "a start that continues after a kill of its starter" do
    test "stops in its start in the state process, where a claim can take the bytes" do
      lazy = LazyStream.new({:bytes, "hello"}, nil)
      {:ok, pid} = LazyStream.process(lazy, self())
      kill(pid)

      # The cell has "process", and no stream process: the bytes are free.
      # The start that continued comes now.
      log =
        capture_log(fn ->
          assert Web.ReadableStream.__new__(%{type: "bytes"}, [], registry_key: lazy.ref) ==
                   :ignore
        end)

      refute log =~ "error"
      assert Registry.lookup(LazyStream.registry(), lazy.ref) == []
      assert LazyStream.take(lazy) == {:ok, "hello"}
    end

    test "registers itself in the state starting, and a claim after the state readable stops it" do
      {lazy, continued} = continued_start()
      assert LazyStream.take(lazy) == {:ok, "hello"}
      wait_until(fn -> not Process.alive?(continued) end)

      # Some time later, the registry has no key for the process.
      wait_until(fn -> Registry.lookup(LazyStream.registry(), lazy.ref) == [] end)
    end

    test "registers itself in the state starting, and a read after the state readable stops it" do
      {lazy, continued} = continued_start()
      copy = start_copy(lazy, :read)
      assert receive_result(copy) == ["hello"]
      refute Process.alive?(continued)

      # The bytes went to one reader only.
      body = %Web.Response{body: %ReadableStream{lazy: lazy}}

      assert %Web.TypeError{message: "body already used"} =
               catch_exit(Web.await(Web.Response.text(body)))
    end
  end

  # The start registers itself while the cell has "starting", the state that
  # it permits. Then the cell has "readable": the state after a starter
  # that set "readable" for a copy that stopped, before that starter looked
  # in the registry. The test sets the two states: no step of the real code
  # can stop there for a test.
  defp continued_start do
    lazy = LazyStream.new({:bytes, "hello"}, nil)
    :atomics.put(lazy.ref, 1, 4)

    source = %{
      type: "bytes",
      pull: fn controller ->
        Web.ReadableStream.enqueue(controller.pid, Uint8Array.from("hello"))
        Web.ReadableStream.close(controller.pid)
      end
    }

    continued =
      Web.ReadableStream.__new__(source, [high_water_mark: 0], registry_key: lazy.ref)

    :atomics.put(lazy.ref, 1, 0)
    {lazy, continued.controller_pid}
  end

  # ---------------------------------------------------------------------------
  # The steps of the actors in a known sequence
  # ---------------------------------------------------------------------------

  # A test cannot stop a process between two steps of one function. Thus the
  # test does the steps of a claim or of a starter itself, with the step
  # functions that the normal path calls one after the other, and the steps
  # of the other actors come between them. After each step, the cell and the
  # stream process agree with the specification.
  describe "the steps of the actors in a known sequence" do
    test "a claim that found a stream process that stopped looks again after a new start" do
      lazy = LazyStream.new({:bytes, "hello"}, nil)

      model =
        start_model([{~s(Copies = {"a", "b"}), ~s(Copies = {"a", "b", "c"})} | @stop_config])

      # Copy b gets a stream process, and does not read it. A process kills
      # it: the cell has "process", and the bytes are free.
      {:ok, first} = LazyStream.process(lazy, self())
      kill(first)

      model =
        model
        |> SpecModel.step!("Begin", ["b", "read"])
        |> SpecModel.settle(internal("b", false))
        |> SpecModel.step!("Drop", ["b"])
        |> SpecModel.step!("StreamKill")

      assert_spec_state(model, lazy)

      # Copy a claims the bytes. Its look finds "process" and no stream
      # process.
      look = LazyStream.__look__(lazy)
      assert look == {5, nil}
      model = model |> SpecModel.step!("Begin", ["a", "locked"]) |> SpecModel.step!("Eval", ["a"])
      assert SpecModel.get(model, "cpc")["a"] == "release"
      assert_spec_state(model, lazy)

      # Copy c reads: its starter starts a new stream process, and sets
      # "process" again.
      reader = start_copy(lazy, :process)
      assert {:ok, second} = receive_result(reader)

      model =
        model
        |> SpecModel.step!("Begin", ["c", "read"])
        |> SpecModel.settle(internal("c", false))

      assert SpecModel.get(model, "cpc")["c"] == "lock"
      assert_spec_state(model, lazy)

      # The step of the claim after its look: the bytes are not free now, and
      # the claim looks again.
      assert LazyStream.__claim_step__(lazy, :locked, look) == :again
      model = SpecModel.step!(model, "Release", ["a"])
      assert SpecModel.get(model, "cpc")["a"] == "ask"
      assert_spec_state(model, lazy)

      # The new look gives the stream process of copy c.
      assert LazyStream.claim(lazy, :locked) == {:process, second}
      model = SpecModel.step!(model, "Eval", ["a"])
      assert SpecModel.get(model, "cpc")["a"] == "lock"
      assert_spec_state(model, lazy)

      # Copy c reads the bytes. They went out one time.
      send(reader, :read)
      assert receive_result(reader) == ["hello"]
      model = model |> SpecModel.step!("Lock", ["c"]) |> SpecModel.step!("Read", ["c"])
      assert SpecModel.get(model, "result")["c"] == "bytes"
      assert SpecModel.get(model, "given") == 1
      assert_spec_state(model, lazy)
      kill(reader)
    end

    test "a starter whose copy stopped stops a start that registered itself after its first stop" do
      lazy = LazyStream.new({:bytes, "hello"}, holding_signal([1, 3]))
      model = start_model([])

      # Copy b reads. The signal holds its starter before the start of the
      # stream process. A process kills copy b, and then its starter. The
      # start continues with no starter: the test does it later.
      copy_b = start_copy(lazy, :read)
      assert_receive {:held, starter_b, _from_b}, 2_000
      kill(copy_b)
      kill(starter_b)

      model =
        model
        |> SpecModel.step!("Begin", ["b", "read"])
        |> steps("b", ~w(Eval Register Decide))
        |> SpecModel.step!("CopyStop", ["b"])
        |> SpecModel.step!("StarterStop", ["b", true])

      assert_spec_state(model, lazy)

      # Copy a reads. Its starter starts a stream process, which registers
      # itself, and the signal holds it in its start. The test suspends the
      # starter, and a process kills copy a. Then the start ends.
      copy_a = start_copy(lazy, :read)
      assert_receive {:subscribed, 2, starter_a}, 2_000
      assert_receive {:held, stream, from}, 2_000
      assert parent(stream) == starter_a
      true = :erlang.suspend_process(starter_a)
      kill(copy_a)

      model =
        model
        |> SpecModel.step!("Begin", ["a", "read"])
        |> steps("a", ~w(Eval Register Decide New))
        |> SpecModel.step!("CopyStop", ["a"])

      assert_spec_state(model, lazy)
      GenServer.reply(from, :ok)

      # The test does the steps of the starter of copy a, and the start of
      # copy b comes between them. First, the starter stops its stream
      # process: no reader keeps it.
      assert LazyStream.__stop_started__(stream) == :ok
      refute Process.alive?(stream)
      model = SpecModel.step!(model, "Check", ["a"])
      assert_spec_state(model, lazy)

      # The start of copy b continues, and registers itself in the state
      # "starting".
      continued = start_continued(lazy)
      model = SpecModel.step!(model, "OrphanStart")
      assert_spec_state(model, lazy)

      # The starter sets "readable", and then it stops the stream process
      # with no use.
      assert LazyStream.__rollback__(lazy) == :ok
      model = SpecModel.step!(model, "Rollback", ["a"])
      assert_spec_state(model, lazy)

      assert LazyStream.__rollback_reap__(lazy) == :ok
      refute Process.alive?(continued)
      kill(starter_a)
      model = SpecModel.step!(model, "StarterReap", ["a"])
      assert_spec_state(model, lazy)

      # The bytes are free.
      assert LazyStream.take(lazy) == {:ok, "hello"}
    end

    test "a look at the state after a start that stopped starts no process" do
      lazy = LazyStream.new({:bytes, "hello"}, holding_signal([1]))
      stream = %ReadableStream{lazy: lazy}

      model =
        start_model([{~s(Copies = {"a", "b"}), ~s(Copies = {"a", "b", "c"})}, @all_ops])

      # Copy b reads. The signal holds its starter after the state
      # "starting". A process kills copy b, and then its starter.
      copy_b = start_copy(lazy, :read)
      assert_receive {:held, starter_b, _from_b}, 2_000
      kill(copy_b)
      kill(starter_b)

      model =
        model
        |> SpecModel.step!("Begin", ["b", "read"])
        |> steps("b", ~w(Eval Register Decide))
        |> SpecModel.step!("CopyStop", ["b"])
        |> SpecModel.step!("StarterStop", ["b", false])

      assert_spec_state(model, lazy)

      # Copy a looks at the state: no process took the bytes. The functions
      # that tell the state agree, and no process starts.
      assert LazyStream.state(lazy) == :readable
      refute ReadableStream.disturbed?(stream)
      refute ReadableStream.locked?(stream)
      refute Web.Response.body_used?(%Web.Response{body: stream})
      assert live_keys({lazy.ref, :start}) == []
      assert live_keys(lazy.ref) == []
      model = model |> SpecModel.step!("Begin", ["a", "state"]) |> SpecModel.step!("Eval", ["a"])
      assert SpecModel.get(model, "result")["a"] == "readable"
      assert SpecModel.get(model, "sp")["a"] == "none"
      assert_spec_state(model, lazy)

      # A stream read continues the start, and gets the bytes.
      copy_c = start_copy(lazy, :read)
      assert receive_result(copy_c) == ["hello"]

      model =
        model
        |> SpecModel.step!("Begin", ["c", "read"])
        |> SpecModel.settle(internal("c", true))

      assert SpecModel.get(model, "result")["c"] == "bytes"
      assert_spec_state(model, lazy)
      kill(copy_c)
    end

    test "a look at the state during the start of a closed stream gives consumed" do
      lazy = LazyStream.new({:bytes, "hello"}, holding_signal([1]))

      model =
        start_model([{~s(Copies = {"a", "b"}), ~s(Copies = {"a", "b", "c"})}, @all_ops])

      # Copy b cancels the stream.
      assert LazyStream.cancel(lazy) == :ok

      model =
        model
        |> SpecModel.step!("Begin", ["b", "canceled"])
        |> SpecModel.settle(internal("b", false))

      # Copy c reads. The signal holds its starter after the state
      # "starting_closed".
      copy_c = start_copy(lazy, :read)
      assert_receive {:held, _starter_c, from}, 2_000

      model =
        model
        |> SpecModel.step!("Begin", ["c", "read"])
        |> steps("c", ~w(Eval Register Decide))

      assert_spec_state(model, lazy)

      # Copy a looks at the state: a claim used the bytes, and the stream is
      # closed.
      assert LazyStream.state(lazy) == :consumed
      model = model |> SpecModel.step!("Begin", ["a", "state"]) |> SpecModel.step!("Eval", ["a"])
      assert SpecModel.get(model, "result")["a"] == "consumed"
      assert_spec_state(model, lazy)

      # The start ends: copy c reads a closed stream.
      GenServer.reply(from, :ok)
      assert receive_result(copy_c) == []
      model = SpecModel.settle(model, internal("c", true))
      assert SpecModel.get(model, "result")["c"] == "closed"

      # The lifetime rules stop a closed stream after its end, at a time that
      # the test does not know: the test compares the cell only.
      assert @cell[:atomics.get(lazy.ref, 1)] == SpecModel.get(model, "cell")
      kill(copy_c)
    end
  end

  # The start of a stream process of the bytes, with the key of the stream:
  # the start of a starter that a process killed, which continues.
  defp start_continued(lazy) do
    source = %{
      type: "bytes",
      pull: fn controller ->
        Web.ReadableStream.enqueue(controller.pid, Uint8Array.from("hello"))
        Web.ReadableStream.close(controller.pid)
      end
    }

    Web.ReadableStream.__new__(source, [high_water_mark: 0], registry_key: lazy.ref).controller_pid
  end

  # The processes that are alive and have the key. The registry removes the
  # key some time after the stop of a process.
  defp live_keys(key) do
    for {pid, _value} <- Registry.lookup(LazyStream.registry(), key), Process.alive?(pid), do: pid
  end

  defp assert_spec_state(model, lazy) do
    assert @cell[:atomics.get(lazy.ref, 1)] == SpecModel.get(model, "cell")
    live = if stream_pid(%{lazy: lazy, node: node()}), do: 1, else: 0
    assert live == SpecModel.get(model, "live")
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

  # The first copy waits after its step: it does no more step.
  defp model_read(model, :stream) do
    model
    |> SpecModel.step!("Begin", ["b", "read"])
    |> SpecModel.settle(internal("b", true))
  end

  defp model_read(model, :copy) do
    model
    |> SpecModel.step!("Begin", ["b", "read"])
    |> SpecModel.settle(internal("a", true) ++ internal("b", true))
  end

  defp steps(model, name, actions),
    do: Enum.reduce(actions, model, &SpecModel.step!(&2, &1, [name]))

  # The steps that a real operation does in the copy and in its starter.
  defp internal(name, read?) do
    actions =
      for action <-
            ~w(Eval ClaimSet Release Reap Register Decide New Check Rollback StarterReap Wake),
          do: {action, [name]}

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
