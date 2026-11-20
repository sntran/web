defmodule Web.URLPattern.InitTest do
  use ExUnit.Case, async: true

  alias Web.URL
  alias Web.URLPattern.Init

  @base "https://user:pw@example.com:8080/a/b?q=*#h"

  defp pattern(init), do: Init.process(init, :pattern, %{})
  defp url(init), do: Init.process(init, :url, %{})

  describe "normalize/1" do
    test "gives atom keys, and drops the keys with nil and the unknown keys" do
      assert Init.normalize(%{"pathname" => "/a", "baseURL" => "x", search: nil, other: "y"}) ==
               %{pathname: "/a", base_url: "x"}

      assert Init.normalize(%{baseURL: "x", hash: "h"}) == %{base_url: "x", hash: "h"}
      assert Init.normalize(%{"base_url" => "x", 1 => "y"}) == %{base_url: "x"}
    end

    test "raises TypeError for a value that is not a string" do
      assert_raise Web.TypeError, fn -> Init.normalize(%{port: 80}) end
    end
  end

  describe "process/3 with a base URL" do
    test "gives each component of the base URL that is less specific than the init" do
      assert pattern(%{base_url: @base}) == %{
               protocol: "https",
               hostname: "example.com",
               port: "8080",
               pathname: "/a/b",
               search: "q=\\*",
               hash: "h"
             }

      assert pattern(%{search: "z", base_url: @base}) == %{
               protocol: "https",
               hostname: "example.com",
               port: "8080",
               pathname: "/a/b",
               search: "z"
             }

      assert pattern(%{hostname: "x", base_url: @base}) == %{protocol: "https", hostname: "x"}
      assert pattern(%{protocol: "http", base_url: @base}) == %{protocol: "http"}
    end

    test "gives the username and the password only to a URL" do
      assert %{username: "user", password: "pw", search: "q=*"} = url(%{base_url: @base})
      assert %{username: "user", password: "p"} = url(%{password: "p", base_url: @base})
      assert %{username: "u"} = url = url(%{username: "u", base_url: @base})
      refute Map.has_key?(url, :password)
      refute Map.has_key?(pattern(%{base_url: @base}), :username)
    end

    test "makes a relative pathname relative to the directory of the base URL" do
      assert pattern(%{pathname: "c", base_url: @base}).pathname == "/a/c"
      assert pattern(%{pathname: "/c", base_url: @base}).pathname == "/c"
      assert pattern(%{pathname: "{/c}", base_url: @base}).pathname == "{/c}"
      assert pattern(%{pathname: "\\/c", base_url: @base}).pathname == "\\/c"
      assert url(%{pathname: "{/c}", base_url: @base}).pathname == "/a/%7B/c%7D"
      assert pattern(%{pathname: "c", base_url: "data:foo"}).pathname == "c"
      assert pattern(%{pathname: "c", base_url: "foo://host"}).pathname == "c"
    end

    test "raises TypeError for a base URL that is not valid" do
      assert_raise Web.TypeError, fn -> pattern(%{base_url: ""}) end
      assert_raise Web.TypeError, fn -> pattern(%{base_url: "/relative"}) end
    end
  end

  describe "process/3 for a URL" do
    test "canonicalizes each component" do
      assert url(%{
               protocol: "HTTP:",
               username: "a b",
               password: "c:d",
               hostname: "EXAMPLE.com",
               port: "80",
               pathname: "/x/../y z",
               search: "?q r",
               hash: "#h i"
             }) == %{
               protocol: "http",
               username: "a%20b",
               password: "c%3Ad",
               hostname: "example.com",
               port: "",
               pathname: "/y%20z",
               search: "q%20r",
               hash: "h%20i"
             }
    end

    test "uses the opaque path of a scheme that is not special" do
      assert url(%{protocol: "data", pathname: "a b?c"}).pathname == "a b"
      assert url(%{pathname: "a b"}).pathname == "a%20b"
    end
  end

  test "process/3 for a pattern keeps the text, and removes the separators" do
    assert pattern(%{protocol: "http:", search: "?a", hash: "#b", pathname: "/a b"}) == %{
             protocol: "http",
             search: "a",
             hash: "b",
             pathname: "/a b"
           }
  end

  test "opaque_path?/1 tells if a URL has an opaque path" do
    assert Init.opaque_path?(URL.new("data:foo"))
    assert Init.opaque_path?(URL.new("foo:"))
    refute Init.opaque_path?(URL.new("foo:/bar"))
    refute Init.opaque_path?(URL.new("foo://host"))
    refute Init.opaque_path?(URL.new("https://example.com"))
  end
end
