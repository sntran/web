defmodule Web.ReadableStream do
  @moduledoc """
  An Elixir implementation of the WHATWG ReadableStream standard.

  Provides a way to represent a stream of data that can be consumed or multicasted (teed).
  The implementation follows the Web API concepts, including:

  - **Backpressure**: The stream respects the consumption speed of its readers.
  - **Locking**: A stream can be locked to a single reader using `get_reader/1`.
  - **Teeing**: A stream can be split into two branches via `tee/1`.

  ## Technical Implementation Notes

  ### [[disturbed]] slot
  In the WHATWG spec, a stream is "disturbed" once data has been requested from it or it
  has been cancelled. In this implementation, the `[[disturbed]]` state prevents certain
  operations like `tee/1` if the stream has already been interacted with.

  ### Teeing and Backpressure
  The `tee/1` implementation is built via stream composition: data is piped into a multicaster
  writable sink that forwards each chunk into two identity `TransformStream` branches.
  Because each multicaster write waits for both branch writes to settle, branch backpressure
  naturally throttles upstream pulling.
  """

  use Web.Stream

  defstruct [:controller_pid]

  @released_message "The stream is not available. It ended, or its owner stopped."

  # A key in the dictionary of the stream process: see `start_ended/2`.
  @start_ended {__MODULE__, :start_ended}

  alias Web.AbortSignal
  alias Web.ArrayBuffer
  alias Web.AsyncContext.Snapshot
  alias Web.Blob
  alias Web.Internal.ReadableStreamTee
  alias Web.Promise
  alias Web.ReadableByteStreamController
  alias Web.ReadableStreamBYOBReader
  alias Web.TypeError
  alias Web.Uint8Array
  alias Web.URLSearchParams
  alias Web.WritableStream

  # ---------------------------------------------------------------------------
  # Web.Stream behavior callbacks
  # ---------------------------------------------------------------------------

  @impl Web.Stream
  def start(pid, opts) do
    source = Keyword.get(opts, :source)
    stream_type = Keyword.get(opts, :stream_type, :default)
    state = %{source: source, pid: pid, started: false, stream_type: stream_type}

    if is_map(source) and is_function(source[:start], 1) do
      ctrl = controller_for(stream_type, pid)
      fun = source.start

      # The stream waits for a promise that the `start` callback returns.
      start = fn -> ctrl |> fun.() |> await_pull_result() end
      {:producer, state, [{:next_event, :internal, {:start_task, start}}]}
    else
      {:producer, state}
    end
  end

  @impl Web.Stream
  def pull(ctrl, %{source: %{pull: pull}} = state) when is_function(pull, 1) do
    ctrl
    |> pull.()
    |> await_pull_result()

    {:ok, %{state | started: true}}
  end

  def pull(_ctrl, %{source: source, pid: pid} = state) when is_pid(source) do
    send(source, {:pull, pid})
    {:ok, %{state | started: true}, :pause}
  end

  def pull(ctrl, %{source: {module, function, args}} = state) when is_list(args) do
    ctrl
    |> then(&apply(module, function, args ++ [&1]))

    {:ok, %{state | started: true}}
  end

  def pull(ctrl, %{source: fun} = state) when is_function(fun, 1) do
    ctrl
    |> fun.()
    |> await_pull_result()

    {:ok, %{state | started: true}}
  end

  def pull(_ctrl, state) do
    # No pull source — pause to avoid a busy-loop
    {:ok, state, :pause}
  end

  @impl Web.Stream
  def terminate({type, reason}, %{source: source, pid: pid}) when type in [:cancel, :abort] do
    do_terminate(reason, source, pid)
  end

  def terminate(reason, %{source: source, pid: pid}) do
    do_terminate(reason, source, pid)
  end

  defp controller_for(:bytes, pid), do: %ReadableByteStreamController{pid: pid}
  defp controller_for(:default, pid), do: %Web.ReadableStreamDefaultController{pid: pid}

  defp await_pull_result(%Promise{} = promise), do: Promise.await(promise)
  defp await_pull_result(_result), do: :ok

  # This function can run in a task, thus the stream is `stream`, not `self()`.
  defp do_terminate(reason, source, stream) do
    case source do
      %{cancel: cancel} when is_function(cancel, 1) ->
        cancel.(reason)

      src when is_pid(src) ->
        send(src, {:web_stream_cancel, stream, reason})

      {m, f, a} ->
        apply(m, f, a ++ [reason])

      fun when is_function(fun, 1) ->
        fun.(reason)

      _ ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new ReadableStream with the given underlying source.

  ## Examples

      iex> source = %{
      ...>   start: fn controller ->
      ...>     Web.ReadableStreamDefaultController.enqueue(controller, "hello")
      ...>     Web.ReadableStreamDefaultController.close(controller)
      ...>   end
      ...> }
      iex> stream = Web.ReadableStream.new(source)
      iex> Enum.to_list(stream)
      ["hello"]
  """
  def new(underlying_source \\ %{}, opts \\ []) when is_list(opts) do
    :ok = validate_source!(underlying_source)
    stream_type = source_stream_type(underlying_source)
    {high_water_mark, strategy} = normalize_stream_options(underlying_source, opts)

    if not is_number(high_water_mark) or high_water_mark < 0 do
      raise Web.RangeError, "Invalid high water mark: #{inspect(high_water_mark)}"
    end

    stream_opts =
      opts
      |> Keyword.put(:source, underlying_source)
      |> Keyword.put(:high_water_mark, high_water_mark)
      |> Keyword.put(:strategy, strategy)
      |> Keyword.put(:stream_type, stream_type)
      |> Keyword.put(
        :auto_allocate_chunk_size,
        source_auto_allocate_chunk_size(underlying_source)
      )

    {:ok, pid} =
      start_link(stream_opts)

    %__MODULE__{controller_pid: pid}
  end

  @doc """
  Makes a `ReadableStream` from an enumerable, or from a value of bytes.

    * An enumerable gives one chunk for each of its elements, with no
      change, as `ReadableStream.from()` of the Streams Standard does for
      an iterable.
    * A value of bytes gives a stream of bytes: each chunk is a
      `Web.Uint8Array`. A value of bytes is a binary, a `Web.Blob`, a
      `Web.ArrayBuffer`, a `Web.Uint8Array`, or a `Web.URLSearchParams` (its
      text). A binary gives one chunk. In ECMAScript, a string is an
      iterable of its code points. A binary of the BEAM is not an
      enumerable, thus this function reads it as bytes.
    * `nil` gives a stream with no chunks.
    * A `ReadableStream` is returned with no change.

  Raises `Web.TypeError` for each other value.

  ## Examples

      iex> stream = Web.ReadableStream.from(["a", "b"])
      iex> Enum.to_list(stream)
      ["a", "b"]

      iex> stream = Web.ReadableStream.from("hello")
      iex> Enum.map(stream, &Web.Uint8Array.to_binary/1)
      ["hello"]

      iex> stream = Web.ReadableStream.from(nil)
      iex> Enum.to_list(stream)
      []

      iex> existing = Web.ReadableStream.new()
      iex> Web.ReadableStream.from(existing) == existing
      true
  """
  def from(nil) do
    new(%{start: &Web.ReadableStreamDefaultController.close/1})
  end

  def from(%URLSearchParams{} = params) do
    from(URLSearchParams.to_string(params))
  end

  def from(%Blob{parts: parts}) do
    blob_parts_pid = start_blob_parts_queue(parts)

    new(%{
      pull: fn controller ->
        case ask_blob_parts_queue(blob_parts_pid) do
          :done ->
            Web.ReadableStreamDefaultController.close(controller)

          part ->
            Web.ReadableStreamDefaultController.enqueue(controller, Uint8Array.from(part))
        end
      end,
      cancel: fn _reason ->
        if Process.alive?(blob_parts_pid) do
          send(blob_parts_pid, :stop)
        end
      end
    })
  end

  # A buffer or a view gives one chunk, which is a `Web.Uint8Array`.
  def from(%ArrayBuffer{} = buffer), do: from_chunk(Uint8Array.from(buffer))
  def from(%Uint8Array{} = bytes), do: from_chunk(bytes)

  def from(data) when is_binary(data), do: from_chunk(Uint8Array.from(data))

  def from(%__MODULE__{} = stream), do: stream

  def from(enumerable), do: from_enumerable(enumerable, [])

  defp from_chunk(chunk) do
    new(%{
      start: fn controller ->
        Web.ReadableStreamDefaultController.enqueue(controller, chunk)
        Web.ReadableStreamDefaultController.close(controller)
      end
    })
  end

  @doc false
  # Makes a stream from an enumerable, with options for the stream engine.
  # The HTTP dispatcher uses the option `:unread_timeout` for a response
  # body.
  def from_enumerable(enumerable, opts) when is_list(opts) do
    if Enumerable.impl_for(enumerable) do
      enumerator_pid = start_enumerator(enumerable)

      new(
        %{
          pull: fn controller ->
            case ask_enumerator(enumerator_pid) do
              :done ->
                Web.ReadableStreamDefaultController.close(controller)

              {:chunk, chunk} ->
                Web.ReadableStreamDefaultController.enqueue(controller, chunk)
            end
          end,
          cancel: fn _reason ->
            # coveralls-ignore-start
            if Process.alive?(enumerator_pid) do
              send(enumerator_pid, :stop)
            end

            # coveralls-ignore-stop
          end
        },
        Keyword.put(opts, :cancel_on_reader_exit, true)
      )
    else
      raise TypeError, "Cannot make a ReadableStream from #{inspect(enumerable)}"
    end
  end

  defp normalize_stream_options(underlying_source, opts) do
    stream_type = source_stream_type(underlying_source)

    default_hwm =
      case underlying_source do
        %{} = source -> Map.get(source, :high_water_mark, 1)
        _ -> 1
      end

    strategy_from_source =
      case underlying_source do
        %{} = source -> Map.get(source, :strategy)
        _ -> nil
      end

    strategy =
      Keyword.get_lazy(opts, :strategy, fn ->
        strategy_from_source || default_strategy_for(stream_type, default_hwm)
      end)

    high_water_mark =
      Keyword.get(opts, :high_water_mark, Map.get(strategy, :high_water_mark, default_hwm))

    {high_water_mark, strategy}
  end

  @source_callbacks [start: 1, pull: 1, cancel: 1]

  # The checks of the Streams Standard for an underlying source that is a
  # map. A process, a function, and a module-function-arguments tuple are
  # sources of this library only, and have no such checks.
  defp validate_source!(%{} = source) when not is_struct(source) do
    if Map.get(source, :type) not in [nil, "bytes"] do
      raise TypeError, "Invalid type of the underlying source: #{inspect(source.type)}"
    end

    for {name, arity} <- @source_callbacks,
        callback = Map.get(source, name),
        not is_nil(callback) do
      if not is_function(callback, arity) do
        raise TypeError,
              "The underlying source function #{inspect(name)} must be a function with " <>
                "#{arity} argument(s), got: #{inspect(callback)}"
      end
    end

    :ok
  end

  defp validate_source!(source)
       when is_pid(source) or is_function(source, 1) or
              (is_tuple(source) and tuple_size(source) == 3),
       do: :ok

  defp validate_source!(source) do
    raise TypeError, "Invalid underlying source: #{inspect(source)}"
  end

  defp source_stream_type(%{} = source) do
    if Map.get(source, :type) == "bytes", do: :bytes, else: :default
  end

  defp source_stream_type(_underlying_source), do: :default

  defp source_auto_allocate_chunk_size(%{} = source) do
    Map.get(source, :auto_allocate_chunk_size)
  end

  defp source_auto_allocate_chunk_size(_underlying_source), do: nil

  defp default_strategy_for(:bytes, high_water_mark) do
    Web.ByteLengthQueuingStrategy.new(high_water_mark)
  end

  defp default_strategy_for(:default, high_water_mark) do
    Web.CountQueuingStrategy.new(high_water_mark)
  end

  defp reader_mode_from_options(opts) do
    case Keyword.get(opts, :mode) do
      nil -> :default
      "byob" -> :byob
      mode -> raise TypeError, "Invalid reader mode: #{inspect(mode)}"
    end
  end

  defp start_blob_parts_queue(parts) do
    spawn(fn -> blob_parts_queue_loop(parts) end)
  end

  defp blob_parts_queue_loop(parts) do
    receive do
      {:next, from, ref} ->
        case next_blob_part(parts) do
          {:ok, part, rest} ->
            send(from, {ref, part})
            blob_parts_queue_loop(rest)

          :done ->
            send(from, {ref, :done})
            :ok
        end

      :stop ->
        :ok
    end
  end

  defp next_blob_part([part | rest]) when is_binary(part), do: {:ok, part, rest}

  defp next_blob_part([%Blob{parts: nested_parts} | rest]),
    do: next_blob_part(nested_parts ++ rest)

  defp next_blob_part([]), do: :done

  defp ask_blob_parts_queue(pid) do
    ref = make_ref()
    send(pid, {:next, self(), ref})

    receive do
      {^ref, result} -> result
    end
  end

  # An error of the enumerable goes to the process that asked for the chunk.
  # That process raises it again, and the stream goes to the errored state.
  defp safe_enumerator_next(state) do
    enumerator_next(state)
  catch
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

  # The accumulator of the reduction holds the chunk. The value `:none` shows
  # that the enumerable gave no chunk.
  defp enumerator_next(:done), do: :done

  defp enumerator_next({:initial, enumerable}) do
    reducer = fn chunk, _acc -> {:suspend, {:chunk, chunk}} end
    enumerable_step(Enumerable.reduce(enumerable, {:cont, :none}, reducer))
  end

  defp enumerator_next({:continuation, continuation}) do
    enumerable_step(continuation.({:cont, :none}))
  end

  defp enumerable_step({:suspended, {:chunk, chunk}, continuation}) do
    {:chunk, chunk, {:continuation, continuation}}
  end

  # An enumerable that halts itself, such as `Stream.take/2`, gives its last
  # chunk together with the halt.
  defp enumerable_step({:halted, {:chunk, chunk}}), do: {:chunk, chunk, :done}
  defp enumerable_step({_done_or_halted, :none}), do: :done

  defp start_enumerator(enumerable) do
    spawn(fn -> enumerator_loop({:initial, enumerable}) end)
  end

  defp enumerator_loop(state) do
    receive do
      {:next, from, ref} ->
        case safe_enumerator_next(state) do
          {:chunk, chunk, next_state} ->
            send(from, {ref, {:chunk, chunk}})
            enumerator_loop(next_state)

          # The enumerable is complete, or it failed. The enumerator stops.
          last_reply ->
            send(from, {ref, last_reply})
        end

      :stop ->
        halt_enumerator(state)
    end
  end

  # Runs the code that the enumerable has for its end, for example the
  # `after` function of `Stream.resource/3`.
  defp halt_enumerator({:continuation, continuation}) do
    _ = continuation.({:halt, :none})
    :ok
  catch
    _kind, _reason -> :ok
  end

  defp halt_enumerator(_initial_or_done), do: :ok

  defp ask_enumerator(pid) do
    ref = Process.monitor(pid)
    send(pid, {:next, self(), ref})

    receive do
      {^ref, {:raised, kind, reason, stacktrace}} ->
        Process.demonitor(ref, [:flush])
        :erlang.raise(kind, reason, stacktrace)

      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        reply

      {:DOWN, ^ref, :process, ^pid, reason} when reason in [:normal, :noproc] ->
        :done

      {:DOWN, ^ref, :process, ^pid, reason} ->
        exit(reason)
    end
  end

  @doc false
  def disturbed?(nil), do: false
  def disturbed?(body) when is_binary(body) or is_list(body), do: false

  def disturbed?(%__MODULE__{controller_pid: pid}) do
    disturbed?(pid)
  end

  def disturbed?(pid) when is_pid(pid) do
    Web.Stream.call(pid, :disturbed?, true)
  end

  def disturbed?(_body), do: false

  @doc """
  Returns `true` when the stream currently has an active reader lock.
  """
  def locked?(nil), do: false
  def locked?(body) when is_binary(body) or is_list(body), do: false

  def locked?(%__MODULE__{controller_pid: pid}) do
    locked?(pid)
  end

  def locked?(pid) when is_pid(pid) do
    Web.Stream.call(pid, {:locked?, :reader}, false)
  end

  def locked?(_body), do: false

  # Private helper — reads all chunks from a stream to a binary.
  @doc """
  Locks the stream and returns a reader.

  ## Examples

      iex> stream = Web.ReadableStream.new()
      iex> reader = Web.ReadableStream.get_reader(stream)
      iex> is_struct(reader, Web.ReadableStreamDefaultReader)
      true
  """
  def get_reader(%__MODULE__{controller_pid: pid}, opts) when is_list(opts) do
    case reader_mode_from_options(opts) do
      :byob ->
        case get_reader(pid, opts) do
          :ok ->
            %ReadableStreamBYOBReader{controller_pid: pid, owner_pid: self()}

          {:error, :already_locked} ->
            raise TypeError, "ReadableStream is already locked"

          {:error, :not_byte_stream} ->
            raise TypeError, "ReadableStream is not a byte stream"

          {:error, :released} ->
            raise TypeError, @released_message
        end

      :default ->
        get_reader(%__MODULE__{controller_pid: pid})
    end
  end

  def get_reader(pid, opts) when is_pid(pid) and is_list(opts) do
    request =
      case reader_mode_from_options(opts) do
        :default -> {:get_reader, self()}
        :byob -> {:get_reader, self(), :byob}
      end

    case Web.Stream.call(pid, request, {:error, :released}) do
      {:ok, _ref} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def get_reader(pid) when is_pid(pid), do: get_reader(pid, [])

  def get_reader(%__MODULE__{controller_pid: pid}) do
    case get_reader(pid, []) do
      :ok ->
        %Web.ReadableStreamDefaultReader{controller_pid: pid, owner_pid: self()}

      {:error, :already_locked} ->
        raise TypeError, "ReadableStream is already locked"

      {:error, :released} ->
        raise TypeError, @released_message
    end
  end

  def read(pid) do
    Web.Stream.call(pid, {:read, self()}, {:error, :not_locked_by_reader})
  end

  @doc false
  def byob_read(pid, view) when is_pid(pid) do
    Web.Stream.call(pid, {:byob_read, self(), view}, {:error, :not_locked_by_reader})
  end

  def force_unknown_error(pid) do
    :gen_statem.call(pid, :force_unknown_error)
  end

  def release_lock(pid, owner \\ self()) do
    Web.Stream.call(pid, {:release_lock, :reader, owner}, :ok)
  end

  @doc false
  # The promise `closed` of a reader.
  def reader_closed(pid, owner) do
    Web.Stream.promise_call(pid, {:wait_closed, :reader, owner}, :ok, fn
      :ok ->
        {:ok, :ok}

      {:error, {:errored, reason}} ->
        {:error, reason}

      {:error, :lock_released} ->
        {:error, %TypeError{message: "This reader is no longer locked."}}
    end)
  end

  def get_desired_size(pid) do
    Web.Stream.call(pid, :get_desired_size, nil)
  end

  @doc false
  # `enqueue` with no check, for a source that is a process of this library.
  # Such a source can run at the same time as a cancel, thus a chunk for a
  # stream that is closed or errored is discarded.
  def enqueue(pid, chunk) do
    :gen_statem.cast(pid, {:enqueue, chunk})
  end

  @doc false
  # `close` with no check: see `enqueue/2`.
  def close(pid) do
    Web.Stream.control_cast(pid, :close)
  end

  @doc false
  # `enqueue` of a controller, as in the Streams Standard: raises
  # `Web.TypeError` when the stream is closed or errored.
  def controller_enqueue(pid, chunk) do
    if pid == self() do
      # The function `start` of a transform stream runs in the stream
      # process, where a call to the stream is not possible.
      start_refusal() |> controller_result("enqueue a chunk")
      enqueue(pid, chunk)
    else
      pid
      |> Web.Stream.call({:enqueue, chunk}, {:error, :closed})
      |> controller_result("enqueue a chunk")
    end
  end

  @doc false
  # `close` of a controller: see `controller_enqueue/2`.
  def controller_close(pid) do
    if pid == self() do
      start_refusal() |> controller_result("close")
      Process.put(@start_ended, :closed)
      close(pid)
    else
      pid |> Web.Stream.call(:close, {:error, :closed}) |> controller_result("close")
    end
  end

  @doc false
  # Records that the function `start` of a transform stream ended the
  # readable side. A subsequent `enqueue` in that function raises.
  def start_ended(pid, state) when state in [:closed, :errored] do
    if pid == self(), do: Process.put(@start_ended, state)
    :ok
  end

  defp start_refusal do
    case Process.get(@start_ended) do
      nil -> :ok
      state -> {:error, state}
    end
  end

  defp controller_result(:ok, _action), do: :ok

  defp controller_result({:error, state}, action) do
    raise TypeError, "Cannot #{action}: the stream is #{state}."
  end

  @impl Web.Stream
  def error(_reason, %{source: _} = state) do
    {:ok, state}
  end

  def error(pid, reason) when is_pid(pid) do
    Web.Stream.control_cast(pid, {:error, reason})
  end

  def cancel(target, reason \\ :cancelled)

  # A cancel of the stream object. The Streams Standard refuses it when the
  # stream has a reader: use the cancel function of the reader.
  def cancel(%__MODULE__{controller_pid: pid}, reason) do
    Web.Stream.promise_call(pid, {:terminate_unlocked, :cancel, reason}, :ok, fn
      :ok -> {:ok, :ok}
      {:error, :locked} -> {:error, %TypeError{message: "Cannot cancel a locked stream."}}
      {:error, thrown} -> {:error, thrown}
    end)
  end

  def cancel(pid, reason) do
    Web.Stream.promise_call(pid, {:terminate, :cancel, reason}, :ok, fn
      :ok -> {:ok, :ok}
      {:error, thrown} -> {:error, thrown}
    end)
  end

  @doc false
  def __get_slots__(pid) do
    :gen_statem.call(pid, :get_slots)
  end

  def tee(pid) when is_pid(pid), do: do_tee(%__MODULE__{controller_pid: pid})

  @doc """
  Gives two branches of the stream, as `ReadableStream.prototype.tee()` of
  the Streams Standard. The stream becomes locked.

    * Each chunk of the stream goes to the two branches.
    * A read from one of the two branches reads the stream. A branch that no
      process reads keeps each chunk in its queue. It does not slow down
      the other branch, and its queue has no limit.
    * When the stream ends or has an error, the two branches end or get
      that error.
    * A cancel of one branch has no effect on the stream. When the two
      branches are cancelled, the stream is cancelled, and the reason is
      the list of the two reasons.

  Raises `Web.TypeError` if the stream is locked.

  The promise of a cancel of one branch stays pending until the second
  branch is cancelled or the stream ends, as in the Streams Standard. Do not
  await the cancel of one branch while a process reads the other branch.
  A halt of an enumeration, such as `Enum.take/2`, does not wait.

  ## Examples

      iex> stream = Web.ReadableStream.from(["a", "b"])
      iex> [left, right] = Web.ReadableStream.tee(stream)
      iex> {Enum.to_list(left), Enum.to_list(right)}
      {["a", "b"], ["a", "b"]}
  """
  def tee(%__MODULE__{controller_pid: pid}) do
    case tee(pid) do
      branches when is_list(branches) ->
        branches

      {:error, :already_locked} ->
        raise TypeError, "ReadableStream is already locked"

      {:error, :released} ->
        raise TypeError, @released_message
    end
  end

  @doc """
  Pipes a readable stream into a writable stream.

  Returns a `%Promise{}` that runs the pump lifecycle asynchronously.

  ## Options

  - `:prevent_close` - do not close the writable side when the source is done
  - `:prevent_abort` - do not abort the writable side when the source errors
  - `:prevent_cancel` - do not cancel the readable side when the sink errors

  The names `:preventClose`, `:preventAbort`, and `:preventCancel` of the
  Streams Standard are accepted also.
  - `:signal` - optional `%Web.AbortSignal{}` to interrupt piping
  """
  def pipe_to(readable, writable, options \\ []) do
    {ready, wait_for_locks} = pipe_lock_signal()

    promise =
      Promise.detached(fn resolve, reject ->
        run_pipe(readable, writable, options, resolve, reject, ready)
      end)

    # The pipe has the two locks when this function returns, as in the
    # Streams Standard. A stream that is locked gives a rejected promise.
    _ = wait_for_locks.()
    promise
  end

  # Starts a pipe that no process awaits. A promise for such a pipe would
  # stay until its owner stops, thus this function makes no promise. Returns
  # `:ok` when the pipe has the two locks, or the error of the locks.
  defp start_pipe(readable, writable, options) do
    snapshot = Snapshot.take()
    ignore = fn _outcome -> :ok end
    {ready, wait_for_locks} = pipe_lock_signal()

    {:ok, _pid} =
      Task.Supervisor.start_child(Web.TaskSupervisor, fn ->
        try do
          Snapshot.run(snapshot, fn ->
            run_pipe(readable, writable, options, ignore, ignore, ready)
          end)
        catch
          _kind, _reason -> :ok
        end
      end)

    wait_for_locks.()
  end

  # The process of the pipe calls `ready` after it tried to get the two locks.
  # The process that started the pipe calls `wait_for_locks`.
  defp pipe_lock_signal do
    caller = self()
    ref = make_ref()

    ready = fn result -> send(caller, {ref, result}) end

    wait_for_locks = fn ->
      receive do
        {^ref, result} -> result
      end
    end

    {ready, wait_for_locks}
  end

  defp run_pipe(readable, writable, options, resolve, reject, ready) do
    case acquire_pipe_locks(readable, writable) do
      {:ok, reader, writer} ->
        ready.(:ok)
        outcome = pipe_outcome(reader, writer, options)

        # The pipe releases its locks before its promise settles.
        release_reader_lock(reader)
        release_writer_lock(writer)

        case outcome do
          :ok -> resolve.(:ok)
          {:error, reason} -> reject.(reason)
        end

      {:error, error} ->
        ready.({:error, error})
        reject.(error)
    end
  end

  defp acquire_pipe_locks(readable, writable) do
    reader = acquire_reader_for_pipe(readable)

    try do
      {:ok, reader, acquire_writer_for_pipe(writable)}
    rescue
      error in TypeError ->
        release_reader_lock(reader)
        {:error, error}
    end
  rescue
    error in TypeError -> {:error, error}
  end

  defp pipe_outcome(reader, writer, options) do
    case pump(reader, writer, options) do
      :done ->
        maybe_close_writer(writer, options)
        :ok

      # The pipe rejects with the error of the stream, or with the reason
      # of the signal, as the Streams Standard specifies.
      {:source_error, reason} ->
        reason = stored_error(reason)
        maybe_abort_writer(writer, reason, options)
        {:error, reason}

      {:sink_error, reason} ->
        reason = stored_error(reason)
        maybe_cancel_reader(reader, reason, options)
        {:error, reason}

      {:aborted, reason} ->
        maybe_cancel_reader(reader, reason, options)
        maybe_abort_writer(writer, reason, options)
        {:error, reason}
    end
  rescue
    error in TypeError -> {:error, error}
  end

  @doc """
  Pipes this stream through a transform and returns the transform's readable side.
  """
  def pipe_through(
        readable,
        %{readable: transformed_readable, writable: transformed_writable},
        options \\ []
      ) do
    # A stream that is locked raises here, as in the Streams Standard.
    case start_pipe(readable, transformed_writable, options) do
      :ok -> transformed_readable
      {:error, error} -> raise error
    end
  end

  # ---------------------------------------------------------------------------
  # Private pipe helpers
  # ---------------------------------------------------------------------------

  defp stored_error({:errored, reason}), do: reason
  defp stored_error(reason), do: reason

  defp pump(reader, writer, options) do
    owner_pid = self()

    try do
      ensure_pipe_signal_active!(options[:signal])

      with :ok <-
             await_pipe_step(
               fn -> WritableStream.ready(writer.controller_pid, writer.owner_pid) end,
               options
             ),
           :ok <- ensure_pipe_signal_active!(options[:signal]),
           read_result <-
             await_pipe_step(fn -> read_for_pipe(reader.controller_pid, owner_pid) end, options) do
        case read_result do
          %{value: chunk, done: false} ->
            case WritableStream.write(writer.controller_pid, writer.owner_pid, chunk) do
              :ok ->
                pump(reader, writer, options)

              {:error, reason} ->
                {:sink_error, reason}
            end

          %{done: true} ->
            :done

          {:error, reason} ->
            {:source_error, reason}
        end
      else
        # coveralls-ignore-next-line
        {:error, reason} -> {:sink_error, reason}
      end
    catch
      {:abort, reason} -> {:aborted, reason}
    end
  end

  defp await_pipe_step(fun, options) do
    signal = Keyword.get(options, :signal)

    if signal == nil do
      fun.()
    else
      case AbortSignal.subscribe(signal) do
        {:error, :aborted} ->
          # coveralls-ignore-next-line
          AbortSignal.check!(signal)

        {:ok, subscription} ->
          task = Task.async(fun)

          try do
            await_pipe_step_result(task, subscription, signal)
          after
            AbortSignal.unsubscribe(subscription)
            Task.shutdown(task, :brutal_kill)
          end
      end
    end
  end

  defp await_pipe_step_result(task, subscription, signal) do
    case Task.yield(task, 10) do
      {:ok, result} ->
        result

      # coveralls-ignore-start
      nil ->
        case AbortSignal.receive_abort(subscription, 0, true) do
          {:error, :aborted, reason} ->
            throw({:abort, normalize_abort_reason(signal, reason)})

          :ok ->
            await_pipe_step_result(task, subscription, signal)
        end

        # coveralls-ignore-stop
    end
  end

  defp read_for_pipe(pid, owner_pid) do
    case Web.Stream.call(pid, {:read, owner_pid}, {:error, :released}) do
      {:ok, chunk} -> %{value: chunk, done: false}
      :done -> %{value: nil, done: true}
      {:error, _} = error -> error
    end
  end

  defp ensure_pipe_signal_active!(nil), do: :ok

  defp ensure_pipe_signal_active!(%AbortSignal{} = signal) do
    AbortSignal.throw_if_aborted(signal)
  rescue
    _error in Web.DOMException ->
      throw({:abort, normalize_abort_reason(signal, :aborted)})
  end

  defp ensure_pipe_signal_active!(signal), do: AbortSignal.check!(signal)

  # coveralls-ignore-start
  defp normalize_abort_reason(signal, :aborted) do
    AbortSignal.reason(signal) || AbortSignal.default_reason()
  end

  defp normalize_abort_reason(_signal, reason), do: reason
  # coveralls-ignore-stop

  defp maybe_close_writer(writer, options) do
    if pipe_option(options, :prevent_close, :preventClose) do
      :ok
    else
      _ = WritableStream.close(writer.controller_pid, writer.owner_pid)
      :ok
    end
  end

  defp maybe_abort_writer(writer, reason, options) do
    if pipe_option(options, :prevent_abort, :preventAbort) do
      :ok
    else
      _ = WritableStream.abort(writer.controller_pid, writer.owner_pid, reason)
      :ok
    end
  end

  defp maybe_cancel_reader(reader, reason, options) do
    if pipe_option(options, :prevent_cancel, :preventCancel) do
      :ok
    else
      cancel_now(reader.controller_pid, reason)
      :ok
    end
  end

  defp cancel_now(pid, reason) do
    Web.Stream.control_cast(pid, {:terminate, :cancel, reason})
  end

  defp acquire_reader_for_pipe(%__MODULE__{} = readable), do: get_reader(readable)

  defp acquire_reader_for_pipe(pid) when is_pid(pid) do
    case get_reader(pid) do
      :ok -> %Web.ReadableStreamDefaultReader{controller_pid: pid, owner_pid: self()}
      {:error, :already_locked} -> raise TypeError, "ReadableStream is already locked"
      {:error, :released} -> raise TypeError, @released_message
    end
  end

  defp acquire_writer_for_pipe(%WritableStream{} = writable),
    do: WritableStream.get_writer(writable, :pipe)

  defp acquire_writer_for_pipe(pid) when is_pid(pid) do
    case WritableStream.get_writer(pid, :pipe) do
      :ok -> %Web.WritableStreamDefaultWriter{controller_pid: pid, owner_pid: self()}
      {:error, :already_locked} -> raise TypeError, "WritableStream is already locked"
      {:error, :released} -> raise TypeError, @released_message
    end
  end

  # The largest time that the VM accepts for a timer: about 49 days.
  @no_callback_timeout 4_294_967_295

  # The two branches are usual streams of the type of the source. The tee
  # process reads the source for them.
  defp do_tee(%__MODULE__{controller_pid: source}) do
    type = source_type(source)

    with {:ok, tee} <- ReadableStreamTee.start(source) do
      # The cancel callback of a branch waits until the two branches are
      # cancelled, thus a branch has no time limit for its callbacks.
      [branch1, branch2] =
        for index <- [1, 2] do
          new(tee_branch_source(tee, index, type), timeout_ms: @no_callback_timeout)
        end

      :ok =
        ReadableStreamTee.attach(
          tee,
          branch1.controller_pid,
          branch2.controller_pid
        )

      [branch1, branch2]
    end
  end

  defp tee_branch_source(tee, index, type) do
    source = %{
      pull: fn _controller -> ReadableStreamTee.pull(tee) end,
      cancel: fn reason -> ReadableStreamTee.cancel(tee, index, reason) end
    }

    if type == :bytes, do: Map.put(source, :type, "bytes"), else: source
  end

  defp source_type(pid) do
    case Web.Stream.call(pid, :get_slots, nil) do
      %{stream_type: type} -> type
      nil -> :default
    end
  end

  defp release_reader_lock(reader), do: release_lock(reader.controller_pid)

  defp release_writer_lock(writer) do
    WritableStream.release_lock(writer.controller_pid, writer.owner_pid)
  end

  # An option of a pipe, with its Elixir name or its name in the Streams
  # Standard.
  defp pipe_option(options, name, standard_name) do
    Keyword.get(options, name, Keyword.get(options, standard_name, false)) == true
  end
end

defimpl Enumerable, for: Web.ReadableStream do
  alias Web.ReadableStreamDefaultReader

  def reduce(stream, acc, fun) do
    reader = Web.ReadableStream.get_reader(stream)
    do_reduce(reader, acc, fun)
  end

  # A halt is the end of the enumeration. Cancel the stream, thus its source
  # stops and the stream process can stop.
  defp do_reduce(reader, {:halt, acc}, _fun) do
    # The stream is cancelled when this call returns. The call does not
    # wait for the cancel callback of the source.
    _ = Web.Stream.call(reader.controller_pid, {:terminate_detached, :cancel, :halted}, :ok)
    {:halted, acc}
  end

  defp do_reduce(reader, {:suspend, acc}, fun) do
    {:suspended, acc, &do_reduce(reader, &1, fun)}
  end

  defp do_reduce(reader, {:cont, acc}, fun) do
    case Web.Promise.wait(ReadableStreamDefaultReader.read(reader)) do
      {:rejected, reason} ->
        try do
          ReadableStreamDefaultReader.release_lock(reader)
        rescue
          # coveralls-ignore-next-line
          _ -> :ok
        end

        raise_stream_error(reason)

      {:fulfilled, %{done: true}} ->
        try do
          ReadableStreamDefaultReader.release_lock(reader)
        rescue
          # coveralls-ignore-next-line
          _ -> :ok
        end

        {:done, acc}

      {:fulfilled, %{value: chunk, done: false}} ->
        try do
          do_reduce(reader, fun.(chunk, acc), fun)
        rescue
          e ->
            try do
              ReadableStreamDefaultReader.release_lock(reader)
            rescue
              # coveralls-ignore-next-line
              _ -> :ok
            end

            reraise e, __STACKTRACE__
        end
    end
  end

  # Gives the error of the stream, when it is an exception.
  defp raise_stream_error(reason) when is_exception(reason), do: raise(reason)

  defp raise_stream_error(reason) do
    raise Web.TypeError, message: "The stream is errored.", cause: reason
  end

  def count(_stream), do: {:error, __MODULE__}
  def member?(_stream, _element), do: {:error, __MODULE__}
  def slice(_stream), do: {:error, __MODULE__}
end
