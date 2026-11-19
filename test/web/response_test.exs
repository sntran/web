defmodule Web.ResponseTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Web, only: [await: 1]

  alias Web.Response
  alias Web.TypeError

  # ============================================================================
  # Standard Response Tests (Preserved - testing core API functionality)
  # ============================================================================

  test "struct defaults include a Web.Headers container" do
    assert %Response{}.headers == Web.Headers.new()
  end

  test "new/1 normalizes enumerable response bodies through ReadableStream.from/1" do
    resp = Response.new(body: ["he", "llo"])

    assert "hello" = await(Response.text(resp))
  end

  test "text/1 and array_buffer/1 drain the response body" do
    resp = Response.new(body: "hello")

    assert "hello" = await(Response.text(resp))

    resp = Response.new(body: "hello")
    assert %Web.ArrayBuffer{data: "hello", byte_length: 5} = await(Response.array_buffer(resp))

    assert %TypeError{message: "body already used"} =
             catch_exit(await(Response.text(resp)))
  end

  test "bytes/1 returns a Uint8Array view over the consumed response body" do
    resp = Response.new(body: "hello")

    assert %Web.Uint8Array{byte_length: 5} = bytes = await(Response.bytes(resp))
    assert Web.Uint8Array.to_binary(bytes) == "hello"
  end

  test "blob/1 uses content-type header for Blob type" do
    resp = Response.new(body: "hello", headers: [{"content-type", "text/plain"}])

    assert %Web.Blob{size: 5, type: "text/plain"} = await(Response.blob(resp))
  end

  test "new/1 defaults string bodies to text/plain;charset=UTF-8" do
    resp = Response.new(body: "hello")

    assert Web.Headers.get(resp.headers, "content-type") == "text/plain;charset=UTF-8"
  end

  test "clone/1 returns updated original and clone with independent streams" do
    resp = Response.new(body: "hello")

    assert {resp, clone} = Response.clone(resp)
    assert "hello" = await(Response.text(resp))
    assert "hello" = await(Response.text(clone))
  end

  test "json/2 returns JSON body and content-type header" do
    resp = Response.json(%{ok: true})

    assert resp.status == 200
    assert Web.Headers.get(resp.headers, "content-type") == "application/json"
    assert %{"ok" => true} = await(Response.json(resp))
  end

  test "redirect/2 defaults to 302 and sets location header" do
    resp = Response.redirect("https://example.com")

    assert resp.status == 302
    assert Web.Headers.get(resp.headers, "location") == "https://example.com/"
    assert resp.body == nil
    assert "" = await(Response.text(resp))
  end

  test "error/0 returns an error response with status 0" do
    resp = Response.error()

    assert resp.status == 0
    assert resp.ok == false
    assert resp.status_text == ""
    assert resp.type == "error"
    assert "" = await(Response.text(resp))
  end

  test "new/1 defaults status_text to empty string" do
    resp = Response.new(status: 599)
    assert resp.status_text == ""
  end

  test "new/1 allows explicitly setting status_text" do
    resp = Response.new(status: 250, status_text: "Custom")
    assert resp.status_text == "Custom"
  end

  test "json/2 creates an ok response with an empty status_text" do
    resp = Response.json(%{id: 1})
    assert resp.ok == true
    assert resp.status_text == ""
  end

  test "redirect/2 accepts each redirect status, with an empty status_text" do
    for status <- [301, 302, 303, 307, 308] do
      resp = Response.redirect("https://example.com", status)
      assert {resp.status, resp.status_text, resp.ok} == {status, "", false}
    end
  end

  test "error/0 creates a non-ok response" do
    assert Response.error().ok == false
  end

  test "new/1 infers content-type from Blob body type" do
    blob = Web.Blob.new(["hello"], type: "text/plain")
    resp = Response.new(body: blob)

    assert Web.Headers.get(resp.headers, "content-type") == "text/plain"
    assert "hello" = await(Response.text(resp))
  end

  test "new/1 does not overwrite an explicit content-type header" do
    resp = Response.new(body: "hello", headers: [{"content-type", "text/custom"}])

    assert Web.Headers.get(resp.headers, "content-type") == "text/custom"
  end

  describe "the checks of the Response constructor" do
    test "give the default values of the Fetch Standard" do
      resp = Response.new()

      assert {resp.status, resp.status_text, resp.ok, resp.url, resp.type, resp.redirected} ==
               {200, "", true, "", "default", false}

      assert resp.body == nil
      assert Enum.to_list(resp.headers) == []
      assert Response.new([]) == %{resp | snapshot: Response.new([]).snapshot}
    end

    test "accept each status from 200 to 599, and refuse each other status" do
      for status <- [200, 201, 299, 300, 404, 500, 599] do
        assert Response.new(status: status).status == status
      end

      for status <- [-1, 0, 100, 199, 600, 999, 1000] do
        assert_raise Web.RangeError, ~r/from 200 to 599/, fn -> Response.new(status: status) end
      end

      for status <- ["200", 200.0, nil, :ok] do
        assert_raise TypeError, ~r/status must be an integer/, fn ->
          Response.new(status: status)
        end
      end
    end

    property "give ok only for a status from 200 to 299" do
      check all(status <- integer(200..599)) do
        assert Response.new(status: status).ok == status < 300
      end
    end

    test "refuse a status text that is not a reason phrase" do
      for text <- ["a\r\nb", "a\nb", <<"a", 0, "b">>, "a\x7Fb", :ok, 200] do
        assert_raise TypeError, ~r/Invalid status text/, fn ->
          Response.new(status_text: text)
        end
      end

      for text <- ["", "OK", "Not Found", "tab\there", "é"] do
        assert Response.new(status_text: text).status_text == text
      end
    end

    test "refuse a body with a status that permits no body, and start no stream" do
      for status <- [204, 205, 304] do
        assert_raise TypeError, ~r/null body status cannot have body/, fn ->
          Response.new("body", status: status)
        end

        assert_raise TypeError, ~r/null body status cannot have body/, fn ->
          Response.new(body: "", status: status)
        end

        assert Response.new(status: status).body == nil
        assert Response.new(nil, status: status).body == nil
      end
    end

    test "refuse a header that is not valid, and init that is not a keyword list" do
      assert_raise TypeError, ~r/Invalid header name/, fn ->
        Response.new("x", headers: %{"bad name" => "1"})
      end

      assert_raise TypeError, ~r/Invalid header value/, fn ->
        Response.new("x", headers: [{"x-test", "a\r\nb"}])
      end

      assert_raise TypeError, ~r/init must be a keyword list/, fn -> Response.new(%{}) end
      assert_raise TypeError, ~r/init must be a keyword list/, fn -> Response.new("x", %{}) end
    end

    test "give the header content-type of the body, if init has none" do
      for {body, type} <- [
            {"text", "text/plain;charset=UTF-8"},
            {Web.URLSearchParams.new("a=1"), "application/x-www-form-urlencoded;charset=UTF-8"},
            {Web.Blob.new(["x"], type: "image/png"), "image/png"}
          ] do
        assert Web.Headers.get(Response.new(body, []).headers, "content-type") == type
      end

      # A stream, and a Blob with no type, give no header.
      refute Web.Headers.has(
               Response.new(Web.ReadableStream.from(["x"]), []).headers,
               "content-type"
             )

      refute Web.Headers.has(Response.new(Web.Blob.new(["x"]), []).headers, "content-type")
    end
  end

  describe "json/2" do
    test "keeps a content-type that init has" do
      resp = Response.json(%{a: 1}, headers: %{"content-type" => "application/problem+json"})
      assert Web.Headers.get(resp.headers, "content-type") == "application/problem+json"
    end

    test "applies the checks of the constructor" do
      assert Response.json(%{a: 1}, status: 201, status_text: "Created").status == 201

      assert_raise TypeError, ~r/null body status cannot have body/, fn ->
        Response.json(%{a: 1}, status: 204)
      end

      assert_raise Web.RangeError, fn -> Response.json(%{a: 1}, status: 600) end
    end

    test "raises TypeError for a value that cannot be changed to JSON" do
      error =
        assert_raise TypeError, ~r/cannot be changed to JSON/, fn -> Response.json(self()) end

      assert is_exception(error.cause)
    end

    property "gives a body that json/1 reads back" do
      value =
        tree(one_of([integer(), boolean(), string(:printable), constant(nil)]), fn child ->
          one_of([
            list_of(child, max_length: 4),
            map_of(string(:alphanumeric), child, max_length: 4)
          ])
        end)

      check all(data <- value, max_runs: 50) do
        assert await(Response.json(Response.json(data))) == data
      end
    end
  end

  describe "redirect/2" do
    test "gives the serialized URL in the header location, and no body" do
      resp = Response.redirect("https://example.com/a b?q=é")

      assert Web.Headers.get(resp.headers, "location") == "https://example.com/a%20b?q=%C3%A9"
      assert resp.body == nil
      assert Response.redirect(Web.URL.new("https://example.com/x")).status == 302
    end

    test "raises RangeError for a status that is not a redirect status" do
      for status <- [200, 300, 304, 305, 306, 309, 400, "302"] do
        assert_raise Web.RangeError, ~r/Invalid redirect status/, fn ->
          Response.redirect("https://example.com", status)
        end
      end
    end

    test "raises TypeError for a URL that is not valid, before it examines the status" do
      for url <- ["", "/relative", "http://exa mple.com/", 123] do
        assert_raise TypeError, ~r/Invalid URL/, fn -> Response.redirect(url, 200) end
      end
    end
  end

  describe "the body of a response" do
    test "tells if it is used" do
      resp = Response.new("hello", [])
      refute Response.body_used?(resp)
      assert await(Response.text(resp)) == "hello"
      assert Response.body_used?(resp)

      # A response with no body is never used.
      empty = Response.new()
      assert await(Response.text(empty)) == ""
      refute Response.body_used?(empty)
      assert await(Response.text(empty)) == ""
    end

    test "that is nil gives the empty value of each function" do
      assert await(Response.text(Response.new())) == ""
      assert await(Response.array_buffer(Response.new())).byte_length == 0
      assert await(Response.bytes(Response.new())).byte_length == 0
      assert %Web.Blob{size: 0, type: ""} = await(Response.blob(Response.new()))
      assert %Web.SyntaxError{} = catch_exit(await(Response.json(Response.new())))
    end

    test "that is nil can be cloned" do
      resp = Response.new(status: 204)
      assert {first, second} = Response.clone(resp)
      assert first.body == nil and second.body == nil
    end

    test "rejects with SyntaxError when it is not JSON" do
      for body <- ["{bad", "", "[1,", "undefined"] do
        assert %Web.SyntaxError{message: message, cause: %Jason.DecodeError{}} =
                 catch_exit(await(Response.json(Response.new(body, []))))

        assert message =~ "not valid JSON"
      end
    end

    test "gives the type of the header to its blob, and \"\" with no header" do
      typed = Response.new("x", headers: %{"content-type" => "Text/HTML;charset=UTF-8"})
      assert await(Response.blob(typed)).type == "text/html;charset=utf-8"

      untyped = Response.new(Web.ReadableStream.from(["<html>"]), [])
      assert await(Response.blob(untyped)).type == ""
    end
  end
end
