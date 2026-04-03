defmodule Web.URLTest do
  use ExUnit.Case, async: true

  alias Web.URL
  alias Web.URLSearchParams

  test "parses and mutates a standard URL" do
    url = URL.new("https://google.com/search?q=elixir#top")

    assert URL.href(url) == "https://google.com/search?q=elixir#top"
    assert URL.protocol(url) == "https:"
    assert URL.host(url) == "google.com"
    assert URL.hostname(url) == "google.com"
    assert URL.port(url) == ""
    assert URL.pathname(url) == "/search"
    assert URL.search(url) == "?q=elixir"
    assert URL.hash(url) == "#top"
    assert URL.origin(url) == "https://google.com"

    url =
      url
      |> URL.set_port(443)
      |> URL.hash("docs")

    assert URL.host(url) == "google.com:443"
    assert URL.hash(url) == "#docs"
    assert URL.href(url) == "https://google.com:443/search?q=elixir#docs"
  end

  test "supports setters, string conversion, and reusing an existing url struct" do
    url = URL.new("remote:path")

    assert URL.new(url) == url

    url =
      url
      |> URL.set_protocol("tcp")
      |> URL.host("localhost:8080")
      |> URL.set_hostname("127.0.0.1")
      |> URL.set_port(nil)
      |> URL.set_port("9000")
      |> URL.set_pathname("stream")
      |> URL.search("a=1")
      |> URL.hash("#tail")

    assert URL.protocol(url) == "tcp:"
    assert URL.host(url) == "127.0.0.1:9000"
    assert URL.pathname(url) == "/stream"
    assert URL.search(url) == "?a=1"
    assert URL.hash(url) == "#tail"
    assert Kernel.to_string(url) == "tcp://127.0.0.1:9000/stream?a=1#tail"

    url = URL.href(url, "https://example.org/next")
    assert URL.href(url) == "https://example.org/next"
  end

  test "covers hostless and empty setter edge cases" do
    relative = URL.new("folder/file")
    blank = URL.new("")
    root = URL.new("https://example.com")
    remote = URL.new("remote:path")

    assert URL.host(relative) == ""
    assert URL.href(relative) == "/folder/file"
    assert URL.href(blank) == ""

    relative =
      relative
      |> URL.set_protocol("")
      |> URL.host("example.net")
      |> URL.set_port("")
      |> URL.set_pathname("")
      |> URL.hash("")
      |> URL.href("remote:bucket/item")

    root = URL.set_pathname(root, "")
    remote = URL.set_pathname(remote, "next")
    blank = URL.set_protocol(blank, "custom")

    assert URL.href(root) == "https://example.com/"
    assert URL.href(blank) == "custom:"
    assert URL.pathname(remote) == "next"
    assert URL.href(relative) == "remote:bucket/item"
  end

  test "serializes inspect output cleanly" do
    url = URL.new("https://example.com/path")
    assert inspect(url) == ~s(#Web.URL<"https://example.com/path">)
  end

  test "search params are plain structs that can be placed back onto the url" do
    url = URL.new("https://example.com/path?foo=bar")

    params =
      url
      |> URL.search_params()
      |> URLSearchParams.append("foo", "baz")
      |> URLSearchParams.set("space", "hello world")

    url = %{url | search_params: params}

    assert URL.search(url) == "?foo=bar&foo=baz&space=hello+world"
    assert URL.href(url) == "https://example.com/path?foo=bar&foo=baz&space=hello+world"

    url = URL.search(url, "?reset=1")
    assert URLSearchParams.to_list(URL.search_params(url)) == [{"reset", "1"}]
  end

  test "parses rclone style urls as protocol plus pathname" do
    url = URL.new("my_s3:bucket/file.txt?x=1#frag")

    assert URL.rclone?(url)
    assert URL.protocol(url) == "my_s3:"
    assert URL.pathname(url) == "bucket/file.txt"
    assert URL.search(url) == "?x=1"
    assert URL.hash(url) == "#frag"
    assert URL.origin(url) == "null"
    assert URL.href(url) == "my_s3:bucket/file.txt?x=1#frag"
  end

  test "resolves relative urls against a base" do
    url = URL.new("/docs?q=1", "https://example.com/base")

    assert URL.href(url) == "https://example.com/docs?q=1"
  end

  test "supports base urls passed as Web.URL structs and null origins for hostless urls" do
    base = URL.new("https://example.com/root")
    url = URL.new("child", base)
    hostless = URL.new("folder/file")

    assert URL.href(url) == "https://example.com/child"
    assert URL.origin(hostless) == "null"
  end

  test "getter and setter overloads work for href host search and hash" do
    url = URL.new("https://example.com/path")

    assert URL.href(url) == "https://example.com/path"

    url =
      url
      |> URL.host("example.org:8080")
      |> URL.search("?q=1")
      |> URL.hash("frag")

    assert URL.host(url) == "example.org:8080"
    assert URL.search(url) == "?q=1"
    assert URL.hash(url) == "#frag"
  end

  test "href/1 adds a trailing slash for host urls with an empty pathname" do
    url = %URL{protocol: "https:", hostname: "example.com", pathname: "", kind: :standard}

    assert URL.href(url) == "https://example.com/"
  end
end
