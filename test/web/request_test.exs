defmodule Web.RequestTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Request

  property "new/2 defaults methodology handles varied URLs correctly" do
    check all(url <- string(:ascii, min_length: 1)) do
      req = Request.new(url)
      assert req.url == url
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
end
