defmodule Web.FetchSchemeTest do
  # The steps "scheme fetch" of the Fetch Standard for the schemes that need
  # no network: `about:`, `data:`, and each scheme that the library does not
  # fetch.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1, fetch: 1, fetch: 2]

  alias Web.Dispatcher.Scheme
  alias Web.Headers
  alias Web.Response

  defp body(response), do: to_string(await(Response.bytes(response)))

  defp network_error(promise) do
    assert %Web.TypeError{message: "fetch failed" <> detail} = catch_exit(await(promise))
    detail
  end

  describe "about:" do
    test "about:blank gives an empty HTML response" do
      for input <- ["about:blank", "about:blank#top", "about:blank?query", "ABOUT:blank"] do
        response = await(fetch(input))

        assert {response.status, response.status_text, response.ok} == {200, "OK", true}
        assert Headers.get(response.headers, "content-type") == "text/html;charset=utf-8"
        assert Enum.to_list(Headers.entries(response.headers)) |> length() == 1
        assert response.type == "basic"
        assert response.url == input |> String.downcase() |> String.split("#") |> hd()
        assert body(response) == ""
      end
    end

    test "each other about: URL gives a network error" do
      for input <- ["about:config", "about:BLANK", "about:blank/", "about:"] do
        assert network_error(fetch(input)) == ": the only about: URL is about:blank"
      end
    end
  end

  describe "data:" do
    # Some vectors of `fetch/data-urls/resources/data-urls.json` of WPT. The
    # WPT files `fetch/data-urls/processing.any.js` and `base64.any.js` run
    # all of them.
    @vectors [
      {"data:,X", "text/plain;charset=US-ASCII", "X"},
      {"data:,X#X", "text/plain;charset=US-ASCII", "X"},
      {"data:,%FF", "text/plain;charset=US-ASCII", <<255>>},
      {"data:text/plain,X", "text/plain", "X"},
      {"data:text/plain ,X", "text/plain", "X"},
      {"data:text/plain%20,X", "text/plain%20", "X"},
      {"data:text/plain\f,X", "text/plain%0c", "X"},
      {"data:IMAGE/gif,%C2%B1", "image/gif", <<0xC2, 0xB1>>},
      {"data:;x=x;charset=x,X", "text/plain;x=x;charset=x", "X"},
      {"data:;base64,WA", "text/plain;charset=US-ASCII", "X"},
      {"data:x/x;base64;base64,WA", "x/x", "X"},
      {"data:x/x;base64;charset=x,WA", "x/x;charset=x", "WA"},
      {"data:x/x;base64 ,WA", "x/x", "X"},
      {"data:x/x;  BASE64,WA", "x/x", "X"},
      {"data:x/x;base64=x,WA", "x/x;base64=x", "WA"},
      {"data:x;base64=x,WA", "text/plain;charset=US-ASCII", "WA"},
      {"data:;base64,W%20A", "text/plain;charset=US-ASCII", "X"},
      {"data:;base64,W%0CA", "text/plain;charset=US-ASCII", "X"},
      {"data:text/html;charset=x;charset=y,X", "text/html;charset=x", "X"},
      {"data:x;base64,WA", "text/plain;charset=US-ASCII", "X"},
      {"data:x/x;base64,YQ==", "x/x", "a"},
      {"data:x/x;base64,YR==", "x/x", "a"},
      {"data:x/x;base64,Y Q = =", "x/x", "a"}
    ]

    test "gives the MIME type and the body of the steps data: URL processor" do
      for {input, mime_type, bytes} <- @vectors do
        response = await(fetch(input))

        assert {input, Headers.get(response.headers, "content-type"), body(response)} ==
                 {input, mime_type, bytes}

        assert {response.status, response.status_text, response.type} == {200, "OK", "basic"}
        # The serialized URL, with no fragment.
        assert response.url ==
                 input |> Web.URL.new() |> Web.URL.href() |> String.split("#") |> hd()
      end
    end

    test "a URL with no comma, or a body that is not base64, gives a network error" do
      for input <- [
            "data:",
            "data:text/html",
            "data:;base64,W",
            "data:;base64,W===",
            "data:;base64,WA=A",
            "data:;base64,WA-_",
            "data:;BASE64,=WA"
          ] do
        assert network_error(fetch(input)) == ": the data: URL is not valid"
      end
    end

    property "a body in base64 or in percent-encoding gives its bytes" do
      check all(
              bytes <- binary(max_length: 40),
              type <- member_of(["", "text/plain", "application/octet-stream;x=y"]),
              spaces <- string([?\s], max_length: 2)
            ) do
        expected_type = if type == "", do: "text/plain;charset=US-ASCII", else: type

        response = await(fetch("data:#{type};#{spaces}base64,#{Base.encode64(bytes)}"))
        assert body(response) == bytes
        assert Headers.get(response.headers, "content-type") == expected_type

        encoded = for <<byte <- bytes>>, into: "", do: "%" <> Base.encode16(<<byte>>)
        response = await(fetch("data:#{type}," <> encoded))
        assert body(response) == bytes
      end
    end

    test "the method, the body, and the headers of the request have no effect" do
      response = await(fetch("data:,X", method: "POST", body: "ignored", headers: %{"a" => "b"}))
      assert body(response) == "X"
    end

    test "an aborted signal rejects with its reason" do
      signal = Web.AbortSignal.abort(:stop)

      assert catch_exit(await(fetch("data:,X", signal: signal))) == :stop
      assert catch_exit(await(fetch("about:blank", signal: signal))) == :stop
    end
  end

  test "file: and each other scheme that the library does not fetch give a network error" do
    for {input, scheme} <- [
          {"file:///etc/hosts", "file:"},
          {"ftp://example.com/file", "ftp:"},
          {"ws://example.com/", "ws:"},
          {"foo://example.com/", "foo:"},
          {"mailto:a@example.com", "mailto:"}
        ] do
      assert network_error(fetch(input)) ==
               ": the library cannot fetch a URL with the scheme #{inspect(scheme)}"

      # The cause of the `TypeError` is the failure of the dispatcher.
      assert %Web.TypeError{cause: {:scheme_not_supported, ^scheme}} =
               catch_exit(await(fetch(input)))
    end
  end

  test "the dispatcher of the steps scheme fetch gives a result for a request" do
    request = Web.Request.new("data:,X")
    assert {:ok, %Response{status: 200}} = Scheme.fetch(request)

    request = Web.Request.new("file:///etc/hosts")
    assert {:error, {:scheme_not_supported, "file:"}} = Scheme.fetch(request)
  end
end
