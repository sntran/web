defmodule SecureByobStreamExample do
  @moduledoc false

  alias Web.AbortController
  alias Web.ArrayBuffer
  alias Web.ReadableByteStreamController
  alias Web.ReadableStream
  alias Web.ReadableStreamBYOBReader
  alias Web.ReadableStreamBYOBRequest
  alias Web.Uint8Array

  @socket_chunk_bytes 262_144
  @socket_chunk_count 16
  @view_bytes 65_536

  def run do
    {:ok, source_state} =
      Agent.start_link(fn ->
        %{capability_sample: [], pulls: 0, sent: 0}
      end)

    controller = AbortController.new()

    try do
      stream =
        ReadableStream.new(%{
          type: "bytes",
          pull: fn controller_ref ->
            pump_socket_chunk(controller_ref, source_state)
          end,
          cancel: fn reason ->
            IO.puts("source cancelled: #{inspect(reason)}")
          end
        })

      reader = ReadableStream.get_reader(stream, mode: "byob")
      scratch = Uint8Array.new(ArrayBuffer.new(@view_bytes))
      buffer_id = ArrayBuffer.identity(scratch.buffer)

      IO.puts("consumer buffer=#{inspect(buffer_id)} bytes=#{scratch.byte_length}")

      stats =
        drain(reader, scratch, %{
          buffer_id: buffer_id,
          buffer_reused?: true,
          bytes: 0,
          reads: 0
        })

      source_stats = Agent.get(source_state, & &1)

      :ok = ReadableStreamBYOBReader.release_lock(reader)
      :ok = AbortController.abort(controller, :demo_complete)

      IO.puts("completed reads=#{stats.reads} bytes=#{stats.bytes}")
      IO.puts("buffer reused on every read=#{stats.buffer_reused?}")

      IO.puts(
        "sample capabilities=#{Enum.map_join(source_stats.capability_sample, ", ", &inspect/1)}"
      )
    after
      if Process.alive?(source_state) do
        Agent.stop(source_state)
      end
    end
  end

  defp pump_socket_chunk(controller, source_state) do
    case ReadableByteStreamController.byob_request(controller) do
      %ReadableStreamBYOBRequest{} = request ->
        remember_capability(source_state, request.address)

        case next_socket_chunk(source_state, request.view_byte_length) do
          :done ->
            ReadableByteStreamController.close(controller)

          {:chunk, chunk, pull_number} ->
            maybe_log_capability(request, pull_number, chunk)
            ReadableStreamBYOBRequest.respond(request, chunk)
        end

      nil ->
        :ok
    end
  end

  defp next_socket_chunk(source_state, max_bytes) do
    Agent.get_and_update(source_state, fn %{pulls: pulls, sent: sent} = state ->
      total_bytes = @socket_chunk_bytes * @socket_chunk_count

      if sent >= total_bytes do
        {:done, state}
      else
        packet_index = div(sent, @socket_chunk_bytes)
        packet_remaining = @socket_chunk_bytes - rem(sent, @socket_chunk_bytes)
        take = min(max_bytes, packet_remaining)
        chunk = :binary.copy(<<rem(packet_index, 251)>>, take)

        {{:chunk, chunk, pulls + 1}, %{state | pulls: pulls + 1, sent: sent + take}}
      end
    end)
  end

  defp remember_capability(source_state, address) do
    Agent.update(source_state, fn %{capability_sample: capability_sample} = state ->
      next_sample =
        cond do
          address in capability_sample -> capability_sample
          length(capability_sample) >= 3 -> capability_sample
          true -> capability_sample ++ [address]
        end

      %{state | capability_sample: next_sample}
    end)
  end

  defp maybe_log_capability(request, pull_number, chunk) when pull_number <= 3 do
    IO.puts(
      "pull=#{pull_number} capability=#{inspect(request.address)} fill=#{byte_size(chunk)}/#{request.view_byte_length}"
    )
  end

  defp maybe_log_capability(_request, _pull_number, _chunk), do: :ok

  defp drain(reader, scratch, stats) do
    case await_promise(ReadableStreamBYOBReader.read(reader, scratch)) do
      %{done: true} ->
        stats

      %{value: %Uint8Array{} = view, done: false} ->
        read_number = stats.reads + 1

        buffer_reused? =
          stats.buffer_reused? and ArrayBuffer.identity(view.buffer) == stats.buffer_id

        if read_number <= 3 or rem(read_number, 16) == 0 do
          IO.puts(
            "read=#{read_number} bytes=#{view.byte_length} consumer_buffer=#{inspect(ArrayBuffer.identity(view.buffer))}"
          )
        end

        drain(reader, scratch, %{
          stats
          | reads: read_number,
            bytes: stats.bytes + view.byte_length,
            buffer_reused?: buffer_reused?
        })
    end
  end

  defp await_promise(%Web.Promise{task: task}) do
    Task.await(task, :infinity)
  catch
    :exit, {{:shutdown, reason}, {Task, :await, _details}} -> exit(reason)
    :exit, reason -> exit(reason)
  end
end

SecureByobStreamExample.run()
