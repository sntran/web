defmodule Web.TLA.ConnectionPoolConformanceTest do
  # Compares a real `Web.Dispatcher.HTTP.Pool` with the specification
  # `tla/ConnectionPool.tla`.
  #
  # The test makes a random list of operations. Each process of the
  # specification is a real client process that speaks the protocol of the
  # pool, with real connections to a server of the test. The test does each
  # operation on the pool and on the specification, and it compares the two
  # states.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Dispatcher.HTTP.Pool
  alias Web.Test.SpecModel

  @procs ["a", "b", "c"]
  @size 2
  @constants {"Size = 2", "Size = #{@size}"}

  defp command do
    proc = member_of(@procs)

    frequency([
      {5, tuple({constant("Checkout"), proc})},
      {3, tuple({constant("Return"), proc})},
      {2, tuple({constant("Release"), proc})},
      {2, tuple({constant("Cancel"), proc})},
      {2, tuple({constant("Stop"), proc})},
      {1, constant("ServerClose")}
    ])
  end

  property "the pool does each step as the specification permits" do
    check all(commands <- list_of(command(), max_length: 24), max_runs: 60) do
      system = start_system()

      try do
        Enum.reduce(commands, {SpecModel.start("ConnectionPool", @constants), system}, fn
          command, {model, system} ->
            {model, system} = run(command, model, system)
            assert_same_state(model, system)
            {model, system}
        end)
      after
        stop_system(system)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The real system: a server, a pool, and one client for each process
  # ---------------------------------------------------------------------------

  defp start_system do
    test = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    server = spawn(fn -> server(listener, test) end)

    # The origin is only the name of the pool: the clients connect to the
    # server. A new name for each run, as the port of a run can come again.
    origin = {:http, "pool-#{System.unique_integer([:positive])}.test", port}
    {:ok, pool} = Pool.start_link(origin, @size)
    Process.unlink(pool)

    system = %{server: server, pool: pool, port: port, clients: %{}}
    Enum.reduce(@procs, system, &start_client(&2, &1))
  end

  defp stop_system(system) do
    for {_name, pid} <- system.clients, do: Process.exit(pid, :kill)
    Process.exit(system.pool, :kill)
    Process.exit(system.server, :kill)
  end

  # The server accepts each connection, and closes the connection that the
  # test names with the local port of the client.
  defp server(listener, _test) do
    server = self()
    {:ok, acceptor} = Task.start_link(fn -> accept(listener, server) end)
    server_loop(acceptor, %{})
  end

  defp accept(listener, server) do
    {:ok, socket} = :gen_tcp.accept(listener)
    :ok = :gen_tcp.controlling_process(socket, server)
    {:ok, {_address, port}} = :inet.peername(socket)
    send(server, {:accepted, port, socket})
    accept(listener, server)
  end

  defp server_loop(acceptor, sockets) do
    receive do
      {:accepted, port, socket} ->
        server_loop(acceptor, Map.put(sockets, port, socket))

      # The acceptor can tell the connection after the test names it.
      {:close, port, from} ->
        socket =
          Map.get_lazy(sockets, port, fn ->
            receive do
              {:accepted, ^port, socket} -> socket
            end
          end)

        :gen_tcp.close(socket)
        send(from, :closed)
        server_loop(acceptor, Map.delete(sockets, port))
    end
  end

  defp start_client(system, name) do
    test = self()
    pid = spawn(fn -> client(test, system.pool, system.port, %{holder: "none", slot: nil}) end)
    put_in(system.clients[name], pid)
  end

  # A client speaks the protocol of the pool. It does one command at a
  # time. After each message to the pool, it waits until the pool handled
  # it: an answer of the pool to that message is then in its mailbox.
  defp client(test, pool, port, state) do
    receive do
      {:command, command} ->
        state = client_command(command, pool, port, state)
        send(test, {:client, self(), {state.holder, state.slot}})
        client(test, pool, port, state)
    end
  end

  defp client_command("Checkout", pool, port, state) do
    slot = make_ref()
    send(pool, {:checkout, self(), slot})
    _sync = :sys.get_state(pool)
    take_grant(%{state | holder: "waiting", slot: slot}, port)
  end

  defp client_command("Return", pool, _port, state) do
    {:ok, conn} = Mint.HTTP.controlling_process(state.conn, pool)
    send(pool, {:checkin, state.slot, conn})
    _sync = :sys.get_state(pool)
    %{holder: "none", slot: nil}
  end

  defp client_command("Release", pool, _port, state) do
    Mint.HTTP.close(state.conn)
    send(pool, {:checkin, state.slot, :closed})
    _sync = :sys.get_state(pool)
    %{holder: "none", slot: nil}
  end

  defp client_command("Cancel", pool, _port, state) do
    slot = state.slot
    send(pool, {:cancel, self(), slot})
    assert_receive {^slot, :canceled}, 2_000
    %{holder: "none", slot: nil}
  end

  defp client_command(:status, _pool, port, state), do: take_grant(state, port)

  # A client that waits can have its grant in its mailbox. With a slot, the
  # client opens its connection.
  defp take_grant(%{holder: "waiting", slot: slot} = state, port) do
    receive do
      {^slot, {:conn, conn}} ->
        Map.merge(state, %{holder: "conn", conn: conn})

      {^slot, :connect} ->
        {:ok, conn} = Mint.HTTP.connect(:http, "localhost", port, mode: :passive)
        Map.merge(state, %{holder: "slot", conn: conn})
    after
      0 -> state
    end
  end

  defp take_grant(state, _port), do: state

  defp call(system, name, command) do
    pid = system.clients[name]
    send(pid, {:command, command})

    receive do
      {:client, ^pid, result} -> result
    after
      2_000 -> flunk("the client #{name} gave no answer")
    end
  end

  # ---------------------------------------------------------------------------
  # One operation, on the real pool and on the specification
  # ---------------------------------------------------------------------------

  defp run("ServerClose", model, system) do
    if SpecModel.enabled?(model, "ServerClose") do
      [conn | _rest] = idle = :sys.get_state(system.pool).idle
      {:ok, {_address, port}} = :inet.sockname(Mint.HTTP.get_socket(conn))
      send(system.server, {:close, port, self()})
      assert_receive :closed, 2_000

      # The pool sees the close, and removes the connection.
      eventually(fn -> length(:sys.get_state(system.pool).idle) == length(idle) - 1 end)
      {SpecModel.step!(model, "ServerClose"), system}
    else
      {model, system}
    end
  end

  defp run({"Stop", name}, model, system) do
    if SpecModel.enabled?(model, "Stop", [name]) do
      pid = system.clients[name]
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000

      # The pool gets the stop from its monitor: the comparison waits for
      # it.
      {SpecModel.step!(model, "Stop", [name]), start_client(system, name)}
    else
      {model, system}
    end
  end

  defp run({action, name}, model, system) do
    if SpecModel.enabled?(model, action, [name]) do
      {holder, _slot} = call(system, name, action)
      model = SpecModel.step!(model, action, [name])
      assert holder == SpecModel.get(model, "holder")[name], "#{action} of #{name}"
      {model, system}
    else
      {model, system}
    end
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end

  # ---------------------------------------------------------------------------
  # The comparison
  # ---------------------------------------------------------------------------

  # The pool does some steps after a message to it, for example at the stop
  # of a client: the comparison waits for them.
  defp assert_same_state(model, system, attempts \\ 200) do
    compare(model, system)
  rescue
    error in ExUnit.AssertionError ->
      if attempts == 0, do: reraise(error, __STACKTRACE__)
      Process.sleep(5)
      assert_same_state(model, system, attempts - 1)
  end

  defp compare(model, system) do
    statuses = Map.new(@procs, &{&1, call(system, &1, :status)})
    names_of_slots = Map.new(statuses, fn {name, {_holder, slot}} -> {slot, name} end)
    names_of_pids = Map.new(system.clients, fn {name, pid} -> {pid, name} end)
    pool = :sys.get_state(system.pool)

    holders = Map.new(statuses, fn {name, {holder, _slot}} -> {name, holder} end)
    assert holders == SpecModel.get(model, "holder")

    assert length(pool.idle) == SpecModel.get(model, "idle")

    slots = pool.slots |> Map.keys() |> MapSet.new(&Map.get(names_of_slots, &1))
    assert slots == MapSet.new(SpecModel.get(model, "slots"))

    queue = for {pid, _slot, _monitor} <- :queue.to_list(pool.waiting), do: names_of_pids[pid]
    assert queue == SpecModel.get(model, "queue")
  end
end
