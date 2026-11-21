defmodule Web.TLA.LazyStreamConformanceTest do
  # Compares the copies of a real `Web.Internal.LazyStream` with the
  # specification `tla/LazyStream.tla`.
  #
  # The first property makes a random list of operations of the copies in
  # two processes. It does each operation on the real copies and on the
  # specification, and it compares the results and the two states.
  #
  # A third property does the first one with the array on a second node:
  # each operation of the copies runs on the node of the array.
  #
  # The second property lets three processes do an operation on their
  # copies at the same time. The test cannot control the steps of the
  # processes, thus it checks the properties of the specification on the
  # results: the bytes go out one time at most, one stream process at most,
  # and no copy gets "gone".
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Internal.LazyStream
  alias Web.ReadableStream
  alias Web.Test.SpecModel

  @copies [:a, :b]
  @operations [:take, :take_chunks, :cancel, :tee, :proxy, :process, :state]

  # The values of the cell: see `Web.Internal.LazyStream`.
  @cell %{
    0 => "readable",
    1 => "consumed",
    2 => "canceled",
    3 => "locked",
    4 => "starting",
    5 => "process"
  }

  defp command do
    frequency([
      {10, tuple({member_of(@operations), member_of(@copies)})},
      {1, constant(:stop_stream)}
    ])
  end

  property "the copies do each operation as the specification permits" do
    check all(commands <- list_of(command(), max_length: 12), max_runs: 150) do
      run_commands(commands, LazyStream.new({:chunk, "hello"}, nil), node())
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
      check all(commands <- list_of(command(), max_length: 10), max_runs: 30) do
        # An agent on the second node keeps one copy there. Thus the VM
        # keeps the array.
        {:ok, agent} =
          :erpc.call(node, Agent, :start, [LazyStream, :new, [{:chunk, "hello"}, nil]])

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
    copies = Map.new(@copies, fn name -> {name, start_copy(lazy)} end)
    system = %{lazy: lazy, node: node, copies: copies, pid: nil, given: 0}

    try do
      Enum.reduce(commands, {SpecModel.start("LazyStream"), system}, fn command,
                                                                        {model, system} ->
        {model, system} = run(command, model, system)
        assert_same_state(model, system)
        {model, system}
      end)
    after
      Enum.each(copies, fn {_name, pid} -> Process.exit(pid, :kill) end)
    end
  end

  # A function on the node of the array.
  defp on_node(%{node: node}, module, function, args) when node == node(),
    do: apply(module, function, args)

  defp on_node(%{node: node}, module, function, args),
    do: :erpc.call(node, module, function, args)

  property "copies in different processes at the same time give the bytes one time" do
    check all(operations <- list_of(member_of(@operations), length: 3), max_runs: 200) do
      lazy = LazyStream.new({:chunk, "hello"}, nil)
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

  # ---------------------------------------------------------------------------
  # The real copies
  # ---------------------------------------------------------------------------

  # A process with a copy of the struct. It does one operation at a time.
  defp start_copy(lazy) do
    test = self()

    spawn(fn ->
      copy_loop(test, lazy)
    end)
  end

  defp copy_loop(test, lazy) do
    receive do
      {:run, operation} ->
        send(test, {:result, operate(operation, lazy)})
        copy_loop(test, lazy)
    end
  end

  defp operate(:take, lazy), do: LazyStream.take(lazy)
  defp operate(:take_chunks, lazy), do: LazyStream.take_chunks(lazy)
  defp operate(:cancel, lazy), do: LazyStream.cancel(lazy)
  defp operate(:tee, lazy), do: LazyStream.tee(lazy)
  defp operate(:proxy, lazy), do: LazyStream.proxy(lazy)
  defp operate(:process, lazy), do: LazyStream.process(lazy, self())
  defp operate(:state, lazy), do: LazyStream.state(lazy)

  defp call(system, copy, operation) do
    send(system.copies[copy], {:run, operation})

    receive do
      {:result, result} -> result
    after
      2_000 -> flunk("the copy #{copy} gave no result")
    end
  end

  # ---------------------------------------------------------------------------
  # One operation, on the real copies and on the specification
  # ---------------------------------------------------------------------------

  defp run(:stop_stream, model, system) do
    if SpecModel.enabled?(model, "StreamStop") do
      monitor = Process.monitor(system.pid)
      Process.exit(system.pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, _pid, :killed}
      {SpecModel.step!(model, "StreamStop"), system}
    else
      {model, system}
    end
  end

  defp run({operation, copy}, model, system) do
    name = to_string(copy)
    result = call(system, copy, operation)
    model = model_steps(operation, name, model)
    model_result = SpecModel.get(model, "result")[name]

    assert model_result in results(operation, result),
           "#{operation} of the copy #{name} gave #{inspect(result)}, " <>
             "and the specification gives #{model_result}"

    {model, system |> record_pid(result) |> record_bytes(operation, result)}
  end

  defp model_steps(operation, name, model) when operation in [:take, :tee, :proxy],
    do: SpecModel.step!(model, "Claim", [name, "locked"])

  defp model_steps(:take_chunks, name, model),
    do: SpecModel.step!(model, "Claim", [name, "consumed"])

  defp model_steps(:cancel, name, model), do: SpecModel.step!(model, "Claim", [name, "canceled"])
  defp model_steps(:state, name, model), do: SpecModel.step!(model, "State", [name])

  # A stream read is three steps of the specification: the compare-exchange,
  # the start of the stream process, and the state "process".
  defp model_steps(:process, name, model) do
    model = SpecModel.step!(model, "Begin", [name])

    if SpecModel.enabled?(model, "Start", [name]) do
      model |> SpecModel.step!("Start", [name]) |> SpecModel.step!("Publish", [name])
    else
      model
    end
  end

  # The results of the specification that a real result can be. The real
  # functions give one value for some states.
  defp results(:take, {:ok, "hello"}), do: ["ok"]
  defp results(:take, :used), do: ["consumed", "canceled", "gone"]
  defp results(:cancel, :ok), do: ["ok", "consumed", "canceled", "gone"]
  defp results(:take_chunks, {:ok, [_chunk]}), do: ["ok"]
  defp results(:tee, {:ok, [_branch, _other]}), do: ["ok"]
  defp results(:proxy, {:ok, %LazyStream{}}), do: ["ok"]
  defp results(:process, {:ok, pid}) when is_pid(pid), do: ["process"]
  defp results(:process, {:error, :already_locked}), do: ["locked"]
  defp results(:process, {:error, :released}), do: ["gone"]
  defp results(_operation, {:process, pid}) when is_pid(pid), do: ["process"]

  defp results(_operation, state) when state in [:readable, :consumed, :canceled, :locked, :gone],
    do: [to_string(state)]

  # All the copies find one stream process.
  defp record_pid(system, result) do
    case result do
      {tag, pid} when tag in [:ok, :process] and is_pid(pid) ->
        assert system.pid in [nil, pid], "a second stream process: #{inspect(pid)}"
        %{system | pid: pid}

      _other ->
        system
    end
  end

  # The operations that took the bytes.
  defp record_bytes(system, operation, {:ok, _value}) when operation != :process,
    do: %{system | given: system.given + 1}

  defp record_bytes(system, _operation, _result), do: system

  # ---------------------------------------------------------------------------
  # The comparison of the two states
  # ---------------------------------------------------------------------------

  defp assert_same_state(model, system) do
    state = SpecModel.to_map(model)
    assert @cell[on_node(system, :atomics, :get, [system.lazy.ref, 1])] == state["cell"]
    assert registered?(system) == state["registered"]

    # The stream process has the chunk only when it got the bytes.
    stream_bytes = if stream_has_bytes?(system), do: 1, else: 0
    assert system.given + stream_bytes == state["given"]
  end

  # The registry removes the key some time after the stop: the process
  # must be alive.
  defp registered?(system) do
    case on_node(system, Registry, :lookup, [LazyStream.registry(), system.lazy.ref]) do
      [{pid, _value}] -> on_node(system, Process, :alive?, [pid])
      [] -> false
    end
  end

  # The function start of the stream process enqueues the chunk and closes
  # the stream. The messages of start come before the answer of the copy.
  # A stream process that stopped is counted with its kind of the start.
  defp stream_has_bytes?(%{pid: nil}), do: false

  defp stream_has_bytes?(system) do
    key = {__MODULE__, system.pid}

    case Process.get(key) do
      nil ->
        slots = ReadableStream.__get_slots__(system.pid)
        bytes? = :queue.len(slots.queue) == 1 and slots.state == :closed
        Process.put(key, bytes?)
        bytes?

      bytes? ->
        bytes?
    end
  end

  # The properties of the specification on the results of operations at the
  # same time.
  defp check_results(lazy, results) do
    pids = results |> Enum.flat_map(&found_pid/1) |> Enum.uniq()

    # OneProcess: all the copies find one stream process.
    assert length(pids) <= 1
    assert length(Registry.lookup(LazyStream.registry(), lazy.ref)) <= 1

    # GoneOnlyAfterStop: no stream process stopped, thus no copy gets
    # "gone".
    refute Enum.any?(results, fn {_operation, result} ->
             result in [:gone, {:error, :released}]
           end)

    # BytesOnce: the operations that took the bytes, and the stream process
    # when it has the bytes.
    taken = Enum.count(results, &took_bytes?/1)
    stream = Enum.count(pids, &(:queue.len(ReadableStream.__get_slots__(&1).queue) == 1))
    assert taken + stream <= 1

    # The state of the cell agrees: a claim of the bytes took them, and a
    # cancel took nothing.
    case @cell[:atomics.get(lazy.ref, 1)] do
      state when state in ["consumed", "locked"] -> assert taken == 1
      "canceled" -> assert taken == 0
      "process" -> :ok
      "readable" -> assert taken == 0 and pids == []
    end
  end

  defp found_pid({_operation, {tag, pid}}) when tag in [:ok, :process] and is_pid(pid), do: [pid]
  defp found_pid(_result), do: []

  defp took_bytes?({operation, result}), do: operation != :process and match?({:ok, _}, result)
end
