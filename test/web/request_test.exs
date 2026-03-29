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
      assert req.body == nil
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
    assert req.body == "data"
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
end
