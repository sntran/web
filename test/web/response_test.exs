defmodule Web.ResponseTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Response

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
    assert resp.body == nil
    assert resp.url == nil
    assert resp.headers == Web.Headers.new()
  end
end
