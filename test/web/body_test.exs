defmodule Web.BodyTest do
  use ExUnit.Case, async: true
  import Web, only: [await: 1]

  alias Web.ReadableStream
  alias Web.Request
  alias Web.Response

  test "ReadableStream.from/1 normalizes strings and arbitrary binaries" do
    assert "hello" == "hello" |> ReadableStream.from() |> Enum.join("")

    assert <<0, 255, 1>> == <<0, 255, 1>> |> ReadableStream.from() |> Enum.join("")
  end

  test "ReadableStream.from/1 returns an existing stream as-is" do
    stream = ReadableStream.new()
    assert ReadableStream.from(stream) == stream
  end

  test "ReadableStream.from/1 normalizes nil into an empty stream" do
    assert "" == nil |> ReadableStream.from() |> Enum.join("")
  end

  test "Response.text/1 marks the body as disturbed and rejects a second read" do
    response = Response.new(body: "hello")

    assert ReadableStream.disturbed?(response.body) == false
    assert "hello" = await(Response.text(response))
    assert ReadableStream.disturbed?(response.body) == true

    assert %Web.TypeError{message: "body already used"} =
             catch_exit(await(Response.text(response)))
  end

  test "Response.clone/1 tees the body and both branches can be consumed" do
    response = Response.new(body: "hello")

    assert {response, clone} = Response.clone(response)
    assert "hello" = await(Response.text(response))

    assert ReadableStream.disturbed?(response.body) == true
    assert ReadableStream.disturbed?(clone.body) == false

    assert "hello" = await(Response.text(clone))
  end

  test "request clone disturbance is isolated between original and clone" do
    request = Request.new("https://example.com", body: "hello")

    assert {request, clone} = Request.clone(request)
    assert "hello" = await(Request.text(request))

    assert ReadableStream.disturbed?(request.body) == true
    assert ReadableStream.disturbed?(clone.body) == false

    assert "hello" = await(Request.text(clone))
    assert ReadableStream.disturbed?(clone.body) == true
  end

  test "clone of disturbed body raises TypeError" do
    response = Response.new(body: "hello")
    await(Response.text(response))

    assert_raise Web.TypeError, "body already used", fn ->
      Response.clone(response)
    end
  end

  test "clone of locked stream raises TypeError" do
    stream = ReadableStream.from("hello")
    _reader = ReadableStream.get_reader(stream)
    response = Response.new(body: stream)

    assert_raise Web.TypeError, "ReadableStream is already locked", fn ->
      Response.clone(response)
    end
  end

  test "Web.Body.blob/1 uses empty type when headers are missing" do
    input = %{body: ReadableStream.from("hello")}

    assert %Web.Blob{size: 5, type: ""} = await(Web.Body.blob(input))
  end

  test "Response.text/1 reads iolist body" do
    # read_body_to_binary/1 list branch (source line 172)
    response = Response.new(body: ["hel", "lo"])
    assert "hello" == await(Response.text(response))
  end

  test "Response.text/1 rejects when body read fails via mapper {:error, reason}" do
    # consume_body reject path: mapper returns {:error, reason} (source line 160)
    # json/1 returns {:error, reason} when JSON parsing fails
    response = Response.new(body: "invalid json {{")
    assert %Jason.DecodeError{} = catch_exit(await(Response.json(response)))
  end

  test "Response.text/1 rejects when stream is already locked" do
    # read_body_to_binary already_locked branch (source line 177)
    stream = ReadableStream.from("hello")
    _reader = ReadableStream.get_reader(stream)
    response = Response.new(body: stream)

    assert %Web.TypeError{} = catch_exit(await(Response.text(response)))
  end

  test "Response.text/1 rejects when stream errors during read" do
    # read_stream_chunks error branch: when stream is errored, read() returns {:error, reason}
    {:ok, pid} = ReadableStream.start_link()
    stream = %ReadableStream{controller_pid: pid}
    # Error the stream so read() returns {:error, {:errored, :stream_fail}}
    ReadableStream.error(pid, :stream_fail)
    response = Response.new(body: stream)
    result = catch_exit(await(Response.text(response)))
    assert result == {:errored, :stream_fail}
  end

  test "Response.text/1 returns empty string for nil body" do
    # read_body_to_binary(nil) returns {:ok, ""} — covers body.ex line 169
    response = %Response{Response.new() | body: nil}
    assert "" = await(Response.text(response))
  end

  test "Response.text/1 returns binary body directly" do
    # read_body_to_binary(binary) branch — covers body.ex line 170
    response = %Response{Response.new() | body: "direct binary"}
    assert "direct binary" = await(Response.text(response))
  end

  test "Response.text/1 returns iolist body as binary" do
    # read_body_to_binary(list) branch — covers body.ex line 171
    response = %Response{Response.new() | body: ["io", "list"]}
    assert "iolist" = await(Response.text(response))
  end
end
