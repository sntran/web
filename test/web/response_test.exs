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

  test "new/1 normalizes repeated tuple-list headers into Web.Headers" do
    resp = Response.new(headers: [{"Set-Cookie", "a=1"}, {"set-cookie", "b=2"}])

    assert resp.headers == Web.Headers.new([{"Set-Cookie", "a=1"}, {"set-cookie", "b=2"}])
    assert Web.Headers.get_set_cookie(resp.headers) == ["a=1", "b=2"]
  end

  test "struct defaults include a Web.Headers container" do
    assert %Response{}.headers == Web.Headers.new()
  end
end
