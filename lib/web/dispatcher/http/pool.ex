defmodule Web.Dispatcher.HTTP.Pool do
  @moduledoc false

  # The connections of one origin, for the settings `[:http1]` and
  # `[:http1, :http2]`. An origin is the scheme, the host, and the port.
  #
  # The pool gives each connection to one request at a time. It gives the
  # socket to the process of the request, and that process gives the socket
  # back at the end of the response. Thus the messages of the response go
  # to the process of the request directly.
  #
  #   * A request gets an idle connection: the connection that came back
  #     last, which has the smallest chance to be closed.
  #   * With no idle connection, and less than 25 connections, the request
  #     gets a slot: it opens a new connection itself.
  #   * Else the request waits with no time limit, as in a browser. The
  #     signal of the request stops the wait: see `{:cancel, pid, slot}`.
  #
  # The pool monitors each process that has a connection or a slot, and
  # each process that waits. A process that stops gives back its slot: its
  # socket closes with it.
  #
  # The pool keeps its idle connections in the active mode of the socket:
  # it sees when the server closes one, and removes it.

  use GenServer

  # The connections of one origin.
  @size 25

  @registry Web.Dispatcher.HTTP.Registry
  @supervisor Web.Dispatcher.HTTP.Connections

  @doc false
  def child_spec(origin) do
    %{id: {__MODULE__, origin}, start: {__MODULE__, :start_link, [origin]}, restart: :temporary}
  end

  @doc false
  def start_link(origin) do
    GenServer.start_link(__MODULE__, origin,
      name: {:via, Registry, {@registry, {__MODULE__, origin}}}
    )
  end

  @doc "The pool of an origin. The pool starts at the first request."
  @spec get({:http | :https, String.t(), :inet.port_number()}) :: pid()
  def get(origin) do
    case Registry.lookup(@registry, {__MODULE__, origin}) do
      [{pid, _value}] -> pid
      [] -> start(origin)
    end
  end

  defp start(origin) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, origin}) do
      {:ok, pid} -> pid
      # Two requests started the pool at the same time.
      # coveralls-ignore-next-line
      {:error, {:already_started, pid}} -> pid
    end
  end

  @impl true
  def init(origin) do
    {:ok, %{origin: origin, idle: [], slots: %{}, owners: %{}, waiting: :queue.new()}}
  end

  @impl true
  def handle_info({:checkout, pid, slot}, state) do
    {:noreply, grant(state, {pid, slot, Process.monitor(pid)})}
  end

  # A connection, or `:closed` for a slot whose connection closed. Each
  # slot comes back one time: a process gives it back before it stops.
  def handle_info({:checkin, slot, conn}, state) do
    {monitor, slots} = Map.pop!(state.slots, slot)
    Process.demonitor(monitor, [:flush])
    state = %{state | slots: slots, owners: Map.delete(state.owners, monitor)}
    {:noreply, state |> keep(conn) |> serve()}
  end

  # The process does not wait more. The answer comes after a connection
  # that the pool gave before, thus the process gives that one back.
  def handle_info({:cancel, pid, slot}, state) do
    {waiting, removed} = remove_waiting(state.waiting, &(elem(&1, 1) == slot))
    for {_pid, _slot, monitor} <- removed, do: Process.demonitor(monitor, [:flush])
    send(pid, {slot, :canceled})
    {:noreply, %{state | waiting: waiting}}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.owners, monitor) do
      {nil, _owners} ->
        {waiting, _removed} = remove_waiting(state.waiting, &(elem(&1, 2) == monitor))
        {:noreply, %{state | waiting: waiting}}

      {slot, owners} ->
        state = %{state | owners: owners, slots: Map.delete(state.slots, slot)}
        {:noreply, serve(state)}
    end
  end

  # A message of the socket of an idle connection: the server closed it, or
  # sent data with no request.
  def handle_info(message, state) do
    {:noreply, %{state | idle: idle_message(state.idle, message, [])}}
  end

  defp idle_message([], _message, checked), do: :lists.reverse(checked)

  defp idle_message([conn | rest], message, checked) do
    case Mint.HTTP.stream(conn, message) do
      :unknown ->
        idle_message(rest, message, [conn | checked])

      {:ok, conn, _responses} ->
        if Mint.HTTP.open?(conn),
          do: :lists.reverse(checked, [conn | rest]),
          else: close_and_join(conn, checked, rest)

      {:error, conn, _reason, _responses} ->
        close_and_join(conn, checked, rest)
    end
  end

  defp close_and_join(conn, checked, rest) do
    Mint.HTTP.close(conn)
    :lists.reverse(checked, rest)
  end

  # An idle connection, a slot for a new connection, or a wait.
  defp grant(state, {pid, slot, monitor} = waiter) do
    case take_idle(state.idle, pid) do
      {:ok, conn, idle} ->
        send(pid, {slot, {:conn, conn}})
        borrow(%{state | idle: idle}, waiter)

      {:none, idle} ->
        state = %{state | idle: idle}

        if length(idle) + map_size(state.slots) < @size do
          send(pid, {slot, :connect})
          borrow(state, waiter)
        else
          %{state | waiting: :queue.in({pid, slot, monitor}, state.waiting)}
        end
    end
  end

  defp borrow(state, {_pid, slot, monitor}) do
    %{
      state
      | slots: Map.put(state.slots, slot, monitor),
        owners: Map.put(state.owners, monitor, slot)
    }
  end

  # The socket goes to the process of the request. A connection that closed
  # goes away.
  defp take_idle([], _pid), do: {:none, []}

  defp take_idle([conn | rest], pid) do
    with true <- Mint.HTTP.open?(conn),
         {:ok, conn} <- Mint.HTTP.set_mode(conn, :passive),
         {:ok, conn} <- Mint.HTTP.controlling_process(conn, pid) do
      {:ok, conn, rest}
    else
      _closed ->
        Mint.HTTP.close(conn)
        take_idle(rest, pid)
    end
  end

  defp keep(state, :closed), do: state

  defp keep(state, conn) do
    case Mint.HTTP.set_mode(conn, :active) do
      {:ok, conn} ->
        %{state | idle: [conn | state.idle]}

      {:error, _reason} ->
        Mint.HTTP.close(conn)
        state
    end
  end

  # The processes that wait get the free connections and slots.
  defp serve(state) do
    case :queue.out(state.waiting) do
      {{:value, waiter}, waiting} ->
        if state.idle != [] or length(state.idle) + map_size(state.slots) < @size,
          do: %{state | waiting: waiting} |> grant(waiter) |> serve(),
          else: state

      {:empty, _waiting} ->
        state
    end
  end

  defp remove_waiting(waiting, fun) do
    {removed, kept} = waiting |> :queue.to_list() |> Enum.split_with(fun)
    {:queue.from_list(kept), removed}
  end
end
