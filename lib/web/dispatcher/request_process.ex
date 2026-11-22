defmodule Web.Dispatcher.RequestProcess do
  @moduledoc false

  # The process of a request of a dispatcher, and the body that it holds.
  # `Web.Dispatcher.HTTP` and `Web.Dispatcher.TCP` use it.
  #
  # The promise of `fetch` is a small process: the process of the request.
  # It owns the socket of its connection while the response comes, and
  # holds the body. The socket sends its messages to it directly, and it
  # never waits in a blocking call. Thus it always answers: the readers,
  # the abort signal, and the time limits.
  #
  #   * At the start of the body, the process waits for the end of the body
  #     for 1 ms. A body that ends in that time goes in the struct of the
  #     response, and the process stops. Thus a small response has no
  #     process, and `text/1` starts none. See `Web.Internal.LazyStream`.
  #   * Else the promise settles with the response, as the Fetch Standard
  #     specifies, and the process holds the body. A read of all the bytes,
  #     such as `text/1`, gets them in one message at the end of the body. A
  #     stream read makes a stream process, and the process gives each piece
  #     to it when it pulls.
  #   * The network side stops to read its socket while the process has
  #     64 KiB that no reader took: the backpressure. See `credit/1` of the
  #     network module.
  #   * A body that no process reads in the time of `unread_body_timeout`
  #     releases its connection, and a later read rejects. When the owner
  #     stops, the body waits for the linger time, as a stream does.
  #
  # A connection that fails before the end of the body gives an error to
  # each read: a body that is not complete never looks complete. A cancel or
  # an abort closes the connection. See `tla/ResponseBody.tla`.
  #
  # The network side is a module with the callbacks below. Its functions
  # run in the process of the request, and keep their state in its process
  # dictionary. It gives the events of the response in their sequence:
  # first the events of the dispatcher, then `{:data, piece}` for each piece
  # of the body, and `:done` or `{:error, reason}` at the end.

  alias Web.AsyncContext.Snapshot
  alias Web.Internal.ContentDecoder
  alias Web.Internal.LazyStream
  alias Web.Internal.PromiseCell
  alias Web.ReadableStream

  @doc "The next event of the response, or `:none` when no event is ready."
  @callback next() :: {:ok, term()} | :none

  @doc "Takes a message of the network. Returns `:unknown` for a different message."
  @callback handle(term()) :: :handled | :unknown

  @doc "The time in milliseconds until the receive timeout, or `:infinity`."
  @callback wait_time() :: timeout()

  @doc "The receive timeout is over: the request fails."
  @callback expire() :: :ok

  @doc "Bytes of the body left the buffer of the process."
  @callback credit(non_neg_integer()) :: :ok

  @doc "The process used the end of the response, after the promise settled."
  @callback finish() :: :ok

  @doc "Stops the request: the connection closes, and no more events come."
  @callback close() :: :ok

  # The bytes that a body keeps while no process reads it.
  @held_high_water_mark 65_536

  # The time in microseconds that the process waits for the end of the body
  # before the promise settles. A body that ends in this time goes in the
  # struct, and the response has no process. A body that does not end in
  # this time stays in this process, and the promise settles with the
  # headers, as the Fetch Standard specifies.
  @complete_wait 1_000

  # The process of a request starts with a heap for the work of one
  # request: a heap that grows step by step needs garbage collections.
  @heap_words 4_096

  @doc """
  Starts the process of a request, and returns its promise: the process is
  the promise. In the process, `run.(request, context)` does the request
  with the functions of this module. The promise settles with the response,
  or with `rejection.(reason)` for a failure.
  """
  @spec start(Web.Request.t(), module(), (term() -> term()), (Web.Request.t(), map() -> term())) ::
          Web.Promise.t()
  def start(%Web.Request{} = request, network, rejection, run)
      when is_atom(network) and is_function(rejection, 1) and is_function(run, 2) do
    owner = Web.Promise.owner()
    snapshot = Snapshot.new()
    context = %{rejection: rejection, owner: owner, network: network}

    pid =
      :erlang.spawn_opt(
        fn -> Snapshot.run(snapshot, fn -> run_process(request, context, run) end) end,
        min_heap_size: @heap_words
      )

    PromiseCell.promise(pid)
  end

  defp run_process(request, context, run) do
    # The process is the promise of `fetch`: a pending promise stops when its
    # owner stops, and a settled one keeps its outcome for the linger time.
    PromiseCell.start(context.owner)
    Web.Promise.put_owner(context.owner)

    subscription =
      case Web.AbortSignal.subscribe(request.signal) do
        {:ok, subscription} ->
          context = Map.put(context, :subscription, subscription)
          with_request_signal(request.signal, fn -> run.(request, context) end)
          subscription

        {:error, :aborted} ->
          reject(context, :aborted)
          nil
      end

    # The work is complete: the signal has no more use. The process keeps
    # the outcome for the linger time.
    Web.AbortSignal.unsubscribe(subscription)
    PromiseCell.linger()
  end

  # The response of the request, and the streams that a read of its body
  # makes, get the signal of the request. Thus an abort puts the body in the
  # errored state.
  defp with_request_signal(%Web.AbortSignal{} = signal, fun) do
    Web.AsyncContext.with_signal(signal, fun)
  end

  defp with_request_signal(_signal, fun), do: fun.()

  @doc "The promise rejects with `rejection.(reason)`."
  @spec reject(map(), term()) :: :ok
  def reject(context, reason), do: PromiseCell.settle({:rejected, context.rejection.(reason)})

  @doc "The promise fulfils with the response."
  @spec resolve(map(), Web.Response.t()) :: :ok
  def resolve(_context, response), do: PromiseCell.settle({:fulfilled, response})

  @doc """
  The next event. The events of the network, of the signal, and of the
  readers of the body come as messages. Each wait of the process uses this
  function:

    * an event of the network;
    * `:network` for a message of the network that gives no event;
    * `:promise_message` for a message of the promise;
    * `{:aborted, reason}`, `{:owner_down, reason}`, or `{:message, message}`;
    * `:timeout` at the end of `timeout`.
  """
  @spec next_event(map(), timeout()) :: term()
  def next_event(context, timeout) do
    case context.network.next() do
      {:ok, event} -> event
      :none -> receive_event(context, timeout)
    end
  end

  defp receive_event(%{network: network} = context, timeout) do
    wait = network.wait_time()

    receive do
      message ->
        case network.handle(message) do
          :handled -> network_event(network)
          :unknown -> other_event(message, context)
        end
    after
      min(timeout, wait) ->
        if wait <= timeout do
          network.expire()
          network_event(network)
        else
          :timeout
        end
    end
  end

  defp network_event(network) do
    case network.next() do
      {:ok, event} -> event
      :none -> :network
    end
  end

  # A message of the promise: an await, or the end of the owner. Then an
  # abort, a message of a reader, or a message with no use.
  defp other_event(message, context) do
    case PromiseCell.handle(message) do
      :handled -> :promise_message
      {:owner_down, reason} -> {:owner_down, reason}
      :expired -> :promise_message
      :unknown -> abort_or_message(message, context)
    end
  end

  defp abort_or_message(message, context) do
    case abort_event(message, Map.get(context, :subscription)) do
      nil -> {:message, message}
      reason -> {:aborted, reason}
    end
  end

  # The messages of the subscription to the abort signal: see
  # `Web.AbortSignal.receive_abort/3`. A signal whose process stopped is an
  # aborted signal.
  defp abort_event({:abort, ref, reason}, %{type: :abort_signal, ref: ref}), do: reason
  defp abort_event({:abort, pid, reason}, %{type: :pid, pid: pid}), do: reason
  defp abort_event({:abort, token}, %{type: :token, token: token}), do: :aborted
  defp abort_event({:abort, token, reason}, %{type: :token, token: token}), do: reason

  defp abort_event({:DOWN, monitor, :process, _pid, reason}, %{monitor_ref: monitor} = sub) do
    case {sub.type, reason} do
      {:abort_signal, {:shutdown, {:aborted, reason}}} -> reason
      {:abort_signal, _reason} -> Web.AbortSignal.default_reason()
      {:pid, reason} -> reason
    end
  end

  defp abort_event(_message, _subscription), do: nil

  @doc "A pending promise stops when its owner stops, and its work stops."
  @spec stop_request(map()) :: no_return()
  def stop_request(context) do
    context.network.close()
    exit(:normal)
  end

  @doc "An abort before the response: the connection closes, and the promise rejects."
  @spec abort_request(map()) :: :ok
  def abort_request(context) do
    context.network.close()
    reject(context, :aborted)
  end

  # ---------------------------------------------------------------------------
  # The body of the response
  # ---------------------------------------------------------------------------

  @doc """
  The network gives the body of the response. `response.(body)` makes the
  response with a body: the promise settles with it. The process holds the
  body until its end, and then returns.
  """
  @spec hold_body(map(), Web.Request.t(), (ReadableStream.t() -> Web.Response.t())) :: term()
  def hold_body(context, request, response) do
    body = %{
      context: context,
      network: context.network,
      response: response,
      lazy: LazyStream.new({:held, self()}, request.signal),
      pieces: [],
      size: 0,
      ended: nil,
      mode: :buffer,
      taker: nil,
      stream: nil,
      stream_monitor: nil,
      stream_wants?: false,
      deadline: deadline(Web.Application.unread_body_timeout())
    }

    collect(body, System.monotonic_time(:microsecond) + @complete_wait)
  end

  # Before the promise settles: the process collects the body for a short
  # time. A body that ends in this time goes in the struct of the response.
  # The promise settles with the headers at the end of the time, at the
  # limit of the queue, at a failure, or at an abort.
  defp collect(body, until) do
    body.context
    |> next_event(collect_wait(until))
    |> collect_event(body, until)
  end

  defp collect_wait(until) do
    max(div(until - System.monotonic_time(:microsecond) + 999, 1_000), 0)
  end

  defp collect_event({:data, piece}, body, until) do
    body = add_piece(body, piece)
    if body.size >= @held_high_water_mark, do: settle_held(body), else: collect(body, until)
  end

  # The body is complete: it goes in the struct, and the process stops.
  defp collect_event(:done, body, _until) do
    lazy = %{body.lazy | source: {:bytes, bytes(body)}}
    resolve(body.context, body.response.(%ReadableStream{lazy: lazy}))
    body.network.finish()
  end

  # A failure, or an abort, gives a response whose body has the error.
  defp collect_event({:error, reason}, body, _until), do: fail(body, body_error(reason))

  defp collect_event({:aborted, reason}, body, _until) do
    body.network.close()
    fail(body, reason)
  end

  defp collect_event({:owner_down, _reason}, body, _until), do: stop_request(body.context)
  defp collect_event(:timeout, body, _until), do: settle_held(body)

  # A message of the network with no event, a message of the promise, or a
  # message with no use.
  defp collect_event(_other, body, until), do: collect(body, until)

  # The body failed before the promise settled: the response has the error
  # in its struct, and this process stops.
  defp fail(body, error) do
    lazy = %{body.lazy | source: {:error, error}}
    resolve(body.context, body.response.(%ReadableStream{lazy: lazy}))
  end

  # The promise settles with the response, and this process holds its body
  # until a read.
  defp settle_held(body) do
    resolve(body.context, body.response.(%ReadableStream{lazy: body.lazy}))
    hold(body)
  end

  defp add_piece(body, piece) do
    %{body | pieces: [piece | body.pieces], size: body.size + byte_size(piece)}
  end

  defp bytes(body), do: body.pieces |> :lists.reverse() |> IO.iodata_to_binary()

  # The process holds the body. It answers the readers, and applies the
  # lifetime rules of a stream to a body that no process reads.
  defp hold(body) do
    body.context
    |> next_event(hold_timeout(body))
    |> hold_event(body)
  end

  defp hold_event({:data, piece}, body),
    do: body |> add_piece(piece) |> take_piece(piece) |> hold()

  defp hold_event(:done, body) do
    body.network.finish()
    body |> end_body({:ok, :done}) |> hold_or_stop()
  end

  defp hold_event({:error, reason}, body),
    do: body |> end_body({:error, body_error(reason)}) |> hold_or_stop()

  defp hold_event({:aborted, reason}, body), do: abort(body, reason)
  defp hold_event({:owner_down, reason}, body), do: body |> owner_down(reason) |> hold_or_stop()

  defp hold_event({:message, {:web_body, ref, request}}, %{lazy: %{ref: ref}} = body),
    do: body |> reader_request(request) |> hold_or_stop()

  defp hold_event({:message, message}, body), do: body |> other_message(message) |> hold_or_stop()
  defp hold_event(:timeout, body), do: stop_body(body)

  # A message of the network with no event, or a message of the promise.
  defp hold_event(_other, body), do: hold(body)

  defp hold_or_stop(:stop), do: :ok
  defp hold_or_stop(body), do: hold(body)

  # A body that no process reads has a time limit, and the linger time of
  # an owner that stopped.
  defp hold_timeout(%{mode: :buffer} = body), do: remaining(body.deadline)
  defp hold_timeout(_body), do: :infinity

  # A read of all the bytes takes the bytes that the process has, and each
  # subsequent piece: the bytes leave the buffer at once.
  defp reader_request(body, {:take, reply, pid}) do
    body.network.credit(body.size)
    body = %{body | mode: :take, taker: {reply, pid}}
    if body.ended, do: answer_take(body), else: body
  end

  # A stream read. The first pull of the stream process comes with its first
  # read: from that time, the stream gets the pieces that the process has,
  # and then each piece when it pulls. Before that read, this process keeps
  # the bytes, thus a stream process that stops takes none, and the next
  # reader gets them. See `Web.Internal.LazyStream`.
  defp reader_request(%{mode: :buffer} = body, :pull) do
    case LazyStream.__stream__(body.lazy) do
      pid when is_pid(pid) ->
        %{body | mode: :stream, stream: pid, stream_monitor: Process.monitor(pid)}
        |> reader_request(:pull)
        |> close_if_ended()

      # The stream process stopped after its pull: its read took the bytes,
      # and no process can read them. The time limit of a body that no
      # process reads stops this process. The stop comes between the pull and
      # this look: a test cannot make it at a known time.
      # coveralls-ignore-start
      nil ->
        body
        # coveralls-ignore-stop
    end
  end

  defp reader_request(%{mode: :stream, pieces: [_ | _]} = body, :pull), do: flush_pieces(body)
  defp reader_request(body, :pull), do: %{body | stream_wants?: true}

  defp other_message(body, {:DOWN, monitor, :process, _pid, _reason})
       when monitor == body.stream_monitor do
    stop_body(body)
  end

  defp other_message(body, _message), do: body

  # The owner stopped. A body that no process reads waits for the linger
  # time, then it stops. An owner that failed gives no linger time.
  defp owner_down(%{mode: :buffer} = body, reason) when reason in [:normal, :noproc] do
    %{body | deadline: min(body.deadline, deadline(Web.Promise.default_linger()))}
  end

  defp owner_down(%{mode: :buffer} = body, _reason), do: stop_body(body)
  defp owner_down(body, _reason), do: body

  # The end of the body from the network: `{:ok, :done}`, or the error.
  defp end_body(body, ended) do
    body = %{body | ended: ended}

    case body.mode do
      :buffer -> body
      :take -> answer_take(body)
      :stream -> close_if_ended(body)
    end
  end

  defp answer_take(%{taker: {reply, pid}} = body) do
    result =
      case body.ended do
        {:ok, :done} -> {:ok, bytes(body)}
        {:error, error} -> {:error, error}
      end

    send(pid, {reply, result})
    :stop
  end

  # A new piece from the network. A read of all the bytes takes it at once.
  # A stream that wants a chunk gets it.
  defp take_piece(%{mode: :take} = body, piece) do
    body.network.credit(byte_size(piece))
    body
  end

  defp take_piece(%{mode: :stream, stream_wants?: true} = body, _piece), do: flush_pieces(body)
  defp take_piece(body, _piece), do: body

  # The pieces go to the stream, and leave the buffer of the process.
  defp flush_pieces(body) do
    for piece <- :lists.reverse(body.pieces) do
      ReadableStream.enqueue(body.stream, Web.Uint8Array.from(piece))
    end

    if body.size > 0, do: body.network.credit(body.size)
    %{body | pieces: [], size: 0, stream_wants?: false}
  end

  defp close_if_ended(%{ended: nil} = body), do: body

  defp close_if_ended(%{ended: {:ok, :done}} = body) do
    body = flush_pieces(body)
    LazyStream.__close__(body.stream)
    :stop
  end

  defp close_if_ended(%{ended: {:error, error}} = body) do
    ReadableStream.error(body.stream, error)
    :stop
  end

  # An abort errors the body: each read gets the reason of the signal. The
  # connection closes. A stream has the signal of the request: it gets the
  # abort itself.
  defp abort(%{mode: :stream} = body, _reason), do: stop_body(body)

  defp abort(body, reason) do
    body.network.close()

    case body.mode do
      :buffer -> hold(%{body | ended: {:error, reason}, pieces: [], size: 0})
      :take -> answer_take(%{body | ended: {:error, reason}})
    end
  end

  # The body stops with no read: the time limit, the end of the owner, or a
  # stream that stopped. The connection closes, and a later read rejects.
  defp stop_body(body) do
    body.network.close()
    :stop
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  @doc """
  A network error in the body is a `TypeError`, as the Fetch Standard
  specifies.
  """
  @spec body_error(term()) :: Web.TypeError.t()
  def body_error(%ContentDecoder.Error{} = error) do
    %Web.TypeError{message: "The response body cannot be decoded.", cause: error}
  end

  def body_error(reason) do
    %Web.TypeError{message: "The response body is not complete.", cause: reason}
  end
end
