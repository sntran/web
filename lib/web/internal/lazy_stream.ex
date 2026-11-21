defmodule Web.Internal.LazyStream do
  @moduledoc false

  # A readable stream that has no process yet.
  #
  # A body that has all its bytes, such as `ReadableStream.from("text")`,
  # the body of `Web.Response.new/1`, or the body of a `fetch` response that
  # was complete with its headers, needs no process for a read of all its
  # bytes: `text/1`, `json/1`, and the other body functions take the bytes.
  # A stream read, such as `get_reader/1`, a pipe, `tee/1` of a body that a
  # process holds, or `Enum`, starts the stream process at that time.
  #
  # A source is one of:
  #
  #   * `{:bytes, binary}`: all the bytes of a body are in the struct. No
  #     bytes give no chunk, and the stream process is a byte stream, as in
  #     the Fetch Standard;
  #   * `{:chunk, binary}`: one chunk of `ReadableStream.from/1`, also when
  #     it has no bytes;
  #   * `{:view, view}`: a `Web.Uint8Array`, which is the chunk of the stream
  #     with no copy, as before a stream had no process;
  #   * `{:error, reason}`: a body that failed before a read, such as a
  #     `fetch` body whose connection failed. Each read gets the error;
  #   * `{:held, pid}`: a process holds the bytes, or reads them. That is the
  #     process of a `fetch` request whose body was not complete when the
  #     promise of `fetch` settled: see `Web.Dispatcher.HTTP`.
  #
  # The four problems of a stream with no process, and their solutions:
  #
  #   1. A struct is a value: all its copies must have one state. The state
  #      is one element of an `:atomics` array, as the detached flag of
  #      `Web.ArrayBuffer`. All the copies have the same reference, and a
  #      compare-exchange lets one copy only take the bytes or start the
  #      process. The stream process registers itself with the reference as
  #      its key, thus each copy finds the same process. The registry
  #      removes the key when the process stops, also when it is killed.
  #   2. The abort signal of a request errors its body. With no process, no
  #      process gets the abort. Thus each read examines the signal, and a
  #      stream process that starts later subscribes to it. The result is
  #      the same as that of a stream process that got the abort: a read
  #      before the abort gets the bytes, and a read after it rejects.
  #   3. Each function of `Web.ReadableStream` accepts this form. A function
  #      that needs a process gets it from `process/2`.
  #   4. An `:atomics` array and a registry are local to one node. A copy on
  #      a different node does each operation on the node of the array, with
  #      `:erpc`. When no copy stays on that node, the VM collects the
  #      array, and the stream is not available, as a stream whose process
  #      stopped.

  alias Web.AbortSignal
  alias Web.AsyncContext.Snapshot

  @enforce_keys [:ref, :source]
  defstruct [:ref, :source, :signal]

  @type source ::
          {:bytes, binary()}
          | {:chunk, binary()}
          | {:view, Web.Uint8Array.t()}
          | {:error, term()}
          | {:held, pid()}
  @type t :: %__MODULE__{
          ref: :atomics.atomics_ref(),
          source: source(),
          signal: AbortSignal.t() | nil
        }

  @type state ::
          :readable | :consumed | :canceled | :locked | {:process, pid()} | :gone

  # The values of the state, in the first element of the array.
  #
  #   * readable: no read, no process.
  #   * consumed: an enumeration took all the bytes. The stream is closed
  #     and disturbed, and it has no lock.
  #   * canceled: a cancel came before a read. The stream is closed and
  #     disturbed.
  #   * locked: the bytes went to a reader that keeps its lock: the two
  #     branches of a tee, a body function such as `text/1`, or the proxy of
  #     a new request. The stream is locked and disturbed, as in the Streams
  #     Standard and the Fetch Standard.
  #   * starting: a process starts the stream process.
  #   * process: the stream process exists. The registry has it.
  @readable 0
  @consumed 1
  @canceled 2
  @locked 3
  @starting 4
  @process 5

  @registry Web.StreamRegistry

  # A body that a process holds keeps this number of bytes before the
  # process waits for a read. A stream from it has the same limit.
  @held_high_water_mark 65_536

  @doc "The name of the registry of the stream processes."
  def registry, do: @registry

  @doc """
  Makes a stream with no process. The signal is the ambient abort signal,
  or the signal of the request of a `fetch` body.
  """
  @spec new(source(), AbortSignal.t() | nil) :: t()
  def new(source, signal \\ ambient_signal()) do
    %__MODULE__{ref: :atomics.new(1, signed: false), source: source, signal: abort_signal(signal)}
  end

  # A request can have a signal in a different form, which cannot abort a
  # body.
  defp abort_signal(%AbortSignal{} = signal), do: signal
  defp abort_signal(_other), do: nil

  defp ambient_signal, do: Snapshot.take().ambient_signal

  # ---------------------------------------------------------------------------
  # The state
  # ---------------------------------------------------------------------------

  @doc """
  Returns the state of the stream. A stream that has a process gives
  `{:process, pid}`, and `:gone` when that process stopped.
  """
  @spec state(t()) :: state()
  def state(%__MODULE__{ref: ref} = lazy) do
    if local?(ref), do: decode(lazy, :atomics.get(ref, 1)), else: remote(lazy, :state, [], :gone)
  end

  @doc """
  Changes the state from `:readable` to `to`. Returns `:ok`, or the state
  that the stream has.
  """
  @spec claim(t(), :consumed | :canceled | :locked) :: :ok | state()
  def claim(%__MODULE__{ref: ref} = lazy, to) do
    if local?(ref) do
      case :atomics.compare_exchange(ref, 1, @readable, encode(to)) do
        :ok -> :ok
        current -> decode(lazy, current)
      end
    else
      remote(lazy, :claim, [to], :gone)
    end
  end

  defp encode(:consumed), do: @consumed
  defp encode(:canceled), do: @canceled
  defp encode(:locked), do: @locked

  defp decode(_lazy, @readable), do: :readable
  defp decode(_lazy, @consumed), do: :consumed
  defp decode(_lazy, @canceled), do: :canceled
  defp decode(_lazy, @locked), do: :locked
  defp decode(lazy, @starting), do: await_process(lazy, 0)
  defp decode(lazy, @process), do: lookup(lazy)

  # The process that starts the stream process sets the state `process` in
  # some microseconds.
  @wait_steps 5_000

  defp await_process(lazy, step) when step < @wait_steps do
    if step < 100, do: :erlang.yield(), else: Process.sleep(1)

    case :atomics.get(lazy.ref, 1) do
      @starting -> await_process(lazy, step + 1)
      other -> decode(lazy, other)
    end
  end

  # coveralls-ignore-next-line
  defp await_process(_lazy, _step), do: :gone

  # The registry removes the key of a process that stopped some time after
  # the stop, thus the process must be alive.
  defp lookup(%__MODULE__{ref: ref}) do
    case Registry.lookup(@registry, ref) do
      [{pid, _value}] -> if Process.alive?(pid), do: {:process, pid}, else: :gone
      [] -> :gone
    end
  end

  # ---------------------------------------------------------------------------
  # The stream process
  # ---------------------------------------------------------------------------

  @doc """
  Returns the stream process, and starts it if necessary. `owner` is the
  owner of a new process. A stream that a read used gives a closed stream.
  Returns `{:error, :already_locked}` for a stream in the state `:locked`,
  and `{:error, :released}` when the process stopped.
  """
  @spec process(t(), pid()) :: {:ok, pid()} | {:error, :already_locked | :released}
  def process(%__MODULE__{ref: ref} = lazy, owner) do
    if local?(ref),
      do: local_process(lazy, owner),
      else: remote(lazy, :process, [owner], {:error, :released})
  end

  # One compare-exchange from the state that the stream has: a stream that
  # a read used, or that a cancel closed, gets a closed stream process.
  defp local_process(lazy, owner, expected \\ @readable) do
    case :atomics.compare_exchange(lazy.ref, 1, expected, @starting) do
      :ok -> start(lazy, if(expected == @readable, do: :readable, else: :closed), owner)
      current when current in [@consumed, @canceled] -> local_process(lazy, owner, current)
      current -> existing_process(decode(lazy, current))
    end
  end

  defp existing_process({:process, pid}), do: {:ok, pid}
  defp existing_process(:locked), do: {:error, :already_locked}
  defp existing_process(_gone), do: {:error, :released}

  defp start(lazy, initial, owner) do
    # A signal that aborted before this time errors the new stream, as it
    # errored a stream process that existed at the abort.
    lazy =
      case {initial, check_signal(lazy)} do
        {:readable, {:error, reason}} -> %{lazy | source: {:error, reason}}
        _no_abort_or_closed -> lazy
      end

    stream =
      Web.AsyncContext.with_signal(lazy.signal, fn ->
        start_stream(lazy, initial, owner)
      end)

    :atomics.put(lazy.ref, 1, @process)
    {:ok, stream.controller_pid}
  end

  # The functions of this library that do not raise put the chunks in the
  # stream: an abort of the signal can come at the same time.
  defp start_stream(%{source: {kind, _bytes}} = lazy, :readable, owner)
       when kind in [:bytes, :chunk, :view] do
    {:ok, chunks} = chunks(lazy.source)

    Web.ReadableStream.__new__(
      lazy
      |> stream_type()
      |> Map.put(:start, fn controller ->
        for chunk <- chunks, do: Web.ReadableStream.enqueue(controller.pid, chunk)
        Web.ReadableStream.close(controller.pid)
      end),
      [owner: owner],
      registry_key: lazy.ref
    )
  end

  defp start_stream(%{source: {:error, error}} = lazy, :readable, owner) do
    Web.ReadableStream.__new__(
      %{start: &Web.ReadableStream.error(&1.pid, error)},
      [owner: owner],
      registry_key: lazy.ref
    )
  end

  # The holder enqueues the chunks that it has, and then each chunk that it
  # reads. A holder that stops before the end puts the stream in the errored
  # state. A cancel stops the holder, thus its connection does not stay. The
  # stream is a byte stream, as the body of a response of the network in the
  # Fetch Standard.
  defp start_stream(%{source: {:held, holder}} = lazy, :readable, owner) do
    stream =
      Web.ReadableStream.__new__(
        %{type: "bytes", cancel: fn _reason -> Process.exit(holder, :kill) end},
        [
          high_water_mark: @held_high_water_mark,
          cancel_on_reader_exit: true,
          owner: owner
        ],
        direct_pull: {:message, holder, {:web_body, lazy.ref, :pull}},
        watch_source: {holder, &incomplete_error/1},
        registry_key: lazy.ref
      )

    send(holder, {:web_body, lazy.ref, {:stream, stream.controller_pid}})
    stream
  end

  # A read used the bytes, or a cancel came: the new process is a closed
  # stream that a read used.
  defp start_stream(lazy, :closed, owner) do
    Web.ReadableStream.__new__(
      lazy |> stream_type() |> Map.put(:start, &Web.ReadableStream.close(&1.pid)),
      [owner: owner],
      registry_key: lazy.ref,
      disturbed: true
    )
  end

  # The body of a request or a response is a byte stream: the Fetch
  # Standard sets it up "with byte reading support". Thus a BYOB reader can
  # read it. A stream of `ReadableStream.from/1` is a default stream.
  defp stream_type(%{source: {:bytes, _binary}}), do: %{type: "bytes"}
  defp stream_type(_lazy), do: %{}

  @doc false
  # The error of a body whose holder stopped before the end of the body.
  def incomplete_error(reason) do
    %Web.TypeError{
      message: "The response body is not complete.",
      cause: {:connection_process_stopped, reason}
    }
  end

  # ---------------------------------------------------------------------------
  # Reads with no process
  # ---------------------------------------------------------------------------

  @doc """
  Takes all the bytes for a body function, such as `text/1`. The stream
  goes to the state `:locked` before the function returns, as the reader
  of a body function of the Fetch Standard keeps its lock.

  Returns `{:ok, binary}`, `{:error, reason}` for an abort or a failure of
  the body, `:held` for a source `{:held, pid}`, `:used` for a stream that
  a read used, `:locked`, or `{:process, pid}` when the stream has a
  process. After `:held`, `take_held/1` gives the bytes.
  """
  @spec take(t()) ::
          {:ok, binary()} | {:error, term()} | :held | :used | :locked | {:process, pid()}
  def take(%__MODULE__{} = lazy) do
    case claim(lazy, :locked) do
      :ok -> take_source(lazy)
      :locked -> :locked
      {:process, pid} -> {:process, pid}
      _consumed_canceled_or_gone -> :used
    end
  end

  defp take_source(%{source: {kind, binary}} = lazy) when kind in [:bytes, :chunk] do
    with :ok <- check_signal(lazy), do: {:ok, binary}
  end

  defp take_source(%{source: {:view, view}} = lazy) do
    with :ok <- check_signal(lazy), do: {:ok, Web.Uint8Array.to_binary(view)}
  end

  defp take_source(%{source: {:error, error}} = lazy) do
    with :ok <- check_signal(lazy), do: {:error, error}
  end

  defp take_source(%{source: {:held, _holder}}), do: :held

  @doc """
  Gives all the bytes of a source `{:held, pid}` after `take/1` gave
  `:held`. The call waits until the holder has all the bytes.
  """
  @spec take_held(t()) :: {:ok, binary()} | {:error, term()}
  def take_held(%__MODULE__{source: {:held, holder}} = lazy) do
    with :ok <- check_signal(lazy) do
      monitor = Process.monitor(holder)
      send(holder, {:web_body, lazy.ref, {:take, monitor, self()}})

      receive do
        {^monitor, result} ->
          Process.demonitor(monitor, [:flush])
          result

        # An abort stops the holder: the reason of the signal is the error.
        {:DOWN, ^monitor, :process, _holder, reason} ->
          with :ok <- check_signal(lazy), do: {:error, incomplete_error(reason)}
      end
    end
  end

  @doc """
  Gives the chunk of a source `{:bytes, binary}` to an enumeration, with no
  process. Returns `{:ok, [chunk]}`, `{:error, reason}`, or the state of a
  stream that a read used or that has a process.
  """
  @spec take_chunks(t()) :: {:ok, [Web.Uint8Array.t()]} | {:error, term()} | state()
  def take_chunks(%__MODULE__{source: {kind, _bytes}} = lazy)
      when kind in [:bytes, :chunk, :view, :error] do
    case claim(lazy, :consumed) do
      :ok -> with :ok <- check_signal(lazy), do: chunks(lazy.source)
      state -> state
    end
  end

  def take_chunks(%__MODULE__{} = lazy), do: state(lazy)

  @doc """
  Cancels a stream with no process. Returns `:ok`, `:locked`, or
  `{:process, pid}`.
  """
  @spec cancel(t()) :: :ok | :locked | {:process, pid()}
  def cancel(%__MODULE__{} = lazy) do
    case claim(lazy, :canceled) do
      :ok ->
        stop_holder(lazy)
        :ok

      :locked ->
        :locked

      {:process, pid} ->
        {:process, pid}

      # A cancel of a closed stream, or of a stream that stopped.
      _closed ->
        :ok
    end
  end

  defp stop_holder(%{source: {:held, holder}}), do: Process.exit(holder, :kill)
  defp stop_holder(_lazy), do: :ok

  @doc """
  The two branches of a tee of a source `{:bytes, binary}`, with no
  process. Returns `{:ok, [branch, branch]}`, or the state of the stream.
  """
  @spec tee(t()) :: {:ok, [t()]} | state()
  def tee(%__MODULE__{source: {kind, _bytes} = source} = lazy)
      when kind in [:bytes, :chunk, :view, :error] do
    case claim(lazy, :locked) do
      :ok -> {:ok, [new(source, lazy.signal), new(source, lazy.signal)]}
      state -> state
    end
  end

  def tee(%__MODULE__{} = lazy), do: state(lazy)

  @doc """
  The proxy of a source with its bytes in memory, with no process: the
  step "create a proxy" of the Streams Standard for the body of a new
  request. The stream goes to the state `:locked`, and the new stream has
  the same bytes. Returns `{:ok, stream}`, or the state of the stream.
  """
  @spec proxy(t()) :: {:ok, t()} | state()
  def proxy(%__MODULE__{source: {kind, _bytes} = source} = lazy)
      when kind in [:bytes, :chunk, :view, :error] do
    case claim(lazy, :locked) do
      :ok -> {:ok, new(source, lazy.signal)}
      state -> state
    end
  end

  def proxy(%__MODULE__{} = lazy), do: state(lazy)

  # The chunks of a source of bytes: a new view for a binary, and the view of
  # the source with no copy. No bytes give no chunk, as for a body in the
  # Fetch Standard: it enqueues bytes only when bytes are available.
  defp chunks({:bytes, ""}), do: {:ok, []}
  defp chunks({:view, view}), do: {:ok, [view]}
  defp chunks({:error, error}), do: {:error, error}
  defp chunks({_bytes_or_chunk, binary}), do: {:ok, [Web.Uint8Array.from(binary)]}

  defp check_signal(%{signal: nil}), do: :ok

  defp check_signal(%{signal: signal}) do
    case AbortSignal.reason(signal) do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # A copy on a different node
  # ---------------------------------------------------------------------------

  defp local?(ref), do: node(ref) == node()

  # The function runs on the node of the array. A reference that comes back
  # to its node is the reference of the array again, while one copy of the
  # struct stays on that node. When no copy stays, or the node is not
  # available, the result is `gone`.
  defp remote(%__MODULE__{ref: ref} = lazy, function, args, gone) do
    :erpc.call(node(ref), __MODULE__, function, [lazy | args])
  catch
    :error, _reason -> gone
  end
end
