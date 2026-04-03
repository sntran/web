defmodule Web.BodyTest do
  use ExUnit.Case, async: true

  alias Web.ReadableStream
  alias Web.Request
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
end
