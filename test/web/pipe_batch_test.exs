defmodule Web.PipeBatchTest do
  # A pipe reads the chunks that the source has in one batch, and sends the
  # writes of the batch with no wait between them. These tests put the
  # chunks in the queue of the source before the pipe starts, thus the
  # batches have more than one chunk at a known time.
  use ExUnit.Case, async: true

  import Web, only: [await: 1]

  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController
  alias Web.WritableStream

  # A source with the chunks in its queue, and closed.
  defp queued_source(chunks) do
    source =
      ReadableStream.new(
        %{
          start: fn controller ->
            for chunk <- chunks, do: ReadableStreamDefaultController.enqueue(controller, chunk)
            ReadableStreamDefaultController.close(controller)
          end
        },
        high_water_mark: length(chunks)
      )

    # The start callback runs in the worker of the stream: the test waits
    # until the queue has each chunk.
    eventually(fn -> queued(source) == length(chunks) end)
    source
  end

  defp queued(stream) do
    stream.controller_pid |> ReadableStream.__get_slots__() |> Map.get(:queue) |> :queue.len()
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end

  test "writes each chunk of a batch, in the sequence of the source" do
    test = self()
    source = queued_source(Enum.to_list(1..8))

    destination =
      WritableStream.new(%{
        high_water_mark: 16,
        write: fn chunk, _controller ->
          send(test, {:written, chunk})
          :ok
        end
      })

    assert await(ReadableStream.pipe_to(source, destination)) == :ok

    for chunk <- 1..8, do: assert_received({:written, ^chunk})
  end

  test "rejects with the first failure of a batch" do
    source = queued_source(Enum.to_list(1..8))

    destination =
      WritableStream.new(%{
        high_water_mark: 16,
        write: fn
          3, _controller -> raise "the third write fails"
          _chunk, _controller -> :ok
        end
      })

    assert %RuntimeError{message: "the third write fails"} =
             catch_exit(await(ReadableStream.pipe_to(source, destination)))
  end
end
