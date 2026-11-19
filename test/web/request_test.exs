defmodule Web.RequestTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Web, only: [await: 1]

  alias Web.Request
  alias Web.TypeError

  property "new/1 gives a request with the default values, or raises TypeError" do
    check all(
            url <-
              one_of([
                string(:ascii, min_length: 1),
                map(string(:alphanumeric, min_length: 1), &("http://" <> &1 <> "/"))
              ])
          ) do
      try do
        Request.new(url)
      rescue
        error in TypeError ->
          assert error.message =~ "URL"
      else
        req ->
          assert match?(%Web.URL{}, req.url)
          assert req.url.username == "" and req.url.password == ""
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
    assert "data" = await(Web.Request.text(req))

    assert req.headers ==
             Web.Headers.new(%{
               "x" => "y",
               "content-type" => "text/plain;charset=UTF-8"
             })

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

  test "new/2 normalizes enumerable request bodies through ReadableStream.from/1" do
    req = Request.new("http://example.com", method: "POST", body: ["he", "llo"])

    assert "hello" = await(Web.Request.text(req))
  end

  test "text/json/array_buffer consume the request body once" do
    request = Request.new("https://example.com", method: "POST", body: ~s({"hello":"world"}))

    assert %{"hello" => "world"} = await(Request.json(request))

    assert %TypeError{message: "body already used"} =
             catch_exit(await(Request.text(request)))
  end

  test "array_buffer/1 returns Web.ArrayBuffer" do
    req = Request.new("https://example.com", method: "POST", body: "hello")
    assert %Web.ArrayBuffer{data: "hello", byte_length: 5} = await(Request.array_buffer(req))
  end

  test "bytes/1 and blob/1 return expected Web types" do
    req =
      Request.new("https://example.com",
        method: "POST",
        body: "hello",
        headers: [{"content-type", "text/plain"}]
      )

    assert %Web.Uint8Array{} = bytes = await(Request.bytes(req))
    assert Web.Uint8Array.to_binary(bytes) == "hello"

    req =
      Request.new("https://example.com",
        method: "POST",
        body: "hello",
        headers: [{"content-type", "text/plain"}]
      )

    assert %Web.Blob{size: 5, type: "text/plain"} = await(Request.blob(req))
  end

  test "new/2 infers content-type for URLSearchParams bodies" do
    params = Web.URLSearchParams.new(%{"hello" => "world"})
    req = Request.new("https://example.com", method: "POST", body: params)

    assert Web.Headers.get(req.headers, "content-type") ==
             "application/x-www-form-urlencoded;charset=UTF-8"

    assert "hello=world" = await(Request.text(req))
  end

  test "new/2 does not overwrite an explicit content-type header" do
    req =
      Request.new("https://example.com",
        method: "POST",
        body: Web.URLSearchParams.new(%{"hello" => "world"}),
        headers: [{"content-type", "text/custom"}]
      )

    assert Web.Headers.get(req.headers, "content-type") == "text/custom"
  end

  test "new/2 raises when input is not a request, a URL struct, or a string" do
    assert_raise TypeError, ~r/Request input must be a Web.Request struct/, fn ->
      Request.new(123, [])
    end

    assert_raise TypeError, ~r/Request init must be a keyword list/, fn ->
      Request.new("https://example.com", %{method: "POST"})
    end
  end

  describe "the checks of the Request constructor" do
    test "refuse a URL that is not valid" do
      for input <- ["", " ", "not a url", "/relative-only", "?query", "example.com/path"] do
        assert_raise TypeError, ~r/Invalid URL/, fn -> Request.new(input) end
      end

      for input <- ["http://exa mple.com/", "http://[::1/", "http://localhost:99999/"] do
        assert_raise TypeError, ~r/Invalid URL/, fn -> Request.new(input) end
      end
    end

    test "refuse a URL that includes credentials, and do not show them" do
      for input <- ["https://user:secret@example.com/", "https://user@example.com/"] do
        error = assert_raise TypeError, ~r/includes credentials/, fn -> Request.new(input) end
        refute error.message =~ "secret"
        refute error.message =~ "user@"
      end

      assert_raise TypeError, ~r/includes credentials/, fn ->
        Request.new(Web.URL.new("https://user:secret@example.com/"))
      end
    end

    test "refuse a method that is not a token" do
      for method <- ["", "BAD METHOD", "GET\r\n", "GE(T", 1] do
        assert_raise TypeError, ~r/is not a valid HTTP method/, fn ->
          Request.new("https://example.com", method: method)
        end
      end
    end

    test "refuse the forbidden methods, in each case" do
      for method <- ["CONNECT", "trace", "Track", :connect] do
        assert_raise TypeError, ~r/HTTP method is unsupported/, fn ->
          Request.new("https://example.com", method: method)
        end
      end
    end

    test "change only the six standard methods to uppercase" do
      for method <- ~w(delete get head options post put) do
        assert Request.new("https://example.com", method: method).method ==
                 String.upcase(method)
      end

      # The Fetch Standard does not change these methods.
      assert Request.new("https://example.com", method: "patch").method == "patch"
      assert Request.new("https://example.com", method: "PATCH").method == "PATCH"
      assert Request.new("https://example.com", method: "Custom").method == "Custom"
    end

    test "change a method that is an atom to uppercase" do
      assert Request.new("https://example.com", method: :patch).method == "PATCH"
      assert Request.new("https://example.com", method: :post).method == "POST"
    end

    test "refuse a body with the methods GET and HEAD" do
      for method <- ["GET", "get", "HEAD", :head] do
        assert_raise TypeError, ~r/GET\/HEAD method cannot have body/, fn ->
          Request.new("https://example.com", method: method, body: "x")
        end
      end

      assert_raise TypeError, ~r/GET\/HEAD method cannot have body/, fn ->
        Request.new("https://example.com", body: "x")
      end

      assert Request.new("https://example.com", method: "GET", body: nil).body == nil
    end

    test "refuse a header name or a header value that is not valid" do
      for headers <- [%{"bad name" => "x"}, [{"", "x"}], [{"a:b", "x"}], [{"é", "x"}]] do
        assert_raise TypeError, ~r/Invalid header name/, fn ->
          Request.new("https://example.com", headers: headers)
        end
      end

      for value <- ["a\r\nb: c", "a\nb", <<"a", 0, "b">>] do
        assert_raise TypeError, ~r/Invalid header value/, fn ->
          Request.new("https://example.com", headers: [{"x-test", value}])
        end
      end
    end

    test "refuse a body that is a stream with no option duplex" do
      for make_body <- [
            fn -> Web.ReadableStream.from(["a"]) end,
            fn -> Stream.map(["a"], & &1) end
          ] do
        assert_raise TypeError, ~r/duplex: "half"` is necessary/, fn ->
          Request.new("https://example.com", method: "POST", body: make_body.())
        end

        for duplex <- ["half", :half] do
          assert %Request{body_source: nil} =
                   Request.new("https://example.com",
                     method: "POST",
                     body: make_body.(),
                     duplex: duplex
                   )
        end
      end

      first = Request.new("https://example.com", method: "POST", body: "x")

      assert_raise TypeError, ~r/duplex: "half"` is necessary/, fn ->
        Request.new(first, body: Web.ReadableStream.from(["a"]))
      end
    end

    test "do not require the option duplex for a body that has a source" do
      for body <- [
            "text",
            ["io", "data"],
            Web.URLSearchParams.new(%{"a" => "1"}),
            Web.Blob.new(["blob"]),
            Web.ArrayBuffer.new("buffer"),
            Web.Uint8Array.new(Web.ArrayBuffer.new("view")),
            Web.FormData.new()
          ] do
        assert %Request{} = Request.new("https://example.com", method: "POST", body: body)
      end

      # A request that has a stream body can be the input with no option.
      first =
        Request.new("https://example.com",
          method: "POST",
          body: Web.ReadableStream.from(["a"]),
          duplex: "half"
        )

      assert %Request{method: "PUT"} = Request.new(first, method: "PUT")
    end

    test "refuse a redirect mode or a duplex mode that is not valid" do
      assert_raise TypeError, ~r/is not a valid redirect mode/, fn ->
        Request.new("https://example.com", redirect: "sometimes")
      end

      assert_raise TypeError, ~r/is not a valid redirect mode/, fn ->
        Request.new("https://example.com", redirect: 1)
      end

      assert_raise TypeError, ~r/is not a valid duplex mode/, fn ->
        Request.new("https://example.com", method: "POST", body: "x", duplex: "full")
      end

      assert %Request{} =
               Request.new("https://example.com", method: "POST", body: "x", duplex: "half")
    end
  end

  describe "new/2 with a request as its input" do
    test "gives the same request when init is empty" do
      request = Request.new("https://example.com", method: "POST", body: "x")
      assert Request.new(request) == request
      assert Request.new(request, []) == request
    end

    test "replaces the values that init has, and keeps the others" do
      controller = Web.AbortController.new()

      first =
        Request.new("https://example.com/a",
          method: "POST",
          headers: %{"x-one" => "1"},
          body: "first",
          redirect: "manual"
        )

      second =
        Request.new(first,
          method: "put",
          headers: %{"x-two" => "2"},
          signal: controller.signal
        )

      assert second.url == first.url
      assert second.method == "PUT"
      assert Web.Headers.get(second.headers, "x-two") == "2"
      refute Web.Headers.has(second.headers, "x-one")
      assert second.redirect == "manual"
      assert second.signal == controller.signal
      assert second.options[:signal] == controller.signal
      assert await(Request.text(second)) == "first"
    end

    test "replaces the body, and can remove it" do
      first = Request.new("https://example.com", method: "POST", body: "first")

      second = Request.new(first, body: "second")
      assert await(Request.text(second)) == "second"
      assert Web.Headers.get(second.headers, "content-type") =~ "text/plain"

      third = Request.new(first, method: "GET", body: nil)
      assert third.body == nil
      assert third.method == "GET"
    end

    test "applies the checks to the result" do
      first = Request.new("https://example.com", method: "POST", body: "first")

      assert_raise TypeError, ~r/GET\/HEAD method cannot have body/, fn ->
        Request.new(first, method: "GET")
      end

      assert_raise TypeError, ~r/is not a valid HTTP method/, fn ->
        Request.new(first, method: "BAD METHOD")
      end

      assert_raise TypeError, ~r/Invalid header name/, fn ->
        Request.new(first, headers: %{"bad name" => "x"})
      end
    end
  end
end
