defmodule Web.RequestTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Request

  property "new/2 defaults methodology handles varied URLs correctly" do
    check all url <- string(:ascii, min_length: 1) do
      req = Request.new(url)
      assert req.url == url
      assert req.method == "GET"
      assert req.headers == Web.Headers.new()
      assert req.body == nil
      assert req.dispatcher == nil
      assert req.options == []
    end
  end

  test "new/2 applies supplied options reliably" do
    req = Request.new(
      "http://example.com",
      method: :post,
      body: "data",
      headers: %{"x" => "y"},
      dispatcher: MyDispatcher,
      extra_option: true
    )
    
    assert req.method == "POST"
    assert req.body == "data"
    assert req.headers == Web.Headers.new(%{"x" => "y"})
    assert req.dispatcher == MyDispatcher
    assert req.options == [extra_option: true]
  end
end
