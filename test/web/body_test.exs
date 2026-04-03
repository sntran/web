defmodule Web.BodyTest do
  use ExUnit.Case, async: true

  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController
  alias Web.Request
  alias Web.Response
  alias Web.WritableStream

  test "ReadableStream.from/1 normalizes strings and arbitrary binaries" do
    assert {:ok, "hello"} = "hello" |> ReadableStream.from() |> ReadableStream.read_all()

    assert {:ok, <<0, 255, 1>>} =
             <<0, 255, 1>> |> ReadableStream.from() |> ReadableStream.read_all()
  end

  test "ReadableStream.from/1 returns an existing stream as-is" do
    stream = ReadableStream.new()
    assert ReadableStream.from(stream) == stream
  end

  test "ReadableStream.from/1 normalizes nil into an empty stream" do
    assert {:ok, ""} = nil |> ReadableStream.from() |> ReadableStream.read_all()
  end

  test "Response.text/1 marks the body as disturbed and rejects a second read" do
    response = Response.new(body: "hello")

    assert ReadableStream.disturbed?(response.body) == false
    assert {:ok, "hello"} = Response.text(response)
    assert ReadableStream.disturbed?(response.body) == true

    assert_raise Web.TypeError, "body already used", fn ->
      Response.text(response)
    end
  end

  test "Response.clone/1 tees the body and both branches can be consumed" do
    response = Response.new(body: "hello")

    assert {:ok, {response, clone}} = Response.clone(response)
    assert {:ok, "hello"} = Response.text(response)
    assert {:ok, "hello"} = Response.text(clone)
  end

  test "clone disturbance is isolated between original and clone" do
    response = Response.new(body: "hello")

    assert {:ok, {response, clone}} = Response.clone(response)
    assert {:ok, "hello"} = Response.text(response)

    assert ReadableStream.disturbed?(response.body) == true
    assert ReadableStream.disturbed?(clone.body) == false

    assert {:ok, "hello"} = Response.text(clone)
  end

  test "request clone disturbance is isolated between original and clone" do
    request = Request.new("https://example.com", body: "hello")

    assert {:ok, {request, clone}} = Request.clone(request)
    assert {:ok, "hello"} = Request.text(request)

    assert ReadableStream.disturbed?(request.body) == true
    assert ReadableStream.disturbed?(clone.body) == false

    assert {:ok, "hello"} = Request.text(clone)
    assert ReadableStream.disturbed?(clone.body) == true
  end

  test "Response.clone/1 returns error when stream is locked" do
    stream = ReadableStream.from("hello")
    _reader = ReadableStream.get_reader(stream)
    response = Response.new(body: stream)

    assert {:error, %Web.TypeError{message: "ReadableStream is already locked"}} =
             Response.clone(response)
  end

  test "Web.Body.blob/1 uses empty type when headers are missing" do
    input = %{body: ReadableStream.from("hello")}

    assert {:ok, %Web.Blob{size: 5, type: ""}} = Web.Body.blob(input)
  end

  test "Web.Body.pipe_to/2 streams an enumerable into a WritableStream and closes it" do
    parent = self()

    writable =
      WritableStream.new(%{
        write: fn chunk, _controller ->
          send(parent, {:chunk, chunk})
          :ok
        end,
        close: fn _controller ->
          send(parent, :sink_closed)
          :ok
        end
      })

    assert :ok = Web.Body.pipe_to(Stream.map(["a", "b", "c"], & &1), writable)

    assert_receive {:chunk, "a"}
    assert_receive {:chunk, "b"}
    assert_receive {:chunk, "c"}
    assert_receive :sink_closed
    assert WritableStream.get_slots(writable.controller_pid).state == :closed
    assert WritableStream.locked?(writable) == false
  end

  test "Web.Body.pipe_to/2 aborts re-raises and cancels the source when piping fails" do
    parent = self()

    source_pid =
      spawn(fn ->
        receive do
          {:pull, stream_pid} ->
            controller = %ReadableStreamDefaultController{pid: stream_pid}
            ReadableStreamDefaultController.enqueue(controller, "boom")
            ReadableStreamDefaultController.close(controller)
            source_loop(parent)
        end
      end)

    source = ReadableStream.new(source_pid)

    writable =
      WritableStream.new(%{
        write: fn _chunk, _controller ->
          raise "sink write failed"
        end
      })

    assert_raise Web.TypeError, "The stream is errored.", fn ->
      Web.Body.pipe_to(source, writable)
    end

    assert_receive {:source_cancelled, _reason}, 200
    assert_wait(fn -> not Process.alive?(source_pid) end)
    assert_wait(fn -> WritableStream.get_slots(writable.controller_pid).state == :errored end)
    assert WritableStream.locked?(writable) == false
  end

  defp source_loop(parent) do
    receive do
      {:web_stream_cancel, _stream_pid, reason} ->
        send(parent, {:source_cancelled, reason})
        :ok
    end
  end

  defp assert_wait(fun, attempts \\ 20)

  defp assert_wait(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(25)
      assert_wait(fun, attempts - 1)
    end
  end

  defp assert_wait(_fun, 0) do
    flunk("condition was not met in time")
  end
end
