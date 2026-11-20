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
    {:ok, source_state} = Agent.start_link(fn -> %{pulls: 0, sent: 0} end)

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

      IO.puts("consumer buffer bytes=#{scratch.byte_length}")

      stats =
        drain(reader, scratch, %{
          buffer_length_kept?: true,
          bytes: 0,
          reads: 0
        })

      source_stats = Agent.get(source_state, & &1)

      :ok = ReadableStreamBYOBReader.release_lock(reader)
      :ok = AbortController.abort(controller, :demo_complete)

      IO.puts("completed reads=#{stats.reads} bytes=#{stats.bytes}")
      IO.puts("buffer length kept on every read=#{stats.buffer_length_kept?}")
      IO.puts("source pulls=#{source_stats.pulls}")
    after
      if Process.alive?(source_state) do
        Agent.stop(source_state)
      end
    end
  end

  # The source writes into the view of the BYOB request. At the end, it
  # closes the stream, and responds with 0 bytes: the read that waits gets
  # its buffer back.
  defp pump_socket_chunk(controller, source_state) do
    case ReadableByteStreamController.byob_request(controller) do
      %ReadableStreamBYOBRequest{} = request ->
        view = ReadableStreamBYOBRequest.view(request)

        case next_socket_chunk(source_state, view.byte_length) do
          :done ->
            ReadableByteStreamController.close(controller)
            ReadableStreamBYOBRequest.respond(request, 0)

          {:chunk, chunk, pull_number} ->
            maybe_log_request(view, pull_number, chunk)
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

  defp maybe_log_request(view, pull_number, chunk) when pull_number <= 3 do
    IO.puts("pull=#{pull_number} fill=#{byte_size(chunk)}/#{view.byte_length}")
  end

  defp maybe_log_request(_view, _pull_number, _chunk), do: :ok

  defp drain(reader, scratch, stats) do
    case await_promise(ReadableStreamBYOBReader.read(reader, scratch)) do
      %{done: true} ->
        stats

      %{value: %Uint8Array{} = view, done: false} ->
        read_number = stats.reads + 1

        # A BYOB read moves the buffer into the stream. The buffer that the
        # reader gave is now detached. The result has a buffer of the same
        # length, which the reader uses for the subsequent read.
        buffer_length_kept? =
          stats.buffer_length_kept? and ArrayBuffer.detached?(scratch.buffer) and
            ArrayBuffer.byte_length(view.buffer) == @view_bytes

        if read_number <= 3 or rem(read_number, 16) == 0 do
          IO.puts("read=#{read_number} bytes=#{view.byte_length}")
        end

        drain(reader, Uint8Array.new(view.buffer), %{
          stats
          | reads: read_number,
            bytes: stats.bytes + view.byte_length,
            buffer_length_kept?: buffer_length_kept?
        })
    end
  end

  defp await_promise(%Web.Promise{} = promise), do: Web.Promise.await(promise)
end

SecureByobStreamExample.run()
