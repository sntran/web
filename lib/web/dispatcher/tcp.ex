# credo:disable-for-this-file Credo.Check.Refactor.Nesting
defmodule Web.Dispatcher.TCP do
  @moduledoc """
  TCP dispatcher implemented on top of `Web.Socket`.

  A dedicated bridge process owns the socket capability, writes the request body,
  and serves chunks into a lightweight `ReadableStream` proxy that closes the
  socket on cancellation or reader-owner exit.
  """

  @behaviour Web.Dispatcher

  alias Web.Internal.Bytes
  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultReader
  alias Web.Request
  alias Web.Response
  alias Web.Socket
  alias Web.TypeError
  alias Web.WritableStream

  @watcher_poll_interval 25

  @impl true
  @spec fetch(Request.t()) :: {:ok, Response.t()} | {:error, any()}
  def fetch(%Request{} = request) do
    do_fetch(request)
  end

  defp do_fetch(%Request{} = request) do
    {host, port} = connection_target(request.url)
    body = normalize_request_body(request)

    case start_socket_bridge(%{hostname: host, port: port}, body, request.signal) do
      {:ok, bridge_pid, socket} ->
        {:ok,
         Response.__network__(
           status: 200,
           status_text: "Connected",
           body: build_body_stream(bridge_pid, socket, request.signal),
           url: Web.URL.href(request.url)
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_body_stream(bridge_pid, socket, signal) do
    # A body that no process starts to read releases its socket after the
    # unread time, as the body of an HTTP response does.
    ReadableStream.new(
      body_source(bridge_pid, socket, signal),
      cancel_on_reader_exit: true,
      unread_timeout: Web.Application.unread_body_timeout()
    )
  end

  # ---------------------------------------------------------------------------
  # Test hooks
  #
  # The tests of this library use these two functions, and the keys
  # `:debug_bridge_pid` and `:debug_socket` of the source, to stop the
  # processes of a connection at a known time.
  # ---------------------------------------------------------------------------

  @doc false
  def __debug_start_socket_bridge__(address, signal) do
    start_socket_bridge(address, nil, signal)
  end

  @doc false
  def __debug_body_source__(bridge_pid, socket, signal) do
    body_source(bridge_pid, socket, signal)
  end

  defp body_source(bridge_pid, socket, signal) do
    %{
      # The monitor of the bridge closes the stream when the bridge stops.
      # Thus the close in these two functions has no check: the stream can
      # be closed already.
      start: fn controller ->
        monitor_bridge(bridge_pid, controller)
        if signal_aborted?(signal), do: abort_body(bridge_pid, socket, signal, controller)
        :ok
      end,
      pull: fn controller ->
        if signal_aborted?(signal) do
          abort_body(bridge_pid, socket, signal, controller)
        else
          request_bridge_pull(bridge_pid, controller)
        end
      end,
      cancel: fn reason ->
        cancel_bridge(bridge_pid, socket, reason)
      end,
      debug_bridge_pid: bridge_pid,
      debug_socket: socket
    }
  end

  defp abort_body(bridge_pid, socket, signal, controller) do
    cancel_bridge(bridge_pid, socket, signal_reason(signal))
    ReadableStream.close(controller.pid)
  end

  defp start_socket_bridge(address, body, signal) do
    caller = self()
    ref = make_ref()

    {bridge_pid, bridge_monitor} =
      spawn_monitor(fn ->
        bridge_boot(caller, ref, address, body, signal)
      end)

    # The socket has the time limit of the connection, thus this wait has
    # an end: the promise `opened` of the socket settles.
    receive do
      {:bridge_ready, ^ref, socket} ->
        Process.demonitor(bridge_monitor, [:flush])
        {:ok, bridge_pid, socket}

      {:bridge_failed, ^ref, reason} ->
        Process.demonitor(bridge_monitor, [:flush])
        {:error, reason}

      # The bridge stopped before the connection was ready.
      {:DOWN, ^bridge_monitor, :process, ^bridge_pid, reason} ->
        {:error, reason}
    end
  end

  defp bridge_boot(caller, ref, address, body, signal) do
    socket = Web.connect(address)

    case await_promise(socket.opened) do
      {:ok, _info} ->
        socket_reader = ReadableStream.get_reader(socket.readable)

        try do
          _ = write_request_body(socket.writable, body)
          abort_watcher = start_abort_watcher(socket, self(), signal)
          send(caller, {:bridge_ready, ref, socket})

          bridge_loop(%{
            abort_watcher: abort_watcher,
            socket: socket,
            socket_reader: socket_reader
          })
        after
          ReadableStream.release_lock(socket_reader.controller_pid)
        end

      {:error, reason} ->
        send(caller, {:bridge_failed, ref, reason})
        shutdown_bridge(%{abort_watcher: nil, socket: socket}, reason)
    end
  end

  defp bridge_loop(state) do
    receive do
      {:cancel, reason} ->
        shutdown_bridge(state, reason)

      {:abort, reason} ->
        shutdown_bridge(state, reason)

      {:pull, controller_pid, reply_to} ->
        fulfill_pull(state, controller_pid, reply_to)

      _message ->
        bridge_loop(state)
    end
  end

  defp monitor_bridge(bridge_pid, controller) do
    spawn(fn ->
      monitor_ref = Process.monitor(bridge_pid)

      receive do
        # The stream can be closed already, thus this close has no check.
        {:DOWN, ^monitor_ref, :process, ^bridge_pid, _reason} ->
          ReadableStream.close(controller.pid)
      end
    end)

    :ok
  end

  defp cancel_bridge(bridge_pid, socket, reason) do
    _ = await_promise(ReadableStream.cancel(socket.readable.controller_pid, reason))
    send(bridge_pid, {:cancel, reason})
    :ok
  end

  defp signal_aborted?(nil), do: false
  defp signal_aborted?(signal), do: Web.AbortSignal.aborted?(signal)

  defp signal_reason(signal) do
    Web.AbortSignal.reason(signal) || Web.AbortSignal.default_reason()
  end

  # The promise fulfils when the bridge gave a chunk to the stream, or when
  # the bridge stopped.
  defp request_bridge_pull(bridge_pid, controller) do
    Web.Promise.new(fn resolve, _reject ->
      bridge_monitor = Process.monitor(bridge_pid)
      reply_ref = make_ref()
      send(bridge_pid, {:pull, controller.pid, {self(), reply_ref}})

      receive do
        {^reply_ref, :ok} -> Process.demonitor(bridge_monitor, [:flush])
        {:DOWN, ^bridge_monitor, :process, ^bridge_pid, _reason} -> :ok
      end

      resolve.(:ok)
    end)
  end

  defp fulfill_pull(state, controller_pid, {reply_pid, reply_ref}) do
    case await_socket_chunk(state.socket_reader) do
      # The bridge runs at the same time as a cancel of the stream, thus
      # these calls have no check.
      {:chunk, chunk} ->
        ReadableStream.enqueue(controller_pid, Bytes.chunk(chunk))
        send(reply_pid, {reply_ref, :ok})
        bridge_loop(state)

      {:done, reason} ->
        ReadableStream.close(controller_pid)
        send(reply_pid, {reply_ref, :ok})
        shutdown_bridge(state, reason)
    end
  end

  defp await_socket_chunk(socket_reader) do
    # A read with no promise: a promise for each chunk keeps the chunk for
    # the linger time.
    case ReadableStreamDefaultReader.read_now(socket_reader) do
      {:ok, %{done: false, value: chunk}} ->
        {:chunk, chunk}

      {:ok, %{done: true}} ->
        {:done, :closed}

      # The read failed, or a cancel stopped it. The body ends.
      {:error, reason} ->
        {:done, reason}
    end
  end

  defp write_request_body(_writable, nil), do: :ok
  defp write_request_body(_writable, <<>>), do: :ok

  defp write_request_body(writable, body) do
    writer = WritableStream.get_writer(writable)

    try do
      WritableStream.write(writer.controller_pid, writer.owner_pid, body)
    after
      release_writer_lock(writer)
    end
  end

  defp start_abort_watcher(_socket, _bridge_pid, nil), do: nil

  defp start_abort_watcher(socket, bridge_pid, signal) do
    ref = make_ref()

    watcher_pid =
      spawn(fn ->
        bridge_monitor = Process.monitor(bridge_pid)

        case Web.AbortSignal.subscribe(signal) do
          {:ok, subscription} ->
            try do
              watch_for_abort(socket, bridge_pid, bridge_monitor, subscription, ref)
            after
              Web.AbortSignal.unsubscribe(subscription)
              Process.demonitor(bridge_monitor, [:flush])
            end

          {:error, :aborted} ->
            Process.demonitor(bridge_monitor, [:flush])
            abort_socket(socket, bridge_pid, signal_reason(signal))
        end
      end)

    %{pid: watcher_pid, ref: ref}
  end

  defp watch_for_abort(socket, bridge_pid, bridge_monitor, subscription, ref) do
    receive do
      {:stop_abort_watcher, ^ref} ->
        :ok

      {:DOWN, ^bridge_monitor, :process, ^bridge_pid, _reason} ->
        :ok
    after
      @watcher_poll_interval ->
        case Web.AbortSignal.receive_abort(subscription, 0, true) do
          {:error, :aborted, reason} ->
            abort_socket(socket, bridge_pid, reason)

          :ok ->
            watch_for_abort(socket, bridge_pid, bridge_monitor, subscription, ref)
        end
    end
  end

  defp abort_socket(socket, bridge_pid, reason) do
    _ = await_promise(ReadableStream.cancel(socket.readable.controller_pid, reason))
    send(bridge_pid, {:abort, reason})
    :ok
  end

  defp shutdown_bridge(state, reason) do
    stop_abort_watcher(state.abort_watcher)
    close_socket(state.socket, reason)
    :ok
  end

  defp stop_abort_watcher(nil), do: :ok

  defp stop_abort_watcher(%{pid: watcher_pid, ref: ref}) do
    send(watcher_pid, {:stop_abort_watcher, ref})
    :ok
  end

  defp close_socket(socket, reason) do
    _ = Socket.close(socket, reason)
    _ = await_promise(socket.closed)
    :ok
  end

  defp await_promise(%Web.Promise{} = promise) do
    case Web.Promise.wait(promise) do
      {:fulfilled, value} -> {:ok, value}
      {:rejected, reason} -> {:error, reason}
    end
  end

  defp release_writer_lock(writer) do
    WritableStream.release_lock(writer.controller_pid, writer.owner_pid)
  end

  defp normalize_request_body(%Request{method: method}) when method in ["GET", "HEAD"], do: nil
  defp normalize_request_body(%Request{body: body}), do: normalize_request_body_data(body)

  defp normalize_request_body_data(nil), do: nil

  defp normalize_request_body_data(%ReadableStream{} = body),
    do: normalize_request_body_data(Enum.to_list(body))

  defp normalize_request_body_data(body) when is_binary(body), do: body

  defp normalize_request_body_data(body) when is_list(body), do: iodata_to_binary(body)

  defp normalize_request_body_data(body) do
    if Enumerable.impl_for(body) do
      body
      |> Enum.to_list()
      |> iodata_to_binary()
    else
      raise TypeError, "body is not readable"
    end
  end

  # The chunks of a body are chunks of bytes: binaries, `Web.Uint8Array`
  # values, `Web.ArrayBuffer` values, or iodata.
  defp iodata_to_binary(body) when is_list(body) do
    case Bytes.to_binary(body) do
      {:ok, binary} -> binary
      :error -> Enum.map_join(body, &body_chunk_to_binary/1)
    end
  end

  defp body_chunk_to_binary(chunk) do
    case Bytes.to_binary(chunk) do
      {:ok, binary} -> binary
      :error -> raise TypeError, "body is not readable"
    end
  end

  defp connection_target(url) do
    if Web.URL.rclone?(url) or remote_like_url?(url) do
      authority =
        url
        |> Web.URL.pathname()
        |> String.split("/", parts: 2)
        |> List.first()

      parts = String.split(authority, ":", parts: 2)

      host = Enum.at(parts, 0, "localhost")

      port =
        case Enum.at(parts, 1) do
          nil -> 80
          value -> String.to_integer(value)
        end

      {host, port}
    else
      host = Web.URL.hostname(url)

      port =
        case Web.URL.port(url) do
          "" -> 80
          value -> String.to_integer(value)
        end

      {host, port}
    end
  end

  defp remote_like_url?(url) do
    Web.URL.hostname(url) == "" and Web.URL.protocol(url) != "" and
      not String.starts_with?(Web.URL.pathname(url), "/")
  end
end
