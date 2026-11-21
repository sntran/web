defmodule Web.Internal.ReadableByteStreamTee do
  @moduledoc false

  # The algorithm ReadableByteStreamTee of the Streams Standard.
  #
  # One process holds the reader lock of the source and keeps the state of
  # the algorithm. The two branches are byte streams. The `pull` callback of
  # a branch sends a pull to this process, and the `cancel` callback records
  # the cancel. The two callbacks do not wait.
  #
  #   * pull1Algorithm and pull2Algorithm take the BYOB request of the branch
  #     when they run: here, when this process starts the read. A BYOB
  #     request of the time of the message can be old: its read ended.
  #   * A pull of a branch with no BYOB request reads the source with a
  #     default reader. The chunk goes to the two branches: the second
  #     branch gets a copy.
  #   * A pull of a branch with a BYOB request reads the source with a BYOB
  #     reader into the view of the request. The view of the result is the
  #     response of that branch, and the other branch gets a copy.
  #   * The process changes the reader of the source when the kind of the
  #     read changes.
  #   * A pull during a read is done after the read, if the branch still
  #     wants bytes: the flags `readAgainForBranch1` and
  #     `readAgainForBranch2`. The pull callback of a branch does not wait,
  #     thus the branch does not pull again by itself.
  #   * When the source ends or has an error, the two branches end or get
  #     the error. When the two branches are cancelled, the source is
  #     cancelled with the list of the two reasons.
  #
  # A branch that stops is a cancelled branch. The process keeps the lock
  # until the source stops, because the Streams Standard never releases the
  # lock of a stream that has a tee.

  use GenServer

  alias Web.ArrayBuffer
  alias Web.ReadableByteStreamController
  alias Web.ReadableStream
  alias Web.ReadableStreamBYOBRequest
  alias Web.Uint8Array

  @type index :: 1 | 2

  # Starts the process and takes a default reader of the source.
  @spec start(pid()) :: {:ok, pid()} | {:error, :already_locked | :released}
  def start(source) when is_pid(source) do
    case GenServer.start(__MODULE__, {source, self()}) do
      {:ok, tee} -> {:ok, tee}
      {:error, {:shutdown, reason}} -> {:error, reason}
    end
  end

  # Gives the two branches to the process. The process does no read before
  # this call.
  @spec attach(pid(), pid(), pid()) :: :ok
  def attach(tee, branch1, branch2), do: GenServer.call(tee, {:attach, branch1, branch2})

  # The pull algorithm of a branch.
  @spec pull(pid(), index()) :: :ok
  def pull(tee, index), do: GenServer.cast(tee, {:pull, index})

  # The cancel algorithm of a branch: see `Web.Internal.ReadableStreamTee`.
  @spec cancel(pid(), index(), term()) :: Web.Promise.t()
  def cancel(tee, index, reason) do
    GenServer.cast(tee, {:cancel, index, reason})

    Web.Promise.new(fn resolve, reject ->
      case wait_complete(tee) do
        :ok -> resolve.(:ok)
        {:error, thrown} -> reject.(thrown)
      end
    end)
  end

  defp wait_complete(tee) do
    GenServer.call(tee, :wait_complete, :infinity)
  catch
    # The tee stopped: its work is complete.
    :exit, _reason -> :ok
  end

  @impl true
  def init({source, caller}) do
    case ReadableStream.get_reader(source) do
      :ok ->
        state = %{
          source: source,
          caller: Process.monitor(caller),
          branches: nil,
          # The kind of the reader of the source: `:default` or `:byob`.
          reader: :default,
          # The read that is in progress: `{request_id, kind}`, or `nil`.
          read: nil,
          # The request for the end of the reader. Its reply forwards an
          # error of the source to the branches.
          closed_request: nil,
          canceled: %{},
          complete_waiters: [],
          result: :ok,
          source_monitor: nil,
          # The branches that pulled during the read that is in progress.
          read_again: MapSet.new()
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:shutdown, reason}}
    end
  end

  defp wait_closed(source), do: :gen_statem.send_request(source, {:wait_closed, :reader, self()})

  @impl true
  def handle_call({:attach, branch1, branch2}, _from, state) do
    Process.demonitor(state.caller, [:flush])

    branches = %{
      1 => {branch1, Process.monitor(branch1)},
      2 => {branch2, Process.monitor(branch2)}
    }

    # The request for the end of the reader comes after the branches: the
    # reply of an errored source gives its error to the branches.
    state = %{state | caller: nil, branches: branches, closed_request: wait_closed(state.source)}
    {:reply, :ok, state}
  end

  def handle_call(:wait_complete, _from, %{source_monitor: monitor} = state)
      when is_reference(monitor) do
    {:reply, state.result, state}
  end

  def handle_call(:wait_complete, from, state) do
    {:noreply, %{state | complete_waiters: [from | state.complete_waiters]}}
  end

  @impl true
  def handle_cast(_message, %{source_monitor: monitor} = state) when is_reference(monitor) do
    {:noreply, state}
  end

  def handle_cast({:pull, index}, %{read: {_id, _kind}} = state) do
    {:noreply, %{state | read_again: MapSet.put(state.read_again, index)}}
  end

  # A pull is a message, thus it can come after a read that gave the branch
  # its bytes. The process reads only for a branch that still wants bytes.
  def handle_cast({:pull, index}, state) do
    if branch_wants_chunk?(state, index) do
      {:noreply, pull_branch(index, state)}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:cancel, index, reason}, state), do: cancel_branch(index, reason, state)

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{caller: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{source_monitor: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, %{source_monitor: monitor} = state) when is_reference(monitor) do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason} = message, state) do
    case branch_index(state, pid, ref) do
      nil -> handle_response(message, state)
      index -> cancel_branch(index, {:branch_down, reason}, state)
    end
  end

  def handle_info(message, state), do: handle_response(message, state)

  # ---------------------------------------------------------------------------
  # The pulls
  # ---------------------------------------------------------------------------

  # pull1Algorithm and pull2Algorithm, with the BYOB request of the branch
  # of now.
  defp pull_branch(index, state) do
    case ReadableByteStreamController.byob_request(controller(state, index)) do
      nil -> pull_with_default_reader(state)
      %ReadableStreamBYOBRequest{} = request -> pull_with_byob_reader(index, request, state)
    end
  end

  defp pull_with_default_reader(state) do
    state = use_reader(state, :default)
    id = :gen_statem.send_request(state.source, {:read, self()})
    %{state | read: {id, :default}}
  end

  defp pull_with_byob_reader(index, request, state) do
    state = use_reader(state, :byob)
    id = :gen_statem.send_request(state.source, {:byob_read, self(), request.view, 1})
    %{state | read: {id, {:byob, index, request}}}
  end

  # The reader of the source has the kind of the read. A new reader gets a
  # new request for its end: the reply to the request of the old reader has
  # no effect.
  defp use_reader(%{reader: kind} = state, kind), do: state

  defp use_reader(state, kind) do
    :ok = ReadableStream.release_lock(state.source, self())
    mode = if kind == :byob, do: [mode: "byob"], else: []
    :ok = ReadableStream.get_reader(state.source, mode)
    %{state | reader: kind, closed_request: wait_closed(state.source)}
  end

  # The message is the reply to the read that is in progress, the reply to
  # the request for the end of the reader, or a message with no use.
  defp handle_response(message, state) do
    read = check_response(message, state.read)
    closed = check_response(message, state.closed_request)

    case {read, closed} do
      {{:reply, reply}, _closed} ->
        {_id, kind} = state.read
        {:noreply, state} = handle_read(kind, reply, %{state | read: nil})
        {:noreply, read_again(state)}

      {_read, {:reply, {:error, {:errored, reason}}}} ->
        {:noreply, fail_branches(reason, %{state | closed_request: nil})}

      {_read, {:reply, _closed_or_released}} ->
        {:noreply, %{state | closed_request: nil}}

      {:no_reply, :no_reply} ->
        {:noreply, state}

      # The source stopped: one of the two requests got no reply.
      _source_stopped ->
        {:noreply, fail_branches(released_error(), %{state | read: nil})}
    end
  end

  defp check_response(_message, nil), do: :no_reply
  defp check_response(message, {id, _kind}), do: :gen_statem.check_response(message, id)
  defp check_response(message, id), do: :gen_statem.check_response(message, id)

  # The chunk steps, the close steps, and the error steps of the read
  # requests.
  defp handle_read(:default, {:ok, chunk}, state) do
    chunk2 = if map_size(state.canceled) == 0, do: clone(chunk), else: chunk
    if active?(state, 1), do: ReadableStream.enqueue(branch(state, 1), chunk)
    if active?(state, 2), do: ReadableStream.enqueue(branch(state, 2), chunk2)
    {:noreply, state}
  end

  defp handle_read(:default, :done, state) do
    for index <- [1, 2], active?(state, index), do: ReadableStream.close(branch(state, index))
    for index <- [1, 2], do: respond_with_zero(state, index)
    {:noreply, complete(state)}
  end

  # The copy comes first: the response takes the buffer of the chunk.
  defp handle_read({:byob, index, request}, {:ok, chunk}, state) do
    other = other(index)
    copy = if active?(state, other), do: clone(chunk)
    if active?(state, index), do: respond_with_new_view(request, chunk)
    if copy, do: ReadableStream.enqueue(branch(state, other), copy)
    {:noreply, state}
  end

  defp handle_read({:byob, index, request}, done, state)
       when done == :done or elem(done, 0) == :done do
    other = other(index)
    if active?(state, index), do: ReadableStream.close(branch(state, index))
    if active?(state, other), do: ReadableStream.close(branch(state, other))

    case done do
      {:done, %Uint8Array{} = chunk} ->
        if active?(state, index), do: respond_with_new_view(request, chunk)

      # No chunk: the source was canceled during the read. In the Standard,
      # only the tee cancels its source, after the cancel of the two
      # branches, thus no branch is active here. The library can also cancel
      # the source, for example when its owner stops.
      :done ->
        if active?(state, index), do: end_dropped_request(state, index)
    end

    respond_with_zero(state, other)
    {:noreply, complete(state)}
  end

  # The error steps. The reply to the request for the end of the reader
  # gives the error to the branches.
  defp handle_read(_kind, {:error, _reason}, state), do: {:noreply, state}

  # readAgainForBranch1, then readAgainForBranch2: the first branch that
  # pulled during the read, and still wants bytes, pulls now with its BYOB
  # request of now. The flag of the other branch stays for the next read.
  defp read_again(%{read: nil, source_monitor: nil} = state) do
    wants? = &(active?(state, &1) and branch_wants_chunk?(state, &1))

    case Enum.find(Enum.sort(state.read_again), wants?) do
      nil ->
        %{state | read_again: MapSet.new()}

      index ->
        pull_branch(index, %{state | read_again: MapSet.delete(state.read_again, index)})
    end
  end

  defp read_again(state), do: state

  # ReadableByteStreamControllerRespond(controller, 0) for a branch with
  # pending pull-into descriptors, after its close.
  defp respond_with_zero(state, index) do
    with true <- active?(state, index),
         %ReadableStreamBYOBRequest{} = request <-
           ReadableByteStreamController.byob_request(controller(state, index)) do
      safely(fn -> ReadableStreamBYOBRequest.respond(request, 0) end)
    end
  end

  # The buffer of the BYOB request went to the read of the source, and the
  # cancel of the source dropped it. The request ends as a read of a closed
  # stream: with a view of 0 bytes, in a new buffer of the same size.
  defp end_dropped_request(state, index) do
    with %ReadableStreamBYOBRequest{view: view} = request <-
           ReadableByteStreamController.byob_request(controller(state, index)) do
      buffer = ArrayBuffer.new(view.buffer.byte_length)
      respond_with_new_view(request, Uint8Array.new(buffer, view.byte_offset, 0))
    end
  end

  defp respond_with_new_view(request, chunk) do
    safely(fn -> ReadableStreamBYOBRequest.respond_with_new_view(request, chunk) end)
  end

  # A branch that a different process errored refuses the response.
  defp safely(fun) do
    fun.()
  rescue
    _error in [Web.TypeError, Web.RangeError] -> :ok
  end

  # CloneAsUint8Array.
  defp clone(%Uint8Array{} = chunk), do: chunk |> Uint8Array.to_binary() |> Uint8Array.from()

  # ---------------------------------------------------------------------------
  # The end
  # ---------------------------------------------------------------------------

  defp fail_branches(reason, state) do
    for index <- [1, 2],
        active?(state, index),
        do: ReadableStream.error(branch(state, index), reason)

    complete(state)
  end

  defp released_error do
    Web.TypeError.exception("The stream is not available. It ended, or its owner stopped.")
  end

  # The work is complete. The process waits for the stop of the source.
  defp complete(state) do
    for {_index, {_pid, monitor}} <- state.branches, do: Process.demonitor(monitor, [:flush])
    for waiter <- state.complete_waiters, do: GenServer.reply(waiter, state.result)

    %{
      state
      | read: nil,
        closed_request: nil,
        complete_waiters: [],
        source_monitor: Process.monitor(state.source)
    }
  end

  # The first reason of a branch is its reason.
  defp cancel_branch(index, reason, state) do
    canceled = Map.put_new(state.canceled, index, reason)
    state = %{state | canceled: canceled}

    if map_size(canceled) == 2 do
      result = Web.Stream.terminate_and_wait(state.source, :cancel, [canceled[1], canceled[2]])
      {:noreply, complete(%{state | result: result})}
    else
      {:noreply, state}
    end
  end

  # ---------------------------------------------------------------------------
  # The branches
  # ---------------------------------------------------------------------------

  defp branch_index(%{branches: branches}, pid, ref) do
    Enum.find_value(branches || %{}, fn {index, branch} ->
      if branch == {pid, ref}, do: index
    end)
  end

  defp branch_wants_chunk?(state, index),
    do: Web.Stream.call(branch(state, index), :wants_chunk?, false)

  defp branch(%{branches: branches}, index), do: branches |> Map.fetch!(index) |> elem(0)
  defp controller(state, index), do: %ReadableByteStreamController{pid: branch(state, index)}
  defp active?(state, index), do: not is_map_key(state.canceled, index)
  defp other(1), do: 2
  defp other(2), do: 1
end
