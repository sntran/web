use Web

boundary = "proxy-boundary-1gb"
chunk_size = 1_048_576
chunk_count = 1024
payload_bytes = chunk_size * chunk_count

multipart_prefix =
  "--#{boundary}\r\n" <>
    "Content-Disposition: form-data; name=\"destination\"\r\n\r\n" <>
    "archive\r\n" <>
    "--#{boundary}\r\n" <>
    "Content-Disposition: form-data; name=\"payload\"; filename=\"payload.bin\"\r\n" <>
    "Content-Type: application/octet-stream\r\n\r\n"

multipart_suffix = "\r\n--#{boundary}--\r\n"

{:ok, source_state} =
  Agent.start_link(fn ->
    %{phase: :prefix, emitted: 0}
  end)

source =
  ReadableStream.new(%{
    pull: fn controller ->
      event =
        Agent.get_and_update(source_state, fn state ->
          case state do
            %{phase: :prefix} ->
              {{:chunk, multipart_prefix}, %{state | phase: :file}}

            %{phase: :file, emitted: emitted} when emitted < chunk_count ->
              {{:chunk, :binary.copy(<<97>>, chunk_size)}, %{state | emitted: emitted + 1}}

            %{phase: :file} ->
              {{:chunk, multipart_suffix}, %{state | phase: :done}}

            %{phase: :done} ->
              {:close, state}
          end
        end)

      case event do
        {:chunk, chunk} -> ReadableStreamDefaultController.enqueue(controller, chunk)
        :close -> ReadableStreamDefaultController.close(controller)
      end
    end,
    cancel: fn _reason ->
      :ok
    end
  })

IO.puts("[mem] start bytes=#{:erlang.memory(:total)}")

response =
  Response.new(
    body: source,
    headers: %{"content-type" => "multipart/form-data; boundary=#{boundary}"}
  )

form_data = await(Response.form_data(response))

route =
  Enum.find(form_data, fn
    ["destination", _] -> true
    _ -> false
  end)

IO.puts("route=#{inspect(route)}")

%Web.File{} = payload = Web.FormData.get(form_data, "payload")
payload_stream = Web.File.stream(payload)

{:ok, sink_state} =
  Agent.start_link(fn ->
    %{bytes: 0, checkpoint: 128 * 1_048_576}
  end)

sink =
  WritableStream.new(%{
    write: fn chunk, _controller ->
      size = byte_size(IO.iodata_to_binary(chunk))

      Agent.get_and_update(sink_state, fn %{bytes: bytes, checkpoint: checkpoint} = state ->
        next = bytes + size

        if next >= checkpoint do
          IO.puts("[mem] bytes=#{next} total=#{:erlang.memory(:total)}")
          {:ok, %{state | bytes: next, checkpoint: checkpoint + 128 * 1_048_576}}
        else
          {:ok, %{state | bytes: next}}
        end
      end)

      :ok
    end
  })

await(ReadableStream.pipe_to(payload_stream, sink))

total_written = Agent.get(sink_state, & &1.bytes)
IO.puts("payload_bytes=#{payload_bytes} written_bytes=#{total_written}")
IO.puts("[mem] end bytes=#{:erlang.memory(:total)}")

Web.FormData.cancel(form_data, :normal)
await(ReadableStream.cancel(source, :done))
await(WritableStream.abort(sink, :done))

Enum.each([source.controller_pid, sink.controller_pid], fn pid ->
  if Process.alive?(pid) do
    Process.unlink(pid)
    Process.exit(pid, :shutdown)
  end
end)

Process.sleep(50)

cleanup_pids = [
  {"source", source.controller_pid},
  {"coordinator", form_data.coordinator},
  {"payload_stream", payload_stream.controller_pid},
  {"sink", sink.controller_pid}
]

Enum.each(cleanup_pids, fn {name, pid} ->
  IO.puts("cleanup #{name}=#{inspect(pid)} alive?=#{Process.alive?(pid)}")
end)

Agent.stop(source_state)
Agent.stop(sink_state)
