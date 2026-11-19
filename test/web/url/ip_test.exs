defmodule Web.URL.IPTest do
  use ExUnit.Case, async: true

  alias Web.URL.IP

  test "ip helpers cover invalid bracketed and non-ipv6 colon hosts" do
    assert IP.split_host_and_port("[::1") == {"[::1", ""}
    assert IP.split_host_and_port("[bad]:80") == {"[bad]:80", ""}

    refute IP.valid_host?("[bad]", "http:")
    assert IP.valid_host?(".", "file:")
    assert IP.valid_host?("..", "file:")
    assert IP.normalize_host(".", "file:") == ""
    assert IP.normalize_host("..", "file:") == ""
    assert IP.normalize_host("AB:CD:ZZ", "custom:") == "ab:cd:zz"
    assert IP.normalize_host("9999999999999", "http:") == "9999999999999"
  end
end
