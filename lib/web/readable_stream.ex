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
  `tee/1` follows the algorithm of the Streams Standard. A pull from one of the two branches
  starts one read from the source, and the chunk of that read goes to the two branches. Thus
  the faster branch sets the speed: a branch that no process reads keeps each chunk in its
  queue, and does not slow down the other branch.
  """

  use Web.Stream

  defstruct [:controller_pid, :lazy]

  @typedoc """
  A readable stream. The fields are private.

  A stream of bytes that are all in memory, such as the body of
  `Web.Response.new/1` or of a small `fetch` response, has no process until
  a stream read: `get_reader/1`, a pipe, or `Enum`. The body functions, such
  as `Web.Response.text/1`, take its bytes with no process.
  """
  @type t :: %__MODULE__{controller_pid: pid() | nil, lazy: LazyStream.t() | nil}

  @released_message "The stream is not available. It ended, or its owner stopped."

  alias Web.ArrayBuffer
  alias Web.AsyncContext.Snapshot
  alias Web.Blob
  alias Web.Internal.LazyStream
  alias Web.Internal.QueuingStrategy
  alias Web.Internal.ReadableByteStreamTee
  alias Web.Internal.ReadableStreamPipe
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

    state = %{
      source: source,
      pid: pid,
      started: false,
      stream_type: stream_type
    }

    # The function `start` of the source runs in the process that makes the
    # stream: see `Web.Stream.run_start/3`. This process waits for it.
    {:producer, state, Web.Stream.start_actions(opts)}
  end

  @impl Web.Stream
  def pull(ctrl, %{source: %{pull: pull}} = state) when is_function(pull, 1) do
    ctrl
    |> pull.()
    |> await_pull_result()

    {:ok, %{state | started: true}}
  end

  # A source that is a process. A stream from `new/2` sends this message
  # from the stream process, with no callback: see `pid_source/1`.
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

  ## The queuing strategy

  The options `:high_water_mark` and `:size` are the members of the
  dictionary `QueuingStrategy` of the Streams Standard:

    * `:high_water_mark` - the limit of the queue: a number that is not
      below zero, or `:infinity`. The default is 1, and 0 for a byte stream.
    * `:size` - a function that gives the size of a chunk. The default
      counts each chunk as 1. The function runs in the process that
      enqueues the chunk. A size that is not a number, or that is below
      zero, or `:infinity`, puts the stream in the errored state, and the
      enqueue raises `Web.RangeError`.

  The option `:strategy` takes a `Web.CountQueuingStrategy` or a
  `Web.ByteLengthQueuingStrategy` instead.

  Raises `Web.RangeError` for a high water mark that is NaN or below zero,
  and for a byte stream with a size function. Raises `Web.TypeError` for a
  size that is not a function.

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
    __new__(underlying_source, opts, [])
  end

  @doc false
  # `new/2` with the options of the engine that no public function has: see
  # `Web.Stream.__start__/3`.
  def __new__(underlying_source, opts, internal) when is_list(opts) and is_list(internal) do
    :ok = validate_source!(underlying_source)
    stream_type = source_stream_type(underlying_source)
    {high_water_mark, strategy, size} = normalize_stream_options(underlying_source, opts)

    :ok = validate_auto_allocate_chunk_size!(stream_type, underlying_source)

    stream_opts =
      opts
      |> Keyword.put(:source, underlying_source)
      |> Keyword.put(:high_water_mark, high_water_mark)
      |> Keyword.put(:strategy, strategy)
      |> Keyword.put(:size, size)
      |> Keyword.put(:stream_type, stream_type)
      |> Keyword.put(
        :auto_allocate_chunk_size,
        source_auto_allocate_chunk_size(underlying_source)
      )

    start_fn = source_start(underlying_source)
    stream_opts = Keyword.put(stream_opts, :has_start, is_function(start_fn))

    {:ok, pid} =
      Web.Stream.__start__(__MODULE__, stream_opts, pid_source(underlying_source) ++ internal)

    if start_fn do
      Web.Stream.run_start(pid, start_fn, controller_for(stream_type, pid))
    end

    %__MODULE__{controller_pid: pid}
  end

  # A source that is a process gets the message `{:pull, stream}` from the
  # stream process directly.
  defp pid_source(source) when is_pid(source), do: [direct_pull: {:pid_source, source}]
  defp pid_source(_source), do: []

  defp source_start(%{start: start}) when is_function(start, 1), do: start
  defp source_start(_source), do: nil

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

  # A value of bytes in memory gives a stream with no process: see
  # `Web.Internal.LazyStream`.

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
  def from(%ArrayBuffer{} = buffer), do: from_chunk(ArrayBuffer.data(buffer))
  def from(%Uint8Array{} = bytes), do: %__MODULE__{lazy: LazyStream.new({:view, bytes})}

  def from(data) when is_binary(data), do: from_chunk(data)

  def from(%__MODULE__{} = stream), do: stream

  def from(enumerable), do: from_enumerable(enumerable, [])

  defp from_chunk(binary), do: %__MODULE__{lazy: LazyStream.new({:chunk, binary})}

  @doc false
  # The stream of a body of bytes in memory, with no process. No bytes give
  # no chunk, as the Fetch Standard specifies for a body.
  def __bytes__(binary) when is_binary(binary),
    do: %__MODULE__{lazy: LazyStream.new({:bytes, binary})}

  @doc false
  # The pid of the stream process. A stream with no process starts it at
  # this time. Returns `{:ok, pid}` or `{:error, :already_locked}` or
  # `{:error, :released}`.
  def __process__(%__MODULE__{controller_pid: pid}) when is_pid(pid), do: {:ok, pid}
  def __process__(%__MODULE__{lazy: lazy}), do: LazyStream.process(lazy, Promise.owner())

  @doc false
  # The same stream, with its process. Raises `Web.TypeError` when the
  # stream cannot have a process.
  def __with_process__(stream), do: %__MODULE__{controller_pid: process!(stream)}

  defp process!(stream) do
    case __process__(stream) do
      {:ok, pid} -> pid
      {:error, :already_locked} -> raise TypeError, "ReadableStream is already locked"
      {:error, :released} -> raise TypeError, @released_message
    end
  end

  @doc false
  # Makes a stream from an enumerable, with options for the stream engine.
  #
  # As `ReadableStream.from()` of the Streams Standard, the stream has the
  # high water mark 0, and each pull takes one element of the enumerable.
  # Thus the enumerable advances only for a read, one element for each
  # read, and an enumerable with side effects runs them at the same times
  # as in the Standard. The option `:high_water_mark` changes the limit.
  def from_enumerable(enumerable, opts) when is_list(opts) do
    if Enumerable.impl_for(enumerable) do
      enumerator = start_enumerator(enumerable)

      # The stream asks the enumerator for each chunk directly, and the
      # enumerator answers the stream: see `enumerator_loop/1`.
      __new__(
        %{cancel: fn _reason -> send(enumerator, :stop) end},
        opts
        |> Keyword.put_new(:high_water_mark, 0)
        |> Keyword.put(:cancel_on_reader_exit, true),
        direct_pull: {:process, enumerator}
      )
    else
      raise TypeError, "Cannot make a ReadableStream from #{inspect(enumerable)}"
    end
  end

  # ExtractSizeAlgorithm and ExtractHighWaterMark of the Streams Standard.
  # The option `:high_water_mark` and the option `:size` change the values
  # of the option `:strategy`.
  defp normalize_stream_options(underlying_source, opts) do
    stream_type = source_stream_type(underlying_source)

    if stream_type == :bytes and not is_nil(Keyword.get(opts, :size)) do
      raise Web.RangeError, "A byte stream cannot have a size function."
    end

    strategy = Keyword.get(opts, :strategy) || source_value(underlying_source, :strategy, nil)

    {strategy_hwm, strategy_size} =
      QueuingStrategy.extract!(strategy, source_default_hwm(underlying_source, stream_type))

    {high_water_mark, size} =
      QueuingStrategy.extract!(Keyword.take(opts, [:high_water_mark, :size]), strategy_hwm)

    high_water_mark = QueuingStrategy.high_water_mark!(high_water_mark, 1)
    size = if is_nil(Keyword.get(opts, :size)), do: strategy_size, else: size
    {high_water_mark, strategy || default_strategy_for(stream_type, high_water_mark), size}
  end

  # The Streams Standard gives a byte stream the high water mark 0, and each
  # other stream the high water mark 1. A source map can give a different
  # one.
  defp source_default_hwm(source, :bytes), do: source_value(source, :high_water_mark, 0)
  defp source_default_hwm(source, :default), do: source_value(source, :high_water_mark, 1)

  defp source_value(%{} = source, key, default), do: Map.get(source, key, default)
  defp source_value(_source, _key, default), do: default

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

  # SetUpReadableByteStreamControllerFromUnderlyingSource: the size of the
  # buffer of a default read of a byte stream is a positive integer.
  defp validate_auto_allocate_chunk_size!(:bytes, source) do
    case source_auto_allocate_chunk_size(source) do
      size when is_nil(size) or (is_integer(size) and size > 0) ->
        :ok

      size ->
        raise TypeError,
              "The option autoAllocateChunkSize must be an integer above 0, got: #{inspect(size)}"
    end
  end

  defp validate_auto_allocate_chunk_size!(:default, _source), do: :ok

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

  # The process of an enumerable. A slow enumerable thus does not stop the
  # stream process, and a cancel can stop the enumerable while it waits.
  # The enumerable cannot be in the worker of the stream: a cancel stops a
  # pull that runs, and the enumerable must then run its code for the end,
  # such as the `after` of `Stream.resource/3`.
  #
  # For each pull, the enumerator gives one chunk to the stream, and then
  # tells the stream that the pull is complete. It also closes the stream,
  # or puts it in the errored state. These messages come from one process,
  # thus the stream gets them in their sequence. A pull costs two messages
  # between the stream and the enumerator, and no other process.
  defp start_enumerator(enumerable) do
    spawn(fn -> enumerator_loop(%{enumerable: {:initial, enumerable}, stream: nil}) end)
  end

  defp enumerator_loop(state) do
    receive do
      {:web_stream_pull, ref, stream} ->
        state = watch_stream(state, stream)

        case produce_chunk(state.enumerable, stream) do
          {:more, enumerable} ->
            send(stream, {ref, :pulled})
            enumerator_loop(%{state | enumerable: enumerable})

          # The enumerable is complete, or it failed, or a cancel stopped it.
          :ended ->
            send(stream, {ref, :pulled})
        end

      # The cancel callback of the stream sends `:stop`. The enumerator also
      # stops when the stream stopped.
      :stop ->
        halt_enumerator(state.enumerable)

      {:DOWN, _ref, :process, _stream, _reason} ->
        halt_enumerator(state.enumerable)
    end
  end

  defp watch_stream(%{stream: nil} = state, stream) do
    Process.monitor(stream)
    %{state | stream: stream}
  end

  defp watch_stream(state, _stream), do: state

  # A pull asked for the chunk: in the Streams Standard, the pull calls the
  # iterator before a cancel can come. Thus a cancel that comes after the
  # request stops the enumerable after this chunk: see `enumerator_loop/1`.
  defp produce_chunk(enumerable, stream) do
    case safe_enumerator_next(enumerable) do
      {:chunk, chunk, next} ->
        enqueue(stream, chunk)
        {:more, next}

      :done ->
        close(stream)
        :ended

      # The stream gets the error as the error of a pull: an exception for a
      # raise, and the value for a throw or an exit.
      {:raised, kind, reason, stacktrace} ->
        :gen_statem.cast(stream, {:error, Exception.normalize(kind, reason, stacktrace)})
        :ended
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

  @doc false
  def disturbed?(nil), do: false
  def disturbed?(body) when is_binary(body) or is_list(body), do: false

  def disturbed?(%__MODULE__{controller_pid: pid}) when is_pid(pid) do
    disturbed?(pid)
  end

  def disturbed?(%__MODULE__{lazy: lazy}) do
    case LazyStream.state(lazy) do
      :readable -> false
      {:process, pid} -> disturbed?(pid)
      _used_or_gone -> true
    end
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

  def locked?(%__MODULE__{controller_pid: pid}) when is_pid(pid) do
    locked?(pid)
  end

  def locked?(%__MODULE__{lazy: lazy}) do
    case LazyStream.state(lazy) do
      :locked -> true
      {:process, pid} -> locked?(pid)
      _other -> false
    end
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
  def get_reader(%__MODULE__{controller_pid: nil} = stream, opts) when is_list(opts) do
    get_reader(%__MODULE__{controller_pid: process!(stream)}, opts)
  end

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
    case lock_reader(pid, reader_mode_from_options(opts)) do
      {:ok, _lock} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def get_reader(pid) when is_pid(pid), do: get_reader(pid, [])

  def get_reader(%__MODULE__{controller_pid: nil} = stream) do
    get_reader(%__MODULE__{controller_pid: process!(stream)})
  end

  # The reader keeps the reference of its lock: see
  # `Web.ReadableStreamDefaultReader`.
  def get_reader(%__MODULE__{controller_pid: pid}) do
    case lock_reader(pid, :default) do
      {:ok, lock} ->
        %Web.ReadableStreamDefaultReader{controller_pid: pid, owner_pid: self(), lock: lock}

      {:error, :already_locked} ->
        raise TypeError, "ReadableStream is already locked"

      {:error, :released} ->
        raise TypeError, @released_message
    end
  end

  # Takes the reader lock for this process. Returns `{:ok, lock}` with the
  # reference of the lock, or `{:error, reason}`.
  defp lock_reader(pid, mode) do
    request =
      case mode do
        :default -> {:get_reader, self()}
        :byob -> {:get_reader, self(), :byob}
      end

    Web.Stream.call(pid, request, {:error, :released})
  end

  def read(pid) do
    Web.Stream.call(pid, {:read, self()}, {:error, :not_locked_by_reader})
  end

  @doc """
  Returns an asynchronous iterator of the chunks of the stream, as
  `values(options)` and `[Symbol.asyncIterator]()` of the Streams Standard.

  The iterator takes a default reader: the stream becomes locked. See
  `Web.ReadableStreamAsyncIterator` for its functions `next/1` and
  `return/2`. The lock is released at the end of the stream, at an error,
  and at `return/2`.

  ## Options

    * `:prevent_cancel` - if `true`, `Web.ReadableStreamAsyncIterator.return/2`
      releases the lock and does not cancel the stream. The default is
      `false`.

  Raises `Web.TypeError` if the stream is locked.

  ## Examples

      iex> stream = Web.ReadableStream.from(["a", "b"])
      iex> iterator = Web.ReadableStream.values(stream)
      iex> Web.await(Web.ReadableStreamAsyncIterator.next(iterator))
      %{value: "a", done: false}
      iex> Web.await(Web.ReadableStreamAsyncIterator.return(iterator))
      %{value: nil, done: true}
      iex> Web.ReadableStream.locked?(stream)
      false
  """
  @spec values(t(), keyword()) :: Web.ReadableStreamAsyncIterator.t()
  def values(%__MODULE__{} = stream, opts \\ []) when is_list(opts) do
    prevent_cancel = Keyword.get(opts, :prevent_cancel, false) == true
    Web.ReadableStreamAsyncIterator.__new__(get_reader(stream), prevent_cancel)
  end

  @doc false
  # A batch read of `max` chunks at most, for the lock of `owner`. See the
  # request `:read_batch` of `Web.Stream`. The answer is `{:chunks, list}`,
  # `{:ok, chunk}`, `:done`, or `{:error, reason}`.
  def read_batch(pid, owner, max) when is_pid(pid) and is_integer(max) and max > 0 do
    Web.Stream.request(pid, {:read_batch, owner, max}, {:error, :not_locked_by_reader})
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
    Web.Stream.control_cast(pid, {:enqueue, chunk})
  end

  @doc false
  # `close` with no check: see `enqueue/2`.
  def close(pid) do
    Web.Stream.control_cast(pid, :close)
  end

  @doc false
  # `enqueue` of a controller, as in the Streams Standard: raises
  # `Web.TypeError` when the stream is closed or errored.
  #
  # The size function of the user runs in this process, as in the Standard:
  # thus the function can call the stream. A size that is not valid puts the
  # stream in the errored state. Then the controller of a readable stream
  # (`kind` is `:readable`) raises or throws the error of the size, and the
  # controller of a transform stream (`:transform`) the error of the stream.
  def controller_enqueue(pid, chunk, kind \\ :readable) do
    case Web.Stream.call(pid, {:enqueue, chunk}, {:error, :closed}) do
      {:size, size} -> enqueue_with_size(pid, chunk, size, kind)
      reply -> controller_result(reply, "enqueue a chunk", kind)
    end
  end

  defp enqueue_with_size(pid, chunk, size, kind) do
    result = QueuingStrategy.call(size, chunk)

    case Web.Stream.call(pid, {:enqueue_sized, chunk, result}, :gone) do
      :ok ->
        :ok

      {:error, {:size, reason, stored}} ->
        size_failure(result, reason, stored, kind)

      # The stream stopped. The chunk has no effect, but the error of the
      # size is still an error of the call.
      :gone ->
        case QueuingStrategy.validate(result) do
          {:ok, _size} -> :ok
          {:error, reason} -> size_failure(result, reason, reason, kind)
        end
    end
  end

  defp size_failure(_result, _reason, stored, :transform), do: raise_value(stored)

  defp size_failure({:thrown, kind, value, stacktrace}, _reason, _stored, :readable),
    do: :erlang.raise(kind, value, stacktrace)

  defp size_failure(_result, reason, _stored, :readable), do: raise(reason)

  # The error of a stream: an exception is raised, and each other value is
  # thrown, as a JavaScript value.
  defp raise_value(error) when is_exception(error), do: raise(error)
  defp raise_value(value), do: throw(value)

  @doc false
  # `close` of a controller: see `controller_enqueue/3`.
  def controller_close(pid) do
    pid |> Web.Stream.call(:close, {:error, :closed}) |> controller_result("close", :readable)
  end

  defp controller_result(:ok, _action, _kind), do: :ok

  # A size of the strategy of the library that is not valid, for example
  # the byte length of a chunk with no bytes.
  defp controller_result({:error, {:size, reason, stored}}, _action, kind),
    do: size_failure(nil, reason, stored, kind)

  defp controller_result({:error, state}, action, _kind) do
    raise TypeError, "Cannot #{action}: the stream is #{state}."
  end

  @doc false
  # `error` with no check, for a source that is a process of this library:
  # see `enqueue/2`.
  def error(pid, reason) when is_pid(pid) do
    Web.Stream.control_cast(pid, {:error, reason})
  end

  def cancel(target, reason \\ :cancelled)

  # A cancel of the stream object. The Streams Standard refuses it when the
  # stream has a reader: use the cancel function of the reader.
  def cancel(%__MODULE__{controller_pid: pid}, reason) when is_pid(pid) do
    Web.Stream.promise_call(pid, {:terminate_unlocked, :cancel, reason}, :ok, &cancel_result/1)
  end

  # A stream with no process has no callback to call.
  def cancel(%__MODULE__{lazy: lazy}, reason) do
    case LazyStream.cancel(lazy) do
      :ok -> Promise.resolve(:ok)
      :locked -> Promise.reject(%TypeError{message: "Cannot cancel a locked stream."})
      {:process, pid} -> cancel(%__MODULE__{controller_pid: pid}, reason)
    end
  end

  # A cancel by a reader, or by the code of this library: it has no check of
  # the lock.
  def cancel(pid, reason) do
    Web.Stream.promise_call(pid, {:terminate, :cancel, reason}, :ok, &cancel_result/1)
  end

  # A value that the cancel callback of the source throws is the rejection
  # reason, with no change.
  defp cancel_result(:ok), do: {:ok, :ok}

  defp cancel_result({:error, :locked}) do
    {:error, %TypeError{message: "Cannot cancel a locked stream."}}
  end

  defp cancel_result({:error, thrown}), do: {:error, thrown}

  @doc false
  def __get_slots__(pid) do
    :gen_statem.call(pid, :get_slots)
  end

  def tee(pid) when is_pid(pid), do: do_tee(%__MODULE__{controller_pid: pid}, false)

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
  def tee(%__MODULE__{} = stream), do: __tee__(stream, false)

  @doc false
  # ReadableStreamTee with the argument cloneForBranch2. The Fetch Standard
  # tees a body with the value `true`: the second branch of a default stream
  # gets a structured clone of each chunk. The tee of a byte stream always
  # gives each branch its own bytes.
  def __tee__(%__MODULE__{controller_pid: nil, lazy: lazy} = stream, clone?) do
    case LazyStream.tee(lazy) do
      {:ok, branches} -> Enum.map(branches, &%__MODULE__{lazy: &1})
      {:process, pid} -> __tee__(%__MODULE__{controller_pid: pid}, clone?)
      :locked -> raise TypeError, "ReadableStream is already locked"
      _readable_or_used -> __tee__(%__MODULE__{controller_pid: process!(stream)}, clone?)
    end
  end

  def __tee__(%__MODULE__{controller_pid: pid}, clone?) do
    case do_tee(%__MODULE__{controller_pid: pid}, clone?) do
      branches when is_list(branches) ->
        branches

      {:error, :already_locked} ->
        raise TypeError, "ReadableStream is already locked"

      {:error, :released} ->
        raise TypeError, @released_message
    end
  end

  @doc """
  Pipes a readable stream into a writable stream, as `pipeTo()` of the
  Streams Standard.

  Returns a `%Promise{}`. The pipe reads a chunk only when the destination
  wants a chunk, and it does not wait for a write before the next read.
  The promise fulfils when the source closed and the close of the
  destination is complete. It rejects with the error of a stream, with the
  reason of the signal, or with the failure of the abort, the cancel, or the
  close that the pipe does. A stream that closes or has an error stops the
  pipe also while a read or a write waits.

  ## Options

  - `:prevent_close` - do not close the writable side when the source is done
  - `:prevent_abort` - do not abort the writable side when the source errors
  - `:prevent_cancel` - do not cancel the readable side when the sink errors
    or closes

  The names `:preventClose`, `:preventAbort`, and `:preventCancel` of the
  Streams Standard are accepted also.
  - `:signal` - optional `%Web.AbortSignal{}` that stops the pipe: the pipe
    aborts the destination and cancels the source, and rejects with the
    reason of the signal
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

    _pid =
      spawn(fn ->
        try do
          Snapshot.run(snapshot, fn ->
            run_pipe(readable, writable, options, ignore, ignore, ready)
          end)
        catch
          # A stream that stops with a failure during a call of the pipe. A
          # test cannot stop a stream at a known step of the pipe.
          # coveralls-ignore-next-line
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
        # ReadableStreamPipeTo: "Set source.[[disturbed]] to true." The
        # source is disturbed when `pipe_to/3` returns, also when the pipe
        # reads no chunk.
        :ok = Web.Stream.call(reader.controller_pid, :disturb, :ok)
        ready.(:ok)

        # The pipe releases its locks before its promise settles.
        case ReadableStreamPipe.run(reader.controller_pid, writer.controller_pid, options) do
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
  # process reads the source for them: ReadableStreamDefaultTee, or
  # ReadableByteStreamTee for a byte stream.
  defp do_tee(%__MODULE__{controller_pid: source}, clone?) do
    {tee_module, started} =
      if source_type(source) == :bytes,
        do: {ReadableByteStreamTee, ReadableByteStreamTee.start(source)},
        else: {ReadableStreamTee, ReadableStreamTee.start(source, clone?)}

    with {:ok, tee} <- started do
      # The cancel callback of a branch waits until the two branches are
      # cancelled, thus a branch has no time limit for its callbacks.
      [branch1, branch2] =
        for index <- [1, 2] do
          new(tee_branch_source(tee_module, tee, index), timeout_ms: @no_callback_timeout)
        end

      :ok =
        tee_module.attach(
          tee,
          branch1.controller_pid,
          branch2.controller_pid
        )

      [branch1, branch2]
    end
  end

  defp tee_branch_source(ReadableStreamTee, tee, index) do
    %{
      pull: fn _controller -> ReadableStreamTee.pull(tee, index) end,
      cancel: fn reason -> ReadableStreamTee.cancel(tee, index, reason) end
    }
  end

  # The pull of a branch of a byte stream gives the BYOB request of the
  # branch.
  defp tee_branch_source(ReadableByteStreamTee, tee, index) do
    %{
      type: "bytes",
      pull: fn controller ->
        request = ReadableByteStreamController.byob_request(controller)
        ReadableByteStreamTee.pull(tee, index, request)
      end,
      cancel: fn reason -> ReadableByteStreamTee.cancel(tee, index, reason) end
    }
  end

  defp source_type(pid) do
    case Web.Stream.call(pid, :get_slots, nil) do
      %{stream_type: type} -> type
      nil -> :default
    end
  end

  defp release_reader_lock(reader), do: release_lock(reader.controller_pid)
end

defimpl Enumerable, for: Web.ReadableStream do
  alias Web.ReadableStreamDefaultReader

  # The largest batch of a read: see `ReadableStreamDefaultReader.read_batch_now/2`.
  @max_batch 64

  # The enumeration reads the chunks in batches. The first batch has one
  # chunk, and each batch after it has two times the chunks of the batch
  # before, up to 64. A batch takes only the chunks that are in the queue:
  # the stream pulls as for one read after the other, as the Streams
  # Standard specifies. Thus an enumeration that takes few chunks, such as
  # `Enum.take/2`, takes no chunk that it does not use.
  # A stream of bytes with no process gives its chunk with no process. A
  # halt before the chunk is a cancel.
  def reduce(%Web.ReadableStream{controller_pid: nil, lazy: lazy} = stream, acc, fun) do
    case acc do
      {:halt, acc} ->
        _ = Web.ReadableStream.cancel(stream, :halted)
        {:halted, acc}

      _cont_or_suspend ->
        case Web.Internal.LazyStream.take_chunks(lazy) do
          {:ok, chunks} -> Enumerable.List.reduce(chunks, acc, fun)
          {:error, reason} -> raise_stream_error(reason)
          {:process, pid} -> reduce(%Web.ReadableStream{controller_pid: pid}, acc, fun)
          _readable_used_or_gone -> reduce_process(stream, acc, fun)
        end
    end
  end

  def reduce(stream, acc, fun), do: reduce_process(stream, acc, fun)

  defp reduce_process(stream, acc, fun) do
    reader = Web.ReadableStream.get_reader(stream)
    do_reduce({reader, [], 1}, acc, fun)
  end

  # A halt is the end of the enumeration. Cancel the stream, thus its source
  # stops and the stream process can stop.
  defp do_reduce({reader, _chunks, _batch}, {:halt, acc}, _fun) do
    # The stream is cancelled when this call returns. The call does not
    # wait for the cancel callback of the source. A cancel does not release
    # the lock: the enumeration releases it, as the `return()` of an async
    # iterator of the Streams Standard does.
    _ = Web.Stream.call(reader.controller_pid, {:terminate_detached, :cancel, :halted}, :ok)
    ReadableStreamDefaultReader.release_lock(reader)
    {:halted, acc}
  end

  defp do_reduce(state, {:suspend, acc}, fun) do
    {:suspended, acc, &do_reduce(state, &1, fun)}
  end

  defp do_reduce({reader, [chunk | chunks], batch}, {:cont, acc}, fun) do
    do_reduce({reader, chunks, batch}, apply_reducer(reader, fun, chunk, acc), fun)
  end

  # The read has no promise: a promise is a process that keeps the chunk
  # for some seconds. The call of the reducer is not in the path of the
  # recursion, thus the stack does not increase with the number of chunks.
  defp do_reduce({reader, [], batch}, {:cont, acc}, fun) do
    case ReadableStreamDefaultReader.read_batch_now(reader, batch) do
      {:ok, chunks} ->
        do_reduce({reader, chunks, min(batch * 2, @max_batch)}, {:cont, acc}, fun)

      :done ->
        ReadableStreamDefaultReader.release_lock(reader)
        {:done, acc}

      {:error, reason} ->
        ReadableStreamDefaultReader.release_lock(reader)
        raise_stream_error(reason)
    end
  end

  # An enumeration that stops because the reducer failed releases the lock.
  defp apply_reducer(reader, fun, chunk, acc) do
    fun.(chunk, acc)
  catch
    kind, reason ->
      ReadableStreamDefaultReader.release_lock(reader)
      :erlang.raise(kind, reason, __STACKTRACE__)
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
