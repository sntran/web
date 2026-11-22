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
  Creates a new ReadableStream with the given underlying source, as
  `new ReadableStream(underlyingSource, strategy)`.

  ## The underlying source

  A map with the members of the dictionary `UnderlyingSource` of the
  Streams Standard: `:start`, `:pull`, and `:cancel` (functions), `:type`
  (`"bytes"` for a byte stream), and `:auto_allocate_chunk_size`. The
  function `start` and `pull` get the controller: a
  `Web.ReadableStreamDefaultController`, or a
  `Web.ReadableByteStreamController` for a byte stream.

  ## The queuing strategy

  The strategy is the dictionary `QueuingStrategy` of the Streams Standard:
  a keyword list or a map with these keys, or a `Web.CountQueuingStrategy`
  or a `Web.ByteLengthQueuingStrategy`.

    * `:high_water_mark` - the limit of the queue: a number that is not
      below zero, or `:infinity`. The default is 1, and 0 for a byte stream.
    * `:size` - a function that gives the size of a chunk. The default
      counts each chunk as 1. The function runs in the process that
      enqueues the chunk. A size that is not a number, or that is below
      zero, or `:infinity`, puts the stream in the errored state, and the
      enqueue raises `Web.RangeError`.

  Raises `Web.RangeError` for a high water mark that is NaN or below zero,
  and for a byte stream with a size function, also the size function of a
  strategy struct. Raises `Web.TypeError` for a size that is not a function,
  and for an underlying source that is not a map.

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
  def new(underlying_source \\ %{}, strategy \\ []) do
    __new__(underlying_source, strategy_options(strategy), [])
  end

  # The members of the dictionary `QueuingStrategy`. A struct is a map: a
  # strategy struct gives its two fields. Each other key has no effect, as
  # in WebIDL.
  defp strategy_options(strategy) when is_list(strategy) or is_map(strategy) do
    [:high_water_mark, :size]
    |> Enum.map(&{&1, member(strategy, &1)})
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp strategy_options(strategy) do
    raise TypeError, "Invalid queuing strategy: #{inspect(strategy)}"
  end

  defp member(strategy, key) when is_list(strategy) do
    case List.keyfind(strategy, key, 0) do
      {^key, value} -> value
      nil -> nil
    end
  end

  defp member(strategy, key), do: Map.get(strategy, key)

  @doc false
  # `new/2` with the options of the engine that no public function has: see
  # `Web.Stream.__start__/3`. The option `:strategy` is a strategy struct
  # for the engine, and `:high_water_mark` and `:size` change its values.
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

    case Web.Stream.__start__(__MODULE__, stream_opts, internal) do
      {:ok, pid} ->
        if start_fn do
          Web.Stream.run_start(pid, start_fn, controller_for(stream_type, pid))
        end

        %__MODULE__{controller_pid: pid}

      # The stream process of a stream with no process: a different stream
      # process has its key. See `Web.Internal.LazyStream`.
      :ignore ->
        :ignore
    end
  end

  defp source_start(%{start: start}) when is_function(start, 1), do: start
  defp source_start(_source), do: nil

  @doc """
  Makes a `ReadableStream` from an enumerable, as `ReadableStream.from()`
  of the Streams Standard does for an iterable. The stream gives one chunk
  for each element, with no change. A `ReadableStream` is an enumerable:
  the new stream reads it, and holds its lock.

  Raises `Web.TypeError` for a value that is not an enumerable. For a
  stream of bytes, use the body of a response
  (`Web.Response.new(binary).body`) or `Web.Blob.stream/1`.

  ## Examples

      iex> stream = Web.ReadableStream.from(["a", "b"])
      iex> Enum.to_list(stream)
      ["a", "b"]

      iex> Web.ReadableStream.from(Web.ReadableStream.from([1, 2])) |> Enum.to_list()
      [1, 2]
  """
  def from(enumerable), do: from_enumerable(enumerable, [])

  @doc false
  # `from/1` with the values of bytes of the library: a binary gives one
  # chunk, a `Web.Blob` its parts, a `Web.ArrayBuffer` or a
  # `Web.Uint8Array` one chunk, a `Web.URLSearchParams` its text, and `nil`
  # no chunk. A `ReadableStream` stays the same. Each chunk is a
  # `Web.Uint8Array`. `Web.Body` and `Web.FormData` use it.
  def __from__(nil) do
    new(%{start: &Web.ReadableStreamDefaultController.close/1})
  end

  def __from__(%URLSearchParams{} = params) do
    __from__(URLSearchParams.to_string(params))
  end

  # A value of bytes in memory gives a stream with no process: see
  # `Web.Internal.LazyStream`.

  def __from__(%Blob{parts: parts}) do
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
  def __from__(%ArrayBuffer{} = buffer), do: from_chunk(ArrayBuffer.data(buffer))
  def __from__(%Uint8Array{} = bytes), do: %__MODULE__{lazy: LazyStream.new({:view, bytes})}

  def __from__(data) when is_binary(data), do: from_chunk(data)

  def __from__(%__MODULE__{} = stream), do: stream

  def __from__(enumerable), do: from(enumerable)

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
  # The lock step of each path that takes the lock of a stream process: a
  # reader, a tee, a pipe, an iterator, an enumeration, a cancel, a body
  # function and the proxy of a body (`Web.Body`), and the FormData parser.
  # `lock` takes the lock of the process `pid`, and returns
  # `{:error, :released}` when the process stopped.
  #
  # The stream process of a stream with no process can stop before that
  # lock: a different process can kill it. When it stopped before its first
  # read, no reader took the bytes, and the state is `:readable`, or
  # `{:process, pid}` for a new stream process: the step asks for the
  # stream process again, with `again`, and takes its lock. A start that
  # stopped also gives `:readable`: the new ask continues it. The state ends
  # the retry: after a read or a claim, the state is `:gone` or the state of
  # the claim, and the error stays. See `tla/LazyStream.tla`.
  def __lock__(%__MODULE__{controller_pid: pid}, lock) when is_pid(pid), do: lock.(pid)

  def __lock__(%__MODULE__{} = stream, lock),
    do: __lock__(stream, process!(stream), lock, fn -> __lock__(stream, lock) end)

  def __lock__(%__MODULE__{lazy: lazy}, pid, lock, again) do
    with {:error, :released} = released <- lock.(pid) do
      if bytes_free?(LazyStream.state(lazy)), do: again.(), else: released
    end
  end

  defp bytes_free?(:readable), do: true
  defp bytes_free?({:process, _pid}), do: true
  defp bytes_free?(_used_or_gone), do: false

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

    strategy = Keyword.get(opts, :strategy)

    {strategy_hwm, strategy_size} =
      QueuingStrategy.extract!(strategy, default_hwm(stream_type))

    {high_water_mark, size} =
      QueuingStrategy.extract!(Keyword.take(opts, [:high_water_mark, :size]), strategy_hwm)

    high_water_mark = QueuingStrategy.high_water_mark!(high_water_mark, 1)
    size = if is_nil(Keyword.get(opts, :size)), do: strategy_size, else: size
    {high_water_mark, strategy || default_strategy_for(stream_type, high_water_mark), size}
  end

  # The Streams Standard gives a byte stream the high water mark 0, and each
  # other stream the high water mark 1.
  defp default_hwm(:bytes), do: 0
  defp default_hwm(:default), do: 1

  @source_callbacks [start: 1, pull: 1, cancel: 1]

  # The checks of the Streams Standard for an underlying source.
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

  defp validate_source!(source) do
    raise TypeError, "Invalid underlying source: #{inspect(source)}"
  end

  defp source_stream_type(source) do
    if Map.get(source, :type) == "bytes", do: :bytes, else: :default
  end

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

  defp source_auto_allocate_chunk_size(source), do: Map.get(source, :auto_allocate_chunk_size)

  defp default_strategy_for(:bytes, high_water_mark),
    do: %Web.ByteLengthQueuingStrategy{high_water_mark: high_water_mark}

  defp default_strategy_for(:default, high_water_mark),
    do: %Web.CountQueuingStrategy{high_water_mark: high_water_mark}

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
            Web.Stream.__send_info__(stream, {ref, :pulled})
            enumerator_loop(%{state | enumerable: enumerable})

          # The enumerable is complete, or it failed, or a cancel stopped it.
          :ended ->
            Web.Stream.__send_info__(stream, {ref, :pulled})
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
        Web.Stream.__usual_cast__(stream, {:error, Exception.normalize(kind, reason, stacktrace)})
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
  Returns `true` when the stream is locked to a reader, as the attribute
  `locked`.
  """
  @spec locked?(t()) :: boolean()
  def locked?(%__MODULE__{} = stream), do: __locked__(stream)

  @doc false
  # `locked?/1` for each value of a body: `nil`, a binary, or a list have no
  # lock. The stream process `pid` gives the lock of its stream.
  def __locked__(%__MODULE__{controller_pid: pid}) when is_pid(pid), do: __locked__(pid)

  def __locked__(%__MODULE__{lazy: lazy}) do
    case LazyStream.state(lazy) do
      :locked -> true
      {:process, pid} -> __locked__(pid)
      _other -> false
    end
  end

  def __locked__(pid) when is_pid(pid), do: Web.Stream.call(pid, {:locked?, :reader}, false)
  def __locked__(_body), do: false

  @doc """
  Locks the stream and returns a reader, as `getReader(options)`.

  ## Options

    * `:mode` - `"byob"` gives a `Web.ReadableStreamBYOBReader` for a byte
      stream. With no mode, the reader is a
      `Web.ReadableStreamDefaultReader`.

  Raises `Web.TypeError` if the stream is locked, and for the mode
  `"byob"` of a stream that is not a byte stream.

  ## Examples

      iex> stream = Web.ReadableStream.new()
      iex> reader = Web.ReadableStream.get_reader(stream)
      iex> is_struct(reader, Web.ReadableStreamDefaultReader)
      true
  """
  def get_reader(%__MODULE__{} = stream, opts \\ []) when is_list(opts) do
    mode = reader_mode_from_options(opts)
    stream |> __lock__(&reader_lock(&1, mode)) |> new_reader()
  end

  @doc false
  # The lock of a reader for this process on the stream process `pid`, with
  # no reader struct: `:ok` or `{:error, reason}`.
  def __get_reader__(pid, opts \\ []) when is_pid(pid) and is_list(opts) do
    case lock_reader(pid, reader_mode_from_options(opts)) do
      {:ok, _lock} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # A default reader of the process `pid`, for the lock step of
  # `__lock__/4`: `{:ok, reader}` or `{:error, reason}`.
  def __reader__(pid) when is_pid(pid) do
    with {:ok, _lock} = locked <- reader_lock(pid, :default), do: {:ok, new_reader(locked)}
  end

  defp reader_lock(pid, mode) do
    with {:ok, lock} <- lock_reader(pid, mode), do: {:ok, {pid, mode, lock}}
  end

  # The reader keeps the reference of its lock: see
  # `Web.ReadableStreamDefaultReader` and `Web.ReadableStreamBYOBReader`.
  defp new_reader({:ok, {pid, :default, lock}}),
    do: %Web.ReadableStreamDefaultReader{controller_pid: pid, owner_pid: self(), lock: lock}

  defp new_reader({:ok, {pid, :byob, lock}}),
    do: %ReadableStreamBYOBReader{controller_pid: pid, owner_pid: self(), lock: lock}

  defp new_reader({:error, :already_locked}),
    do: raise(TypeError, "ReadableStream is already locked")

  defp new_reader({:error, :not_byte_stream}),
    do: raise(TypeError, "ReadableStream is not a byte stream")

  defp new_reader({:error, :released}), do: raise(TypeError, @released_message)

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

  @doc false
  # The release of the reader lock of `owner` on the stream process `pid`.
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

  @doc false
  # The desired size of the stream process `pid`: see the attribute
  # `desiredSize` of the controllers.
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

  @doc """
  Cancels the stream, as `cancel(reason)`. The function `cancel` of the
  underlying source gets the reason. The default reason is `nil`, as
  `undefined` in the Streams Standard.

  Returns a `Web.Promise` that fulfils when the cancel is complete. It
  rejects with `Web.TypeError` when the stream is locked: use the cancel
  function of the reader.
  """
  @spec cancel(t(), term()) :: Promise.t()
  def cancel(stream, reason \\ nil)

  def cancel(%__MODULE__{controller_pid: pid}, reason) when is_pid(pid) do
    Web.Stream.promise_call(pid, {:terminate_unlocked, :cancel, reason}, :ok, &cancel_result/1)
  end

  # A stream with no process has no callback to call. The cancel of its
  # stream process waits for the end of the cancel: a process that stopped
  # before its first read gives the cancel of the bytes. See `__lock__/2`.
  def cancel(%__MODULE__{lazy: lazy} = stream, reason) do
    case LazyStream.cancel(lazy) do
      :ok ->
        Promise.resolve(:ok)

      :locked ->
        Promise.reject(%TypeError{message: "Cannot cancel a locked stream."})

      {:process, pid} ->
        cancel_lazy_process(stream, pid, reason)
    end
  end

  @doc false
  # A cancel of the stream process `pid` by a reader, or by the code of this
  # library: it has no check of the lock.
  def __cancel__(pid, reason) when is_pid(pid) do
    Web.Stream.promise_call(pid, {:terminate, :cancel, reason}, :ok, &cancel_result/1)
  end

  # A process that stopped after a read: the cancel of a stream that ended.
  defp cancel_lazy_process(stream, pid, reason) do
    with {:error, :released} <-
           __lock__(stream, pid, &cancel_process(&1, reason), fn -> cancel(stream, reason) end),
         do: Promise.resolve(:ok)
  end

  defp cancel_process(pid, reason) do
    case Web.Stream.call(pid, {:terminate_unlocked, :cancel, reason}, {:error, :released}) do
      {:error, :released} -> {:error, :released}
      reply -> reply |> cancel_result() |> settled()
    end
  end

  defp settled({:ok, value}), do: Promise.resolve(value)
  defp settled({:error, reason}), do: Promise.reject(reason)

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
    tee = &do_tee(%__MODULE__{controller_pid: &1}, clone?)

    case LazyStream.tee(lazy) do
      {:ok, branches} ->
        Enum.map(branches, &%__MODULE__{lazy: &1})

      {:process, pid} ->
        stream |> __lock__(pid, tee, fn -> __tee__(stream, clone?) end) |> branches()

      :locked ->
        raise TypeError, "ReadableStream is already locked"

      _readable_or_used ->
        stream |> __lock__(tee) |> branches()
    end
  end

  def __tee__(%__MODULE__{controller_pid: pid}, clone?),
    do: %__MODULE__{controller_pid: pid} |> do_tee(clone?) |> branches()

  defp branches(branches) when is_list(branches), do: branches

  defp branches({:error, :already_locked}),
    do: raise(TypeError, "ReadableStream is already locked")

  defp branches({:error, :released}), do: raise(TypeError, @released_message)

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

  The options are the members of the dictionary `StreamPipeOptions` of the
  Streams Standard:

    * `:prevent_close` - do not close the destination when the source
      closes.
    * `:prevent_abort` - do not abort the destination when the source has
      an error.
    * `:prevent_cancel` - do not cancel the source when the destination has
      an error or closes.
    * `:signal` - a `Web.AbortSignal` that stops the pipe: the pipe aborts
      the destination and cancels the source, and rejects with the reason
      of the signal.
  """
  @spec pipe_to(t(), WritableStream.t(), keyword()) :: Promise.t()
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
    snapshot = Snapshot.new()
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
  Pipes this stream through a transform, and returns the readable side of
  the transform, as `pipeThrough(transform, options)`.

  The transform is the dictionary `ReadableWritablePair`: a map or a struct
  with the fields `readable` and `writable`, for example a
  `Web.TransformStream`. The options are the options of `pipe_to/3`. The
  pipe from this stream to the writable side runs in a different process.

  Raises `Web.TypeError` if this stream or the writable side is locked.
  """
  @spec pipe_through(t(), %{readable: t(), writable: WritableStream.t()}, keyword()) :: t()
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

  # The steps "If ! IsReadableStream(this) is false" and "If !
  # IsWritableStream(destination) is false": `pipe_to/3` rejects, and
  # `pipe_through/3` raises.
  defp acquire_reader_for_pipe(%__MODULE__{} = readable), do: get_reader(readable)

  defp acquire_reader_for_pipe(readable) do
    raise TypeError, "The source of a pipe must be a ReadableStream, got: #{inspect(readable)}"
  end

  defp acquire_writer_for_pipe(%WritableStream{} = writable),
    do: WritableStream.get_writer(writable, :pipe)

  defp acquire_writer_for_pipe(writable) do
    raise TypeError,
          "The destination of a pipe must be a WritableStream, got: #{inspect(writable)}"
  end

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
      # cancelled.
      [branch1, branch2] = for index <- [1, 2], do: new(tee_branch_source(tee_module, tee, index))

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

  # The tee takes the BYOB request of the branch when it reads: see
  # `Web.Internal.ReadableByteStreamTee`.
  defp tee_branch_source(ReadableByteStreamTee, tee, index) do
    %{
      type: "bytes",
      pull: fn _controller -> ReadableByteStreamTee.pull(tee, index) end,
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
          # The lock step of the reader asks again for a process that
          # stopped before its first read.
          _process_readable_used_or_gone -> reduce_process(stream, acc, fun)
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
