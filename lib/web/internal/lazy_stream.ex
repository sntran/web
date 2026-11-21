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
  #
  # `tla/LazyStream.tla` has the transitions of the state that copies in
  # different processes do at the same time.

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

  # The values of the state, in the first element of the array, the cell.
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
  #   * starting: a starter starts a stream process that has the bytes.
  #   * starting_closed: a starter starts a closed stream process.
  #   * process: a stream process with the bytes exists, or existed, and it
  #     did not give them out. A stream process that stopped before its
  #     first pull did not take the bytes from the other copies: the next
  #     read gets them.
  #   * taken: the stream process gave the bytes out (its first pull, or a
  #     cancel), or it has no bytes of the struct: a closed stream, or the
  #     stream of a holder.
  @readable 0
  @consumed 1
  @canceled 2
  @locked 3
  @starting 4
  @process 5
  @starting_closed 6
  @taken 7

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
  `{:process, pid}`, and `:gone` when that process stopped after it gave
  the bytes out. A stream process that stopped before it gave the bytes
  out gives `:readable`: the next read gets the bytes.
  """
  @spec state(t()) :: state()
  def state(%__MODULE__{ref: ref} = lazy) do
    if local?(ref), do: decode(lazy, :atomics.get(ref, 1)), else: remote(lazy, :state, [], :gone)
  end

  @doc """
  Changes the state from `:readable` to `to`, also when a stream process
  stopped before it gave the bytes out. Returns `:ok`, or the state that
  the stream has.
  """
  @spec claim(t(), :consumed | :canceled | :locked) :: :ok | state()
  def claim(%__MODULE__{ref: ref} = lazy, to) do
    if local?(ref), do: local_claim(lazy, to), else: remote(lazy, :claim, [to], :gone)
  end

  # One compare-exchange from a cell whose bytes no process has: "readable",
  # or "process" with a stream process that stopped before it gave the
  # bytes out. A cell that changed in between gives a second try.
  defp local_claim(lazy, to), do: claim_from(lazy, to, :atomics.get(lazy.ref, 1))

  defp claim_from(lazy, to, current) do
    if bytes_free?(lazy, current) do
      changed = :atomics.compare_exchange(lazy.ref, 1, current, encode(to))
      if changed == :ok, do: :ok, else: claim_from(lazy, to, changed)
    else
      with :readable <- decode(lazy, current), do: local_claim(lazy, to)
    end
  end

  defp bytes_free?(_lazy, @readable), do: true
  defp bytes_free?(lazy, @process), do: live_stream(lazy) == nil
  defp bytes_free?(_lazy, _current), do: false

  defp encode(:consumed), do: @consumed
  defp encode(:canceled), do: @canceled
  defp encode(:locked), do: @locked

  defp decode(_lazy, @readable), do: :readable
  defp decode(_lazy, @consumed), do: :consumed
  defp decode(_lazy, @canceled), do: :canceled
  defp decode(_lazy, @locked), do: :locked

  # A copy that finds the state "starting" waits for the end of the start.
  defp decode(lazy, current) when current in [@starting, @starting_closed] do
    :ok = await_start(lazy, Web.Promise.owner())
    decode(lazy, :atomics.get(lazy.ref, 1))
  end

  # A stream process that stopped before its first pull did not take the
  # bytes. The cell must have the same value after the look in the
  # registry: a pull between the two looks sets "taken".
  defp decode(lazy, @process) do
    case live_stream(lazy) do
      nil -> confirm(lazy, @process, :readable)
      pid -> {:process, pid}
    end
  end

  defp decode(lazy, @taken) do
    case live_stream(lazy) do
      nil -> :gone
      pid -> {:process, pid}
    end
  end

  defp confirm(lazy, current, state) do
    now = :atomics.get(lazy.ref, 1)
    if now == current, do: state, else: decode(lazy, now)
  end

  # The stream process, when it is alive. The registry is the truth: the
  # stream process registers itself before a starter sets the state
  # "process" or "taken", and the registry removes the key some time after
  # the process stopped.
  defp live_stream(%__MODULE__{ref: ref}) do
    case Registry.lookup(@registry, ref) do
      [{pid, _value}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # The stream process
  #
  # The process of a copy can stop at each step: it is a process of the
  # user. Thus the copy does not start the stream process itself. A short
  # process, the starter, starts it and stops. The copy that asks for the
  # stream process, and each copy that finds the state "starting", monitor
  # the starter: the end of the starter tells them to read the state again.
  # No copy waits for a time limit.
  #
  # The starter registers the key `{ref, :start}` before it changes the
  # state. Thus one starter at most works, and the copies find it. The
  # registry removes the key of a starter that stopped: the next starter
  # continues from the state that it finds. The stream process takes the
  # bytes at its first pull, which comes with the first read, not at its
  # start. Thus a stream process that stops before a read takes no bytes
  # from the other copies. See `tla/LazyStream.tla`.
  # ---------------------------------------------------------------------------

  @doc """
  Returns the stream process, and starts it if necessary. `owner` is the
  owner of a new process. A stream that a read used gives a closed stream.
  Returns `{:error, :already_locked}` for a stream in the state `:locked`,
  and `{:error, :released}` when the process stopped after it gave the
  bytes out.
  """
  @spec process(t(), pid()) :: {:ok, pid()} | {:error, :already_locked | :released}
  def process(%__MODULE__{ref: ref} = lazy, owner) do
    if local?(ref),
      do: local_process(lazy, owner),
      else: remote(lazy, :process, [owner], {:error, :released})
  end

  # The registry first, then the cell: a stream process registers itself
  # before a starter sets a state that is not "starting". Thus a copy gets
  # a stream process only after its start.
  defp local_process(lazy, owner) do
    pid = live_stream(lazy)

    case {:atomics.get(lazy.ref, 1), pid} do
      {@locked, _pid} ->
        {:error, :already_locked}

      {starting, _pid} when starting in [@starting, @starting_closed] ->
        :ok = await_start(lazy, owner)
        local_process(lazy, owner)

      {_current, pid} when is_pid(pid) ->
        {:ok, pid}

      {@taken, nil} ->
        {:error, :released}

      {_readable_used_or_stopped, nil} ->
        :ok = run_starter(lazy, owner)
        local_process(lazy, owner)
    end
  end

  # The copy waits for the starter that has the key. With no starter, the
  # starter that set "starting" stopped before its end: a new starter
  # continues its work.
  defp await_start(lazy, owner) do
    case Registry.lookup(@registry, {lazy.ref, :start}) do
      [{starter, _value}] -> await_down(starter)
      [] -> run_starter(lazy, owner)
    end
  end

  # The starter runs with the context of the copy, thus the stream process
  # has the values of the copy.
  defp run_starter(lazy, owner) do
    snapshot = Snapshot.take()
    copy = self()

    {starter, monitor} =
      spawn_monitor(fn -> Snapshot.run(snapshot, fn -> starter(lazy, owner, copy) end) end)

    receive do
      # A different starter has the key: the copy waits for its end.
      {:DOWN, ^monitor, :process, ^starter, {:busy, other}} -> await_down(other)
      {:DOWN, ^monitor, :process, ^starter, _reason} -> :ok
    end
  end

  defp await_down(pid) do
    monitor = Process.monitor(pid)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    end
  end

  defp starter(lazy, owner, copy) do
    case Registry.register(@registry, {lazy.ref, :start}, nil) do
      {:ok, _partition} -> start(lazy, {owner, copy}, :atomics.get(lazy.ref, 1))
      {:error, {:already_registered, other}} -> exit({:busy, other})
    end
  end

  # The starter has the key. It changes the state with one compare-exchange,
  # or it continues the work of a starter that stopped. A cell that changed
  # before the compare-exchange gives a second decision.
  defp start(lazy, asker, current) do
    case {current, live_stream(lazy)} do
      # The stream process of a starter that stopped before it set the
      # state: this starter sets it.
      {starting, pid} when starting in [@starting, @starting_closed] and is_pid(pid) ->
        publish(lazy, starting, pid)

      {starting, nil} when starting in [@starting, @starting_closed] ->
        start_stream_process(lazy, asker, starting)

      {free, nil} when free in [@readable, @process] ->
        start(lazy, asker, swap(lazy.ref, current, @starting))

      {used, nil} when used in [@consumed, @canceled] ->
        start(lazy, asker, swap(lazy.ref, current, @starting_closed))

      # A claim, or a stream process: the starter has no work. A copy
      # starts a starter only for a different state: this state comes from a
      # claim or a start of a different copy between the two looks.
      # coveralls-ignore-start
      _locked_taken_or_process ->
        :ok
        # coveralls-ignore-stop
    end
  end

  # Returns the new value, or the value that the cell has.
  defp swap(ref, current, to) do
    changed = :atomics.compare_exchange(ref, 1, current, to)
    if changed == :ok, do: to, else: changed
  end

  defp start_stream_process(lazy, {owner, copy}, starting) do
    initial = if starting == @starting, do: :readable, else: :closed

    # A signal that aborted before this time errors the new stream, as it
    # errored a stream process that existed at the abort.
    lazy =
      case {initial, check_signal(lazy)} do
        {:readable, {:error, reason}} -> %{lazy | source: {:error, reason}}
        _no_abort_or_closed -> lazy
      end

    stream =
      Web.AsyncContext.with_signal(lazy.signal, fn -> start_stream(lazy, initial, owner) end)

    # The copy that asked stopped before it got the process: no reader
    # keeps the process, and a process whose owner failed stops at once.
    # The starter stops it, thus the next read starts a new process with
    # the bytes.
    if initial == :closed or Process.alive?(copy) do
      publish(lazy, starting, stream.controller_pid)
    else
      Web.Stream.stop(stream.controller_pid)
      _ = :atomics.compare_exchange(lazy.ref, 1, @starting, @readable)
      :ok
    end
  end

  # The state after the start: "process" for a stream process that has the
  # bytes, and "taken" for each other stream process. The first pull can
  # come before this step: it set "taken".
  defp publish(%{source: {:held, holder}} = lazy, @starting, pid) do
    # The holder gives its bytes to the stream process. A second message,
    # from the starter after a starter that stopped, has no effect.
    send(holder, {:web_body, lazy.ref, {:stream, pid}})
    _ = :atomics.compare_exchange(lazy.ref, 1, @starting, @taken)
    :ok
  end

  defp publish(lazy, @starting, _pid) do
    _ = :atomics.compare_exchange(lazy.ref, 1, @starting, @process)
    :ok
  end

  defp publish(lazy, @starting_closed, _pid) do
    _ = :atomics.compare_exchange(lazy.ref, 1, @starting_closed, @taken)
    :ok
  end

  # The first pull of a stream process, or its cancel: the bytes go out.
  # A copy gets the stream process only after its start, thus the cell has
  # "process", or "taken" after a pull.
  defp mark_taken(ref) do
    _ = :atomics.compare_exchange(ref, 1, @process, @taken)
    :ok
  end

  # The stream process takes the chunks at its first pull, not at its
  # start. A source with bytes has the high water mark 0: the first pull
  # comes with the first read. A source with no bytes, or with an error,
  # has no bytes to keep: its stream process closes, or goes to the errored
  # state, at its start, as the stream of an empty body in the Fetch
  # Standard. The functions of this library that do not raise put the
  # chunks in the stream: an abort of the signal can come at the same time.
  defp start_stream(%{source: {kind, _bytes}} = lazy, :readable, owner)
       when kind in [:bytes, :chunk, :view, :error] do
    ref = lazy.ref
    chunks = chunks(lazy.source)

    source =
      lazy
      |> stream_type()
      |> Map.put(:pull, fn controller -> pull_source(ref, chunks, controller.pid) end)
      |> Map.put(:cancel, &discard(ref, &1))

    high_water_mark = if match?({:ok, [_chunk | _rest]}, chunks), do: 0, else: 1

    Web.ReadableStream.__new__(source, [owner: owner, high_water_mark: high_water_mark],
      registry_key: ref
    )
  end

  # The holder enqueues the chunks that it has, and then each chunk that it
  # reads. A holder that stops before the end puts the stream in the errored
  # state. A cancel stops the holder, thus its connection does not stay. The
  # stream is a byte stream, as the body of a response of the network in the
  # Fetch Standard. The starter tells the holder the stream process: see
  # `publish/3`.
  defp start_stream(%{source: {:held, holder}} = lazy, :readable, owner) do
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
  end

  # A read used the bytes, or a cancel came: the new process is a closed
  # stream that a read used. It closes itself at its first pull, which
  # comes at once: no step of the starter is necessary.
  defp start_stream(lazy, :closed, owner) do
    Web.ReadableStream.__new__(
      lazy |> stream_type() |> Map.put(:pull, &Web.ReadableStream.close(&1.pid)),
      [owner: owner, high_water_mark: 1],
      registry_key: lazy.ref,
      disturbed: true
    )
  end

  # A cancel discards the bytes. The lifetime rules also cancel a stream
  # process whose owner stopped, with the reason `{:owner_down, reason}`: no
  # reader got the bytes, and the next read gets them.
  defp discard(_ref, {:owner_down, _reason}), do: :ok
  defp discard(ref, _reason), do: mark_taken(ref)

  defp pull_source(ref, {:ok, chunks}, pid) do
    if chunks != [], do: :ok = mark_taken(ref)
    for chunk <- chunks, do: Web.ReadableStream.enqueue(pid, chunk)
    Web.ReadableStream.close(pid)
  end

  defp pull_source(_ref, {:error, error}, pid), do: Web.ReadableStream.error(pid, error)

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
