defmodule Web.URLPattern.CanonicalTest do
  use ExUnit.Case, async: true

  alias Web.URLPattern.Canonical

  defp results(fun, cases) do
    for {value, _expected} <- cases do
      try do
        fun.(value)
      rescue
        Web.TypeError -> :error
      end
    end
  end

  defp assert_cases(fun, cases), do: assert(results(fun, cases) == Enum.map(cases, &elem(&1, 1)))

  test "protocol/1 gives the scheme of a URL with the value" do
    assert_cases(&Canonical.protocol/1, [
      {"", ""},
      {"HTTP", "http"},
      {"a+b.c-d", "a+b.c-d"},
      {"file", "file"},
      {"café", :error},
      {"1a", :error},
      {"a b", :error}
    ])
  end

  test "userinfo/1 uses the userinfo percent-encode set" do
    assert_cases(&Canonical.userinfo/1, [
      {"", ""},
      {"caf%C3%A9", "caf%C3%A9"},
      {"us er:@é/", "us%20er%3A%40%C3%A9%2F"},
      {"!$&'()*+,-._~", "!$&'()*+,-._~"}
    ])
  end

  test "hostname/1 uses the hostname state of a special URL" do
    assert_cases(&Canonical.hostname/1, [
      {"", ""},
      {"EXAMPLE.com", "example.com"},
      {"café.com", "xn--caf-dma.com"},
      {"a\tb", "ab"},
      {"foo/bar", "foo"},
      {"foo?bar", "foo"},
      {"foo#bar", "foo"},
      {"bad\\hostname", "bad"},
      {"bad%41b", "badab"},
      {"0x7f.1", "127.0.0.1"},
      {"[::1]", "[::1]"},
      {"[0:0::1]", "[::1]"},
      {"foo:1", :error},
      {"[::1]:80", :error},
      {"/x", :error},
      {"bad hostname", :error},
      {"bad%hostname", :error},
      {"bad@hostname", :error},
      {"[::1", :error}
    ])
  end

  test "ipv6_hostname/1 accepts only the characters of an IPv6 address" do
    assert_cases(&Canonical.ipv6_hostname/1, [
      {"[::AB]", "[::ab]"},
      {"[::x]", :error},
      {"[::é]", :error}
    ])
  end

  test "port/2 uses the port state, and removes the default port of the scheme" do
    assert_cases(&Canonical.port/1, [
      {"", ""},
      {"80", "80"},
      {"0080", "80"},
      {"80a", "80"},
      {"1\t2", "12"},
      {"65535", "65535"},
      {"a", :error},
      {" 1", :error},
      {"65536", :error}
    ])

    assert Canonical.port("80", "http") == ""
    assert Canonical.port("443", "http") == "443"
    assert Canonical.port("21", "ftp") == ""
    assert Canonical.port("80", "file") == "80"
  end

  test "pathname/1 uses the path state of a special URL" do
    assert_cases(&Canonical.pathname/1, [
      {"", ""},
      {"/foo/../bar", "/bar"},
      {"/foo/./bar", "/foo/bar"},
      {"/%2e%2E/x", "/x"},
      {"/x/.", "/x/"},
      {"/x/..", "/"},
      {"/a\\b", "/a/b"},
      {"//a", "//a"},
      {"./bar", "./bar"},
      {"..", ".."},
      {"foo", "foo"},
      {"foo bar?#^{}`\"<>", "foo%20bar%3F%23%5E%7B%7D%60%22%3C%3E"},
      {"é\t", "%C3%A9"}
    ])
  end

  test "opaque_pathname/1 uses the opaque path state" do
    assert_cases(&Canonical.opaque_pathname/1, [
      {"", ""},
      {"x y", "x y"},
      {"a b ?c", "a b%20"},
      {"a b #c", "a b%20"},
      {"a#c", "a"},
      {"?x", ""},
      {"é\u0001\u007F", "%C3%A9%01%7F"},
      {"a\nb", "ab"}
    ])
  end

  test "search/1 and hash/1 use the query state and the fragment state" do
    assert Canonical.search("a b#'é<>\"") == "a%20b%23%27%C3%A9%3C%3E%22"
    assert Canonical.search("a\tb%41") == "ab%41"
    assert Canonical.hash("a b`#é<>\"") == "a%20b%60#%C3%A9%3C%3E%22"
    assert Canonical.hash("a\nb") == "ab"
  end

  test "special_scheme?/1 and default_port/1 have the special schemes" do
    for scheme <- ~w(ftp file http https ws wss), do: assert(Canonical.special_scheme?(scheme))
    refute Canonical.special_scheme?("data")
    assert Canonical.default_port("wss") == 443
    assert Canonical.default_port("file") == nil
  end
end
