defmodule Web.BodyTest do
  use ExUnit.Case, async: true

  alias Web.ReadableStream
  alias Web.Response

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
    assert {:error, %Web.TypeError{message: "body already used"}} = Response.text(response)
  end
end
