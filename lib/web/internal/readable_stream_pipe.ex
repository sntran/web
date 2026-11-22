defmodule Web.Internal.ReadableStreamPipe do
  @moduledoc false

  # The algorithm ReadableStreamPipeTo of the Streams Standard.
  #
  # The process of the pipe holds the reader lock of the source and the
  # writer lock of the destination. It sends each request to a stream as a
  # call with no wait, and handles each answer when it comes. Thus it sees
  # each change of the two streams, also while a read or a write waits:
  #
  #   * It reads a chunk only when the promise `ready` of the destination
  #     fulfils, thus when the desired size of the destination is above
  #     zero. It writes each chunk immediately, and does not wait for a
  #     write before the next read.
  #   * The promises `closed` of the reader and of the writer tell it that
  #     a stream closed, or that it has an error.
  #   * An abort of the signal starts the shutdown.
  #
  # The conditions of the Standard apply in their sequence: an error of the
  # source, an error of the destination, a close of the source, and a close
  # of the destination. The shutdown waits for the writes that are not
  # complete, when the destination is writable. Then it does its action (an
  # abort, a cancel, or a close), releases the two locks, and gives the
  # result of the pipe.

  alias Web.AbortSignal
  alias Web.TypeError

  defstruct [
    :source,
    :dest,
    :source_monitor,
    :dest_monitor,
    :subscription,
    :signal,
    :source_closed,
    :dest_closed,
    :read,
    :ready,
    prevent_close: false,
    prevent_abort: false,
    prevent_cancel: false,
    # The tags of the writes that are not complete.
    writes: %{},
    # `false`, or `{:waiting, action, result}` while the shutdown waits for
    # the writes. The action and the release of the locks follow with no
    # return to the loop.
    shutdown: false,
    # The loop of reads stopped: the promise `ready` rejected.
    stopped: false
  ]

  @released_message "The stream is not available. It ended, or its owner stopped."

  @doc false
  # Pipes `source` to `dest`. The calling process holds the reader lock of
  # `source` and the writer lock of `dest`. Returns `:ok` or
  # `{:error, reason}` after the release of the two locks.
  def run(source, dest, options) when is_pid(source) and is_pid(dest) do
    state = %__MODULE__{
      source: source,
      dest: dest,
      source_monitor: Process.monitor(source),
      dest_monitor: Process.monitor(dest),
      signal: Keyword.get(options, :signal),
      prevent_close: option(options, :prevent_close),
      prevent_abort: option(options, :prevent_abort),
      prevent_cancel: option(options, :prevent_cancel)
    }

    case AbortSignal.subscribe(state.signal) do
      # The signal aborted before the pipe: only the abort applies.
      {:error, :aborted} ->
        state |> abort_algorithm(signal_reason(state.signal)) |> loop()

      {:ok, subscription} ->
        state
        |> Map.put(:subscription, subscription)
        |> watch_closed()
        |> check_initial_states()
        |> next_read()
        |> loop()
    end
  end

  # A member of the dictionary `StreamPipeOptions`.
  defp option(options, name), do: Keyword.get(options, name, false) == true

  defp signal_reason(signal), do: AbortSignal.reason(signal) || AbortSignal.default_reason()

  # The promises `closed` of the reader and of the writer.
  defp watch_closed(state) do
    %{
      state
      | source_closed: request(state.source, {:wait_closed, :reader, self()}),
        dest_closed: request(state.dest, {:wait_closed, :writer, self()})
    }
  end

  # A call with no wait: the answer comes as `{tag, reply}`.
  defp request(pid, message) do
    tag = make_ref()
    send(pid, {:"$gen_call", {self(), tag}, message})
    tag
  end

  # The states of the two streams when the pipe starts, in the sequence of
  # the conditions of the Standard.
  defp check_initial_states(state) do
    source = slots(state.source)
    dest = slots(state.dest)

    cond do
      source_errored?(source) -> source_error(state, source.error_reason)
      dest_errored?(dest) -> dest_error(state, dest_stored_error(dest))
      source_closed?(source) -> source_close(state)
      dest_closing?(dest) -> dest_close(state)
      true -> state
    end
  end

  # The slots of a stream, or `nil` for a stream that stopped.
  defp slots(nil), do: nil
  defp slots(pid), do: Web.Stream.call(pid, :get_slots, nil)

  defp source_errored?(source), do: source != nil and source.state == :errored

  # A stream that closed with chunks in its queue is still readable in the
  # Standard, until a read takes the last chunk.
  defp source_closed?(source),
    do: source != nil and source.state == :closed and :queue.is_empty(source.queue)

  # The writable side of a transform stream is errored when its readable side
  # was cancelled or terminated.
  defp dest_errored?(dest) do
    dest != nil and (dest.state == :errored or match?({:errored, _reason}, dest.writable_error))
  end

  defp dest_stored_error(%{writable_error: {:errored, reason}}), do: reason
  defp dest_stored_error(dest), do: dest.error_reason

  # WritableStreamCloseQueuedOrInFlight, or the state "closed". A stream
  # that stopped is a closed stream.
  defp dest_closing?(nil), do: true

  defp dest_closing?(dest) do
    dest.state in [:closed, :closing] or not is_nil(dest.pending_close_request)
  end

  # The destination is writable, with no close queued or in flight.
  defp dest_writable?(state) do
    case slots(state.dest) do
      %{state: :writable, pending_close_request: nil} -> true
      _other -> false
    end
  end

  # ---------------------------------------------------------------------------
  # The loop
  # ---------------------------------------------------------------------------

  # The next step of the loop of reads: wait for the promise `ready`, and
  # then read one chunk.
  defp next_read(%{shutdown: false, stopped: false, read: nil, ready: nil} = state) do
    %{state | ready: request(state.dest, {:ready, self()})}
  end

  defp next_read(state), do: state

  defp loop({:done, result}), do: result

  defp loop(state) do
    %{source_closed: source_closed, dest_closed: dest_closed, read: read, ready: ready} = state

    receive do
      {^ready, reply} ->
        state |> Map.put(:ready, nil) |> handle_ready(reply) |> loop()

      {^read, reply} ->
        state |> Map.put(:read, nil) |> handle_read(reply) |> loop()

      {^source_closed, reply} ->
        state |> handle_source_closed(reply) |> loop()

      {^dest_closed, reply} ->
        state |> handle_dest_closed(reply) |> loop()

      {tag, reply} when is_map_key(state.writes, tag) ->
        state |> handle_write(tag, reply) |> loop()

      {:DOWN, ref, :process, _pid, _reason} = down ->
        state |> handle_down(ref, down) |> loop()

      {:abort, _key, _reason} = message ->
        state |> handle_abort(message) |> loop()

      {:abort, _key} = message ->
        state |> handle_abort(message) |> loop()
    end
  end

  defp handle_ready(state, :ok) do
    if state.shutdown == false do
      %{state | read: request(state.source, {:read, self()})}
    else
      state
    end
  end

  # The destination is erroring or errored. Its promise `closed` gives the
  # error.
  defp handle_ready(state, {:error, _reason}), do: %{state | stopped: true}

  # A chunk that the pipe read is written, also while the shutdown waits for
  # the writes.
  defp handle_read(state, {:ok, chunk}) do
    tag = request(state.dest, {:write, self(), chunk})
    next_read(%{state | writes: Map.put(state.writes, tag, true)})
  end

  defp handle_read(state, :done), do: source_close(state)

  # The source is errored. Its promise `closed` gives the error before the
  # answer of the read.
  defp handle_read(state, {:error, _reason}), do: state

  # The source closed. With no read in progress, the queue of the source
  # tells if it has chunks: only the pipe reads them. A read in progress
  # gives the end of the stream, or a chunk that the queue had.
  defp handle_source_closed(%{read: nil} = state, :ok) do
    if source_closed?(slots(state.source)), do: source_close(state), else: state
  end

  defp handle_source_closed(state, :ok), do: state

  defp handle_source_closed(state, {:error, {:errored, reason}}), do: source_error(state, reason)

  # Only the pipe can close the destination, and it does that in its last
  # step. Thus the promise `closed` of the writer can only reject here.
  defp handle_dest_closed(state, {:error, {:errored, reason}}), do: dest_error(state, reason)

  # The shutdown waits until each write is complete.
  defp handle_write(state, tag, _reply) do
    state = %{state | writes: Map.delete(state.writes, tag)}

    case state.shutdown do
      {:waiting, action, error} when state.writes == %{} -> act(state, action, error)
      _other -> state
    end
  end

  # A stream that stopped is closed: its lifetime ended. The lock of a pipe
  # does not keep the destination. The writes to a destination that stopped
  # are complete. An action does not go to a stream that stopped.
  defp handle_down(state, ref, down) do
    cond do
      ref == state.source_monitor ->
        source_error(%{state | source: nil}, TypeError.exception(@released_message))

      ref == state.dest_monitor ->
        state = %{state | dest: nil}

        case state.shutdown do
          {:waiting, action, result} -> act(state, action, result)
          false -> dest_error(state, TypeError.exception(@released_message))
        end

      true ->
        handle_abort(state, down)
    end
  end

  defp handle_abort(state, message) do
    case abort_reason(state.subscription, message) do
      {:ok, reason} -> abort_algorithm(state, reason)
      :error -> state
    end
  end

  # The reason of an abort of the signal, as `AbortSignal.receive_abort/3`
  # gives it for each kind of signal.
  defp abort_reason(%{type: :abort_signal, ref: ref}, {:abort, ref, reason}), do: {:ok, reason}

  defp abort_reason(%{type: :abort_signal, monitor_ref: ref}, {:DOWN, ref, _, _, exit_reason}) do
    case exit_reason do
      {:shutdown, {:aborted, reason}} -> {:ok, reason}
      _no_abort -> {:ok, AbortSignal.default_reason()}
    end
  end

  defp abort_reason(%{type: :pid, pid: pid}, {:abort, pid, reason}), do: {:ok, reason}

  defp abort_reason(%{type: :pid, monitor_ref: ref}, {:DOWN, ref, _, _, reason}),
    do: {:ok, reason}

  defp abort_reason(%{type: :token, token: token}, {:abort, token, reason}), do: {:ok, reason}

  defp abort_reason(%{type: :token, token: token}, {:abort, token}),
    do: {:ok, AbortSignal.default_reason()}

  defp abort_reason(_subscription, _message), do: :error

  # ---------------------------------------------------------------------------
  # The conditions of the Standard
  # ---------------------------------------------------------------------------

  # Errors must be propagated forward.
  defp source_error(%{prevent_abort: true} = state, reason),
    do: shutdown(state, nil, {:error, reason})

  defp source_error(state, reason), do: shutdown(state, {:abort, reason}, {:error, reason})

  # Errors must be propagated backward.
  defp dest_error(%{prevent_cancel: true} = state, reason),
    do: shutdown(state, nil, {:error, reason})

  defp dest_error(state, reason), do: shutdown(state, {:cancel, reason}, {:error, reason})

  # Closing must be propagated forward.
  defp source_close(%{prevent_close: true} = state), do: shutdown(state, nil, :ok)
  defp source_close(state), do: shutdown(state, :close, :ok)

  # Closing must be propagated backward.
  defp dest_close(state) do
    error = TypeError.exception("The destination stream closed before the pipe was complete.")

    if state.prevent_cancel,
      do: shutdown(state, nil, {:error, error}),
      else: shutdown(state, {:cancel, error}, {:error, error})
  end

  # The abort algorithm of the signal: an abort of the destination, and
  # then a cancel of the source. The pipe waits for the two actions.
  defp abort_algorithm(state, reason) do
    actions =
      Enum.reject(
        [
          if(not state.prevent_abort, do: {:abort_if_writable, reason}),
          if(not state.prevent_cancel, do: {:cancel_if_readable, reason})
        ],
        &is_nil/1
      )

    shutdown(state, {:all, actions}, {:error, reason})
  end

  # ---------------------------------------------------------------------------
  # Shutdown and finalize
  # ---------------------------------------------------------------------------

  # Shutdown, with or with no action. The result is the result of the pipe,
  # unless the action rejects.
  defp shutdown(%{shutdown: false} = state, action, result) do
    if state.writes != %{} and dest_writable?(state) do
      %{state | shutdown: {:waiting, action, result}}
    else
      act(state, action, result)
    end
  end

  defp shutdown(state, _action, _result), do: state

  defp act(state, nil, result), do: finalize(state, result)

  defp act(state, action, result) do
    case wait_all(start_actions(state, action)) do
      :ok -> finalize(state, result)
      {:error, reason} -> finalize(state, {:error, reason})
    end
  end

  # Starts the action. Returns the tags of the calls, each with the function
  # that changes its answer into `:ok` or `{:error, reason}`.
  #
  # The actions of the abort algorithm start in their sequence. Each action
  # starts when the action before it did the steps that the Standard does
  # before it returns: see "The abort action of a pipe" in `Web.Stream`.
  defp start_actions(state, {:all, actions}) do
    Enum.flat_map(actions, fn action ->
      state |> start_actions(action) |> Enum.map(&await_steps/1)
    end)
  end

  # The destination checks its state: see `Web.Stream`.
  defp start_actions(%{dest: nil}, {:abort_if_writable, _reason}), do: []

  defp start_actions(state, {:abort_if_writable, reason}) do
    tag = request(state.dest, {:pipe_abort, self(), reason})
    [{tag, state.dest_monitor, &Function.identity/1, :steps}]
  end

  defp start_actions(state, {:cancel_if_readable, reason}) do
    if readable?(slots(state.source)), do: start_actions(state, {:cancel, reason}), else: []
  end

  defp start_actions(%{dest: nil}, {:abort, _reason}), do: []

  defp start_actions(state, {:abort, reason}) do
    [{request(state.dest, {:abort, self(), reason}), state.dest_monitor, &Function.identity/1}]
  end

  defp start_actions(state, {:cancel, reason}) do
    request = request(state.source, {:terminate, :cancel, reason})
    [{request, state.source_monitor, &Function.identity/1}]
  end

  # WritableStreamDefaultWriterCloseWithErrorPropagation.
  defp start_actions(state, :close) do
    dest = slots(state.dest)

    cond do
      dest_errored?(dest) -> [{:settled, {:error, dest_stored_error(dest)}}]
      dest_closing?(dest) -> []
      true -> [{request(state.dest, {:close, self()}), state.dest_monitor, &close_result/1}]
    end
  end

  # The source state "readable" of the Standard: a stream that closed with
  # chunks in its queue is readable.
  defp readable?(source),
    do: source != nil and source.state != :errored and not source_closed?(source)

  defp close_result({:error, {:errored, reason}}), do: {:error, reason}
  defp close_result(_closed), do: :ok

  # Waits until the destination did the first steps of its abort: it sends
  # `{:abort_steps_done, tag}`, or the reply of the abort. A stream that
  # stopped did all its steps. The pipe takes each other message when it
  # comes, as `collect/2` does: an answer to an earlier request, or the stop
  # of the signal or of the source.
  defp await_steps({tag, monitor, result, :steps} = action) do
    receive do
      {:abort_steps_done, ^tag} -> {tag, monitor, result}
      {^tag, reply} -> {:settled, result.(reply)}
      {:DOWN, ^monitor, :process, _pid, _reason} -> {:settled, :ok}
      {other, _reply} when is_reference(other) -> await_steps(action)
      {:DOWN, _other, :process, _pid, _reason} -> await_steps(action)
    end
  end

  defp await_steps(action), do: action

  # The result of all the actions: `:ok`, or the first rejection in the
  # sequence of the actions. The pipe waits for each action, thus the result
  # does not depend on which stream answers first. It takes each answer when
  # it comes: a message that waits in the mailbox is work for the process.
  defp wait_all(actions) do
    results = collect(actions, settled_results(actions))
    Enum.find_value(actions, :ok, &error(result_of(&1, results)))
  end

  # An action that has its result before the wait: a close of a destination
  # that is errored, or an abort that a stream answered at once.
  defp settled_results(actions) do
    for {{:settled, result}, index} <- Enum.with_index(actions), into: %{}, do: {index, result}
  end

  defp result_of({:settled, result}, _results), do: result
  defp result_of({tag, _monitor, _result}, results), do: Map.fetch!(results, tag)

  defp collect(actions, results) when map_size(results) == length(actions), do: results

  defp collect(actions, results) do
    receive do
      {tag, reply} when is_reference(tag) ->
        case List.keyfind(actions, tag, 0) do
          {^tag, _monitor, result} -> collect(actions, Map.put(results, tag, result.(reply)))
          nil -> collect(actions, results)
        end

      # A stream that stopped gives no more answers: its action is complete.
      {:DOWN, monitor, :process, _pid, _reason} ->
        done = for {tag, ^monitor, _result} <- actions, do: {tag, :ok}
        collect(actions, Map.merge(Map.new(done), results))
    end
  end

  defp error({:error, _reason} = error), do: error
  defp error(:ok), do: nil

  # Releases the two locks, and gives the result of the pipe.
  defp finalize(state, result) do
    release(state.dest, {:release_lock, :writer, self()})
    release(state.source, {:release_lock, :reader, self()})
    AbortSignal.unsubscribe(state.subscription)
    Process.demonitor(state.source_monitor, [:flush])
    Process.demonitor(state.dest_monitor, [:flush])
    {:done, result}
  end

  defp release(nil, _message), do: :ok
  defp release(pid, message), do: Web.Stream.call(pid, message, :ok)
end
