defmodule AsyncRuntimePowerExample do
  @moduledoc """
  Demonstrates invisible async context propagation across multipart parsing,
  file streaming, compression tasks, logger metadata, console grouping, and
  ambient abort signals.

  Usage:
    mix run examples/async_runtime_power.exs
  """

  use Web

  alias Web.AsyncContext
  alias Web.File

  def run do
    user = AsyncContext.Variable.new("user")
    controller = AbortController.new()
    boundary = "runtime-power-boundary"
    request_id = "req-" <> Integer.to_string(System.unique_integer([:positive]))

    AsyncContext.Variable.run(user, "ada", fn ->
      :logger.update_process_metadata(%{
        request_id: request_id,
        user: AsyncContext.Variable.get(user),
        web_runtime_observe: true
      })

      Console.group("Secure Compressed Proxy")

      try do
        form = FormData.parse(upload_stream(boundary), boundary, signal: controller.signal)
        parent = self()
        snapshot = AsyncContext.Snapshot.take()

        proxy_task =
          Task.async(fn ->
            AsyncContext.Snapshot.run(snapshot, fn ->
              try do
                Enum.each(form, fn
                  ["meta", value] ->
                    Console.info("metadata field received: #{value}")

                  [_name, %File{} = file] ->
                    compression = CompressionStream.new("gzip")
                    send(parent, {:compression_pid, compression.readable.controller_pid})

                    file
                    |> File.stream()
                    |> ReadableStream.pipe_through(compression)
                    |> Enum.each(fn chunk ->
                      send(parent, {:compressed_chunk, byte_size(chunk)})
                      Process.sleep(10)
                    end)
                end)

                :ok
              rescue
                error in Web.TypeError ->
                  {:aborted, error.message}
              catch
                :exit, reason ->
                  {:exit, reason}
              end
            end)
          end)

        compression_pid =
          receive do
            {:compression_pid, pid} -> pid
          after
            1_000 -> raise "timed out waiting for compression stream startup"
          end

        receive do
          {:compressed_chunk, bytes} ->
            Console.debug("compressed chunk observed: #{bytes}B")
        after
          1_000 ->
            raise "timed out waiting for the first compressed chunk"
        end

        Console.warn("Triggering abort controller kill switch")
        :ok = AbortController.abort(controller, :operator_shutdown)

        result =
          case Task.yield(proxy_task, 2_000) || Task.shutdown(proxy_task, :brutal_kill) do
            {:ok, value} -> value
            nil -> :timed_out
          end

        wait_until(
          fn ->
            if Process.alive?(compression_pid) do
              ReadableStream.__get_slots__(compression_pid).state in [:closed, :errored]
            else
              true
            end
          end,
          500
        )

        compression_state =
          if Process.alive?(compression_pid) do
            ReadableStream.__get_slots__(compression_pid).state
          else
            :terminated
          end

        Console.info("proxy task result: #{inspect(result)}")
        Console.info("form coordinator alive?: #{inspect(Process.alive?(form.coordinator))}")
        Console.info("compression terminal state: #{inspect(compression_state)}")

        receive_drain()
      after
        Console.group_end()
        :logger.set_process_metadata(%{})
      end
    end)
  end

  defp upload_stream(boundary) do
    payload =
      multipart_payload(boundary, [
        %{name: "meta", value: "confidential"},
        %{
          name: "upload",
          filename: "secret.txt",
          content_type: "text/plain",
          value: String.duplicate("classified-", 2_000)
        }
      ])

    chunks = chunk_binary(payload, 256)
    {:ok, cursor} = Agent.start_link(fn -> chunks end)

    ReadableStream.new(%{
      pull: fn controller ->
        Process.sleep(15)

        Agent.get_and_update(cursor, fn
          [chunk | rest] ->
            {chunk, rest}

          [] ->
            {:done, []}
        end)
        |> case do
          :done ->
            ReadableStreamDefaultController.close(controller)

          chunk ->
            ReadableStreamDefaultController.enqueue(controller, chunk)
        end
      end,
      cancel: fn reason ->
        Console.warn("upload source cancelled: #{inspect(reason)}")
        if Process.alive?(cursor), do: Agent.stop(cursor, :normal)
      end
    })
  end

  defp multipart_payload(boundary, parts) do
    Enum.map_join(parts, "", fn part ->
      disposition = ~s(Content-Disposition: form-data; name="#{part.name}")

      disposition =
        case Map.get(part, :filename) do
          nil -> disposition
          filename -> disposition <> ~s(; filename="#{filename}")
        end

      headers = [disposition]

      headers =
        case Map.get(part, :content_type) do
          nil -> headers
          type -> headers ++ ["Content-Type: #{type}"]
        end

      [
        "--#{boundary}\r\n",
        Enum.join(headers, "\r\n"),
        "\r\n\r\n",
        part.value,
        "\r\n"
      ]
      |> IO.iodata_to_binary()
    end) <> "--#{boundary}--\r\n"
  end

  defp chunk_binary(binary, size) do
    do_chunk_binary(binary, size, [])
  end

  defp do_chunk_binary(<<>>, _size, acc), do: Enum.reverse(acc)

  defp do_chunk_binary(binary, size, acc) do
    take = min(size, byte_size(binary))
    <<chunk::binary-size(take), rest::binary>> = binary
    do_chunk_binary(rest, size, [chunk | acc])
  end

  defp receive_drain do
    receive do
      {:compressed_chunk, bytes} ->
        Console.debug("compressed chunk observed: #{bytes}B")
        receive_drain()
    after
      100 ->
        :ok
    end
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(10)
        do_wait_until(fun, deadline)
    end
  end
end

AsyncRuntimePowerExample.run()
