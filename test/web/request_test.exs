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
    signal = Web.AbortSignal.abort(:stop)

    req =
      Request.new(
        "http://example.com",
        method: :post,
        body: "data",
        headers: %{"x" => "y"},
        dispatcher: MyDispatcher,
        redirect: :manual,
        signal: signal,
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

    # A key that `RequestInit` does not have changes no field.
    assert req.dispatcher == nil
    assert req.redirect == "manual"
    assert req.signal == signal
    assert req.options[:extra_option] == true
    assert req.options[:redirect] == "manual"
    assert req.options[:signal] == signal
  end

  test "url/1 gives the attribute url: the serialized URL, with its fragment" do
    for input <- ["http://example.com", "HTTPS://[::1]:443/a b?q#frag", "data:,x#y"] do
      request = Request.new(input)

      assert Request.url(request) == Web.URL.href(Web.URL.new(input))
      assert Request.url(Request.new(request, method: "POST")) == Request.url(request)
    end

    assert Request.url(Request.new("http://example.com/a#b")) == "http://example.com/a#b"
  end

  test "new/2 raises TypeError for a signal that is not an AbortSignal or nil" do
    body = Web.ReadableStream.from(["data"])
    input = Request.new("http://example.com", method: "POST", body: body, duplex: "half")

    for signal <- [self(), make_ref(), :token, "signal", 1, %{aborted: false}] do
      assert_raise Web.TypeError, "The value is not an AbortSignal: #{inspect(signal)}", fn ->
        Request.new("http://example.com", signal: signal)
      end

      # The conversion of the init dictionary comes first: the body of the
      # input request does not change.
      assert_raise Web.TypeError, fn -> Request.new(input, signal: signal) end
      refute Web.ReadableStream.disturbed?(input.body)
    end

    # A `nil` signal is a member that is not given: the signal of the input
    # request stays.
    signal = Web.AbortSignal.abort(:stop)
    request = Request.new("http://example.com", signal: signal)
    assert Request.new(request, signal: nil).signal == signal
    assert Request.new("http://example.com", signal: nil).signal == nil
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
        assert_raise TypeError, "Invalid URL: #{inspect(input)}", fn -> Request.new(input) end
      end

      for input <- ["http://exa mple.com/", "http://[::1/", "http://localhost:99999/"] do
        assert_raise TypeError, "Invalid URL: #{inspect(input)}", fn -> Request.new(input) end
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
    test "gives the same request when init is empty and the input has no body" do
      request = Request.new("https://example.com", method: "PUT")
      assert Request.new(request) == request
      assert Request.new(request, []) == request
    end

    test "takes the body of the input, which is then disturbed and locked" do
      for body <- ["x", Web.ReadableStream.from(["x"])] do
        input = Request.new("https://example.com", method: "POST", body: body, duplex: "half")
        request = Request.new(input)

        assert request.body != input.body
        assert Request.body_used?(input)
        assert Web.ReadableStream.locked?(input.body)
        refute Request.body_used?(request)
        assert await(Request.text(request)) == "x"

        assert_raise TypeError, "Request body is already used", fn -> Request.new(input) end
      end
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

    test "replaces the body, and keeps the body of the input for the body nil" do
      first = Request.new("https://example.com", method: "POST", body: "first")

      second = Request.new(first, body: "second")
      assert await(Request.text(second)) == "second"
      assert Web.Headers.get(second.headers, "content-type") =~ "text/plain"
      refute Request.body_used?(first)

      # The Fetch Standard: a body of the input counts for the method GET.
      assert_raise TypeError, ~r/GET\/HEAD method cannot have body/, fn ->
        Request.new(first, method: "GET", body: nil)
      end

      refute Request.body_used?(first)
      assert await(Request.text(Request.new(first, body: nil))) == "first"
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

  describe "the attributes of the Fetch Standard" do
    @enums %{
      mode: ["same-origin", "no-cors", "cors"],
      credentials: ["omit", "same-origin", "include"],
      cache: ["default", "no-store", "reload", "no-cache", "force-cache"],
      referrer_policy: [
        "",
        "no-referrer",
        "no-referrer-when-downgrade",
        "same-origin",
        "origin",
        "strict-origin",
        "origin-when-cross-origin",
        "strict-origin-when-cross-origin",
        "unsafe-url"
      ],
      redirect: ["follow", "error", "manual"]
    }

    test "have the default values of the constructor" do
      request = Request.new("https://example.com/")

      assert %Request{
               destination: "",
               referrer: "about:client",
               referrer_policy: "",
               mode: "cors",
               credentials: "same-origin",
               cache: "default",
               redirect: "follow",
               integrity: "",
               keepalive: false,
               is_reload_navigation: false,
               is_history_navigation: false,
               duplex: "half"
             } = request
    end

    property "take each value of their enumeration, as a string or an atom" do
      check all(
              {key, values} <- member_of(Map.to_list(@enums)),
              value <- member_of(values),
              form <- member_of([:string, :atom])
            ) do
        given = if form == :atom, do: String.to_atom(value), else: value
        request = Request.new("https://example.com/", [{key, given}])
        assert Map.fetch!(request, key) == value

        # A new request with init has the referrer policy "".
        expected = if key == :referrer_policy, do: "", else: value
        assert Request.new(request, method: "POST") |> Map.fetch!(key) == expected
      end
    end

    property "refuse each value that is not in their enumeration" do
      check all(
              key <- member_of([:priority | Map.keys(@enums)]),
              value <- one_of([string(:printable), integer(), constant(true)]),
              value not in Map.get(@enums, key, ["high", "low", "auto"])
            ) do
        assert_raise TypeError, fn -> Request.new("https://example.com/", [{key, value}]) end
      end
    end

    test "take a priority, which is not a field" do
      for priority <- ["high", "low", "auto", :low] do
        request = Request.new("https://example.com/", priority: priority)
        assert request.options[:priority] == priority
        refute Map.has_key?(request, :priority)
      end
    end

    test "take the integrity and the keepalive flag" do
      request = Request.new("https://example.com/", integrity: "sha256-abc", keepalive: true)
      assert {request.integrity, request.keepalive} == {"sha256-abc", true}
      assert Request.new("https://example.com/", keepalive: false).keepalive == false

      assert_raise TypeError, ~r/integrity/, fn ->
        Request.new("https://example.com/", integrity: 1)
      end

      assert_raise TypeError, ~r/keepalive/, fn ->
        Request.new("https://example.com/", keepalive: "yes")
      end
    end

    test "give the referrer as the getter of the Standard" do
      assert Request.new("https://example.com/", referrer: "").referrer == ""

      # The scheme "about" and the path "client": the query has no effect.
      for client <- ["about:client", "ABOUT:client", "about:client?x#y"] do
        assert Request.new("https://example.com/", referrer: client).referrer == "about:client"
      end

      assert Request.new("https://example.com/", referrer: "https://a.example/x y").referrer ==
               "https://a.example/x%20y"

      # The BEAM has no base URL: a relative referrer is not valid.
      for referrer <- ["http://:not a valid URL", "/relative", 1] do
        assert_raise TypeError, ~r/referrer/, fn ->
          Request.new("https://example.com/", referrer: referrer)
        end
      end
    end

    test "go back to the defaults of a new request when init is not empty" do
      input =
        Request.new("https://example.com/",
          referrer: "https://a.example/",
          referrer_policy: "origin",
          mode: "same-origin",
          cache: "no-store"
        )

      assert Request.new(input).referrer == "https://a.example/"

      request = Request.new(input, method: "PUT")
      assert {request.referrer, request.referrer_policy} == {"about:client", ""}
      assert {request.mode, request.cache} == {"same-origin", "no-store"}
    end

    test "refuse a window that is not nil, and the mode navigate" do
      assert %Request{} = Request.new("https://example.com/", window: nil)

      assert_raise TypeError, ~r/window must be nil/, fn ->
        Request.new("https://example.com/", window: "http://test.url")
      end

      assert_raise TypeError, ~r/"navigate" is not valid/, fn ->
        Request.new("https://example.com/", mode: "navigate")
      end
    end

    test "refuse the cache mode only-if-cached with a mode that is not same-origin" do
      for mode <- ["cors", "no-cors"] do
        assert_raise TypeError, ~r/"only-if-cached" permits only/, fn ->
          Request.new("https://example.com/", cache: "only-if-cached", mode: mode)
        end
      end

      assert_raise TypeError, ~r/"only-if-cached" permits only/, fn ->
        Request.new("https://example.com/", cache: "only-if-cached")
      end

      request = Request.new("https://example.com/", cache: "only-if-cached", mode: "same-origin")
      assert request.cache == "only-if-cached"
    end

    test "refuse the mode no-cors with a method that is not CORS-safelisted" do
      for method <- ["GET", "HEAD", "POST", :post] do
        assert %Request{mode: "no-cors"} =
                 Request.new("https://example.com/", mode: "no-cors", method: method)
      end

      # A method is normalized before the check: "post" is "POST".
      assert %Request{method: "POST"} =
               Request.new("https://example.com/", mode: "no-cors", method: "post")

      for method <- ["PUT", "DELETE", "patch", "Custom"] do
        assert_raise TypeError, ~r/"no-cors" permits only/, fn ->
          Request.new("https://example.com/", mode: "no-cors", method: method)
        end
      end

      input = Request.new("https://example.com/", mode: "no-cors")

      assert_raise TypeError, ~r/"no-cors" permits only/, fn ->
        Request.new(input, method: "PUT")
      end
    end

    test "refuse a stream body with keepalive, or with the mode no-cors" do
      assert_raise TypeError, ~r/keepalive cannot have a body that is a stream/, fn ->
        Request.new("https://example.com/",
          method: "POST",
          keepalive: true,
          body: Web.ReadableStream.from(["a"]),
          duplex: "half"
        )
      end

      assert %Request{keepalive: true} =
               Request.new("https://example.com/", method: "POST", keepalive: true, body: "a")

      assert_raise TypeError, ~r/needs the mode "same-origin" or "cors"/, fn ->
        Request.new("https://example.com/",
          method: "POST",
          mode: "no-cors",
          body: Web.ReadableStream.from(["a"]),
          duplex: "half"
        )
      end

      input =
        Request.new("https://example.com/",
          method: "POST",
          body: Web.ReadableStream.from(["a"]),
          duplex: "half"
        )

      assert_raise TypeError, ~r/needs the mode "same-origin" or "cors"/, fn ->
        Request.new(input, mode: "no-cors")
      end

      refute Request.body_used?(input)
    end

    test "refuse a body stream that is disturbed or locked" do
      used = Web.ReadableStream.from(["a", "b"])
      reader = Web.ReadableStream.get_reader(used)
      assert %{value: "a"} = await(Web.ReadableStreamDefaultReader.read(reader))
      :ok = Web.ReadableStreamDefaultReader.release_lock(reader)

      locked = Web.ReadableStream.from(["a"])
      _reader = Web.ReadableStream.get_reader(locked)

      for body <- [used, locked] do
        assert_raise TypeError, ~r/already used or locked/, fn ->
          Request.new("https://example.com/", method: "POST", body: body, duplex: "half")
        end

        assert_raise TypeError, ~r/already used or locked/, fn -> Web.Response.new(body) end
      end
    end
  end

  describe "a new request from a request" do
    property "does not change the input body when the constructor throws" do
      check all(
              init <-
                member_of([
                  [method: "GET"],
                  [method: "HEAD"],
                  [method: "CONNECT"],
                  [mode: "navigate"],
                  [mode: "no-cors", method: "PUT"],
                  [window: "x"],
                  [referrer: "/relative"],
                  [cache: "only-if-cached"],
                  [headers: %{"bad name" => "x"}],
                  [duplex: "full"]
                ]),
              body <- member_of(["text", :stream])
            ) do
        body = if body == :stream, do: Web.ReadableStream.from(["text"]), else: body
        input = Request.new("https://example.com/", method: "POST", body: body, duplex: "half")

        assert_raise TypeError, fn -> Request.new(input, init) end
        refute Request.body_used?(input)
        refute Web.ReadableStream.locked?(input.body)
        assert await(Request.text(Request.new(input))) == "text"
        assert Request.body_used?(input)
      end
    end

    test "takes a body stream with a process through a pipe" do
      body = Web.ReadableStream.from(["a", "b"])
      input = Request.new("https://example.com/", method: "POST", body: body, duplex: "half")
      request = Request.new(input, headers: %{"x" => "1"})

      assert Web.ReadableStream.locked?(body)
      assert Request.body_used?(input)
      assert request.body_source == nil
      assert await(Request.text(request)) == "ab"
    end
  end
end
