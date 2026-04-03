defmodule Web.ResponseTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Response
  alias Web.TypeError

  property "new/1 sets ok true for strictly 2xx status codes matching JS Fetch" do
    check all(status <- integer(200..299)) do
      resp = Response.new(status: status)
      assert resp.status == status
      assert resp.ok == true
    end
  end

  property "new/1 sets ok false for non 2xx status codes generically" do
    check all(status <- one_of([integer(0..199), integer(300..999)])) do
      resp = Response.new(status: status)
      assert resp.status == status
      assert resp.ok == false
    end
  end

  test "new/1 ensures appropriate defaults are assigned dynamically" do
    resp = Response.new()
    assert resp.status == 200
    assert resp.ok == true
    assert resp.type == "default"
    assert match?(%Web.ReadableStream{}, resp.body)
    assert {:ok, ""} = Web.ReadableStream.read_all(resp.body)
    assert resp.url == nil
    assert resp.headers == Web.Headers.new()
  end

  test "new/1 normalizes repeated tuple-list headers into Web.Headers" do
    resp = Response.new(headers: [{"Set-Cookie", "a=1"}, {"set-cookie", "b=2"}])

    assert resp.headers == Web.Headers.new([{"Set-Cookie", "a=1"}, {"set-cookie", "b=2"}])
    assert Web.Headers.get_set_cookie(resp.headers) == ["a=1", "b=2"]
  end

  test "struct defaults include a Web.Headers container" do
    assert %Response{}.headers == Web.Headers.new()
  end

  test "new/1 normalizes enumerable response bodies through ReadableStream.from/1" do
    resp = Response.new(body: ["he", "llo"])

    assert {:ok, "hello"} = Response.text(resp)
  end

  test "text/1 and arrayBuffer/1 drain the response body" do
    resp = Response.new(body: "hello")

    assert {:ok, "hello"} = Response.text(resp)

    resp = Response.new(body: "hello")
    assert {:ok, %Web.ArrayBuffer{data: "hello", byte_length: 5}} = Response.arrayBuffer(resp)

    assert_raise TypeError, "body already used", fn ->
      Response.text(resp)
    end
  end

  test "bytes/1 returns a Uint8Array view over the consumed response body" do
    resp = Response.new(body: "hello")

    assert {:ok, %Web.Uint8Array{byte_length: 5} = bytes} = Response.bytes(resp)
    assert Web.Uint8Array.to_binary(bytes) == "hello"
  end

  test "blob/1 uses content-type header for Blob type" do
    resp = Response.new(body: "hello", headers: [{"content-type", "text/plain"}])

    assert {:ok, %Web.Blob{size: 5, type: "text/plain"}} = Response.blob(resp)
  end

  test "new/1 defaults string bodies to text/plain;charset=UTF-8" do
    resp = Response.new(body: "hello")

    assert Web.Headers.get(resp.headers, "content-type") == "text/plain;charset=UTF-8"
  end

  test "clone/1 returns updated original and clone with independent streams" do
    resp = Response.new(body: "hello")

    assert {:ok, {resp, clone}} = Response.clone(resp)
    assert {:ok, "hello"} = Response.text(resp)
    assert {:ok, "hello"} = Response.text(clone)
  end

  test "json/2 returns JSON body and content-type header" do
    resp = Response.json(%{ok: true})

    assert resp.status == 200
    assert Web.Headers.get(resp.headers, "content-type") == "application/json"
    assert {:ok, %{"ok" => true}} = Response.json(resp)
  end

  test "redirect/2 defaults to 302 and sets location header" do
    resp = Response.redirect("https://example.com")

    assert resp.status == 302
    assert Web.Headers.get(resp.headers, "location") == "https://example.com"
    assert {:ok, ""} = Response.text(resp)
  end

  test "error/0 returns an error response with status 0" do
    resp = Response.error()

    assert resp.status == 0
    assert resp.type == "error"
    assert {:ok, ""} = Response.text(resp)
  end

  test "new/1 infers content-type from Blob body type" do
    blob = Web.Blob.new(["hello"], type: "text/plain")
    resp = Response.new(body: blob)

    assert Web.Headers.get(resp.headers, "content-type") == "text/plain"
    assert {:ok, "hello"} = Response.text(resp)
  end

  test "new/1 does not overwrite an explicit content-type header" do
    resp = Response.new(body: "hello", headers: [{"content-type", "text/custom"}])

    assert Web.Headers.get(resp.headers, "content-type") == "text/custom"
  end

  test "redirect/2 raises for non-redirect statuses" do
    assert_raise TypeError, ~r/Invalid redirect status/, fn ->
      Response.redirect("https://example.com", 200)
    end
  end
end
