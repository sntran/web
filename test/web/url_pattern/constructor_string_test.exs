defmodule Web.URLPattern.ConstructorStringTest do
  use ExUnit.Case, async: true

  alias Web.URLPattern.ConstructorString

  defp parse(input), do: ConstructorString.parse(input)

  test "gives the components of a full pattern string" do
    assert parse("https://user\\:pw@example.com:8080/foo?bar#baz") == %{
             protocol: "https",
             username: "user",
             password: "pw",
             hostname: "example.com",
             port: "8080",
             pathname: "/foo",
             search: "bar",
             hash: "baz"
           }
  end

  test "gives the components of the examples of the Standard" do
    assert parse("https://example.com/:category/*") == %{
             protocol: "https",
             hostname: "example.com",
             port: "",
             pathname: "/:category/*"
           }

    assert parse("http{s}?://{:subdomain.}?shop.example/products/:id([0-9]+)#reviews") == %{
             protocol: "http{s}?",
             hostname: "{:subdomain.}?shop.example",
             port: "",
             pathname: "/products/:id([0-9]+)",
             search: "",
             hash: "reviews"
           }
  end

  test "gives an empty pathname and search before a later component" do
    assert parse("https://example.com#foo") == %{
             protocol: "https",
             hostname: "example.com",
             port: "",
             pathname: "/",
             search: "",
             hash: "foo"
           }

    assert parse("foo://example.com?q") == %{
             protocol: "foo",
             hostname: "example.com",
             port: "",
             pathname: "",
             search: "q"
           }
  end

  test "reads a special scheme with no authority slashes as an authority" do
    assert %{hostname: "example.com", pathname: "/a"} = parse("https\\:example.com/a")

    assert parse("data\\:foo") == %{protocol: "data", hostname: "", port: "", pathname: "foo"}
    assert parse("data:") == %{protocol: "data", hostname: "", port: "", pathname: ""}
  end

  test "reads a protocol at the end of the string" do
    assert parse("https:") == %{protocol: "https", hostname: "", port: ""}
    assert parse("foo:") == %{protocol: "foo", hostname: "", port: "", pathname: ""}
  end

  test "reads a name after a colon as a group, not as a separator" do
    assert parse("data:foo") == %{pathname: "data:foo"}
  end

  test "gives a relative pattern string" do
    assert parse("../admin/*") == %{pathname: "../admin/*"}
    assert parse("#frag") == %{hash: "frag"}
    assert parse("?q=1") == %{search: "q=1"}
    assert parse("") == %{pathname: ""}
  end

  test "ignores the separators in a group and in a name" do
    assert parse("https://{sub.}?example{.com/}foo") == %{
             protocol: "https",
             hostname: "{sub.}?example{.com/}foo",
             port: ""
           }

    assert %{hostname: "a.c:hmm.example.com", port: "8080"} =
             parse("https://a.c:hmm.example.com:8080")
  end

  test "reads an IPv6 hostname in brackets" do
    assert %{hostname: "[\\:\\:1]", port: "8080"} = parse("http://[\\:\\:1]:8080/")
  end

  test "reads a ? after a group as a modifier, and else as a search prefix" do
    assert %{pathname: "/:id?"} = parse("https://example.com/:id?")
    assert %{pathname: "/a", search: "b"} = parse("https://example.com/a?b")
    assert parse("?") == %{search: ""}
  end

  test "reads a username with no password" do
    assert %{username: "user", hostname: "example.com"} = parse("https://user@example.com")

    # ":pw" is a named group: the username ends at "@".
    assert %{username: "user:pw"} = parse("https://user:pw@example.com")
  end

  test "raises TypeError for a protocol that is not valid" do
    assert_raise Web.TypeError, fn -> parse("(café)://foo") end
  end
end
