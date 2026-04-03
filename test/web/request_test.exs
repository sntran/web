defmodule Web.RequestTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Request

  property "new/2 defaults methodology handles varied URLs correctly" do
    check all(url <- string(:ascii, min_length: 1)) do
      req = Request.new(url)
      assert match?(%Web.URL{}, req.url)
      assert req.method == "GET"
      assert req.headers == Web.Headers.new()
      assert match?(%Web.ReadableStream{}, req.body)
      assert {:ok, ""} = Web.ReadableStream.read_all(req.body)
      assert req.dispatcher == nil
      assert req.redirect == "follow"
      assert req.signal == nil
      assert req.options[:redirect] == "follow"
      assert req.options[:signal] == nil
    end
  end

  test "new/2 applies supplied options reliably" do
    req =
      Request.new(
        "http://example.com",
        method: :post,
        body: "data",
        headers: %{"x" => "y"},
        dispatcher: MyDispatcher,
        redirect: :manual,
        signal: self(),
        extra_option: true
      )

    assert Web.URL.href(req.url) == "http://example.com/"
    assert req.method == "POST"
    assert {:ok, "data"} = Web.Request.text(req)
    assert req.headers == Web.Headers.new(%{"x" => "y"})
    assert req.dispatcher == MyDispatcher
    assert req.redirect == "manual"
    assert req.signal == self()
    assert req.options[:extra_option] == true
    assert req.options[:redirect] == "manual"
    assert req.options[:signal] == self()
  end

  test "new/2 normalizes tuple-list headers into Web.Headers" do
    req = Request.new("http://example.com", headers: [{"X-Test", "1"}, {"x-test", "2"}])

    assert req.headers == Web.Headers.new([{"X-Test", "1"}, {"x-test", "2"}])
    assert Web.Headers.get(req.headers, "x-test") == "1, 2"
  end

  test "struct defaults include a Web.Headers container" do
    assert %Request{}.headers == Web.Headers.new()
  end

  test "new/2 accepts an existing Web.URL struct" do
    url = Web.URL.new("https://example.com/path")
    req = Request.new(url, method: :put)

    assert req.url == url
    assert req.method == "PUT"
  end

  test "new/2 normalizes enumerable request bodies through ReadableStream.from/1" do
    req = Request.new("http://example.com", body: ["he", "llo"])

    assert {:ok, "hello"} = Web.Request.text(req)
  end

  test "text/json/arrayBuffer consume the request body once" do
    request = Request.new("https://example.com", body: ~s({"hello":"world"}))

    assert {:ok, %{"hello" => "world"}} = Request.json(request)
    assert {:error, %Web.TypeError{message: "body already used"}} = Request.text(request)
  end

  test "arrayBuffer/1 returns Web.ArrayBuffer" do
    req = Request.new("https://example.com", body: "hello")
    assert {:ok, %Web.ArrayBuffer{data: "hello", byte_length: 5}} = Request.arrayBuffer(req)
  end

  test "bytes/1 and blob/1 return expected Web types" do
    req =
      Request.new("https://example.com",
        body: "hello",
        headers: [{"content-type", "text/plain"}]
      )

    assert {:ok, %Web.Uint8Array{} = bytes} = Request.bytes(req)
    assert Web.Uint8Array.to_binary(bytes) == "hello"

    req =
      Request.new("https://example.com",
        body: "hello",
        headers: [{"content-type", "text/plain"}]
      )

    assert {:ok, %Web.Blob{size: 5, type: "text/plain"}} = Request.blob(req)
  end
end
