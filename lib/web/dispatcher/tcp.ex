# credo:disable-for-this-file Credo.Check.Refactor.Nesting
defmodule Web.Dispatcher.TCP do
  @moduledoc """
  TCP dispatcher implemented on top of `Web.Socket`.

  A dedicated bridge process owns the socket capability, writes the request body,
  and serves chunks into a lightweight `ReadableStream` proxy that closes the
  socket on cancellation or reader-owner exit.
  """

  @behaviour Web.Dispatcher

  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController
  alias Web.ReadableStreamDefaultReader
  alias Web.Request
  alias Web.Response
  alias Web.Socket
  alias Web.TypeError
  alias Web.WritableStream

  @bridge_boot_timeout 6_000
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
         Response.new(
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
    ReadableStream.new(
      body_source(bridge_pid, socket, signal),
      cancel_on_reader_exit: true
    )
  end

  @doc false
  # coveralls-ignore-next-line
  def __debug_start_socket_bridge__(address, body \\ nil, signal \\ nil) do
    start_socket_bridge(address, body, signal)
  end

  @doc false
  def __debug_body_source__(bridge_pid, socket, signal) do
    body_source(bridge_pid, socket, signal)
  end

  @doc false
  def __debug_await_socket_chunk__(socket_reader) do
    await_socket_chunk(socket_reader)
  end

  defp body_source(bridge_pid, socket, signal) do
    %{
      start: fn controller ->
        monitor_bridge(bridge_pid, controller)

        if signal_aborted?(signal) do
          cancel_bridge(bridge_pid, socket, signal_reason(signal))
          ReadableStreamDefaultController.close(controller)
        else
          register_controller(bridge_pid, controller)
        end
      end,
      pull: fn controller ->
        if signal_aborted?(signal) do
          cancel_bridge(bridge_pid, socket, signal_reason(signal))
          ReadableStreamDefaultController.close(controller)
        else
          request_bridge_pull(bridge_pid)
        end
      end,
      cancel: fn reason ->
        cancel_bridge(bridge_pid, socket, reason)
      end,
      debug_bridge_pid: bridge_pid,
      debug_socket: socket
    }
  end

  defp start_socket_bridge(address, body, signal) do
    caller = self()
    ref = make_ref()

    {bridge_pid, bridge_monitor} =
      spawn_monitor(fn ->
        bridge_boot(caller, ref, address, body, signal)
      end)

    receive do
      {:bridge_ready, ^ref, socket} ->
        Process.demonitor(bridge_monitor, [:flush])
        {:ok, bridge_pid, socket}

      {:bridge_failed, ^ref, reason} ->
        Process.demonitor(bridge_monitor, [:flush])
        {:error, reason}

      # coveralls-ignore-start
      {:DOWN, ^bridge_monitor, :process, ^bridge_pid, reason} ->
        {:error, normalize_await_exit_reason(reason)}
        # coveralls-ignore-stop
    after
      @bridge_boot_timeout ->
        Process.exit(bridge_pid, :kill)

        # coveralls-ignore-start
        receive do
          {:DOWN, ^bridge_monitor, :process, ^bridge_pid, _reason} -> :ok
        after
          0 -> :ok
        end

        # coveralls-ignore-stop

        {:error, :timeout}
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
            controller: nil,
            pending_pulls: :queue.new(),
            socket: socket,
            socket_reader: socket_reader
          })
        after
          release_reader_lock(socket_reader)
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
        cancel_controller(state.controller, reason)
        shutdown_bridge(state, reason)

      {:register_controller, controller} ->
        state
        |> Map.put(:controller, controller)
        |> process_pending_pulls()

      {:pull, reply_to} ->
        state
        |> enqueue_pull_request(reply_to)
        |> process_pending_pulls()

      _message ->
        bridge_loop(state)
    end
  end

  defp monitor_bridge(bridge_pid, controller) do
    spawn(fn ->
      monitor_ref = Process.monitor(bridge_pid)

      receive do
        {:DOWN, ^monitor_ref, :process, ^bridge_pid, _reason} ->
          ReadableStreamDefaultController.close(controller)
      end
    end)

    :ok
  end

  defp cancel_bridge(bridge_pid, socket, reason) do
    _ = await_promise(ReadableStream.cancel(socket.readable, reason))

    if Process.alive?(bridge_pid) do
      send(bridge_pid, {:cancel, reason})
    end

    :ok
  end

  defp signal_aborted?(nil), do: false
  defp signal_aborted?(signal), do: Web.AbortSignal.aborted?(signal)

  defp signal_reason(signal), do: Web.AbortSignal.reason(signal) || :aborted

  defp register_controller(bridge_pid, controller) do
    if Process.alive?(bridge_pid) do
      send(bridge_pid, {:register_controller, controller})
    end

    :ok
  end

  defp request_bridge_pull(bridge_pid) do
    Web.Promise.new(fn resolve, _reject ->
      if Process.alive?(bridge_pid) do
        bridge_monitor = Process.monitor(bridge_pid)
        reply_ref = make_ref()
        send(bridge_pid, {:pull, {self(), reply_ref}})

        receive do
          {^reply_ref, :ok} ->
            Process.demonitor(bridge_monitor, [:flush])
            resolve.(:ok)

          {:DOWN, ^bridge_monitor, :process, ^bridge_pid, _reason} ->
            resolve.(:ok)
        end
      else
        resolve.(:ok)
      end
    end)
  end

  defp enqueue_pull_request(state, reply_to) do
    %{state | pending_pulls: :queue.in(reply_to, state.pending_pulls)}
  end

  defp process_pending_pulls(%{controller: nil} = state) do
    bridge_loop(state)
  end

  defp process_pending_pulls(%{pending_pulls: pending_pulls} = state) do
    case :queue.out(pending_pulls) do
      {{:value, reply_to}, rest} ->
        state
        |> Map.put(:pending_pulls, rest)
        |> fulfill_pull(reply_to)

      {:empty, _queue} ->
        bridge_loop(state)
    end
  end

  defp fulfill_pull(%{controller: controller} = state, reply_to) do
    case await_socket_chunk(state.socket_reader) do
      {:chunk, chunk} ->
        ReadableStreamDefaultController.enqueue(controller, chunk)
        reply_pull(reply_to)
        process_pending_pulls(state)

      {:done, reason} ->
        ReadableStreamDefaultController.close(controller)
        reply_pull(reply_to)
        reply_pending_pulls(state.pending_pulls)
        shutdown_bridge(state, reason)
    end
  end

  defp await_socket_chunk(socket_reader) do
    case await_promise(ReadableStreamDefaultReader.read(socket_reader)) do
      {:ok, %{done: false, value: chunk}} ->
        {:chunk, chunk}

      {:ok, %{done: true}} ->
        {:done, :closed}

      {:error, {:readable_cancel, reason}} ->
        {:done, reason}

      {:error, reason} ->
        {:done, reason}
    end
  end

  defp reply_pull({pid, ref}) do
    send(pid, {ref, :ok})
    :ok
  end

  defp reply_pending_pulls(pending_pulls) do
    pending_pulls
    |> :queue.to_list()
    |> Enum.each(&reply_pull/1)
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

      # coveralls-ignore-next-line
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
    _ = await_promise(ReadableStream.cancel(socket.readable, reason))
    send(bridge_pid, {:abort, reason})
    :ok
  end

  defp shutdown_bridge(state, reason) do
    stop_abort_watcher(state.abort_watcher)
    close_socket(state.socket, reason)
    :ok
  end

  defp cancel_controller(nil, _reason), do: :ok

  defp cancel_controller(%ReadableStreamDefaultController{pid: pid}, reason) do
    _ = ReadableStream.cancel(pid, reason)
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

  defp release_reader_lock(%ReadableStreamDefaultReader{controller_pid: pid}) do
    _ = ReadableStream.release_lock(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp await_promise(%Web.Promise{task: task}) do
    {:ok, Task.await(task, :infinity)}
  catch
    :exit, reason -> {:error, normalize_await_exit_reason(reason)}
  end

  defp normalize_await_exit_reason({{:shutdown, reason}, {Task, :await, _details}}), do: reason
  # coveralls-ignore-next-line
  defp normalize_await_exit_reason({:shutdown, reason}), do: reason
  # coveralls-ignore-next-line
  defp normalize_await_exit_reason(reason), do: reason

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

  defp iodata_to_binary(body) do
    if iodata?(body) do
      IO.iodata_to_binary(body)
    else
      raise TypeError, "body is not readable"
    end
  end

  defp iodata?(body) when is_binary(body), do: true
  defp iodata?(body) when is_integer(body), do: body >= 0 and body <= 255
  defp iodata?(body) when is_list(body), do: Enum.all?(body, &iodata?/1)
  defp iodata?(_body), do: false

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
