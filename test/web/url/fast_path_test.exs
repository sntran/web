defmodule Web.URL.FastPathTest do
  # `Web.URL.FastPath` parses the usual URL of a request with a short path.
  # For each input that it accepts, the result must be the result of the
  # full parser. These properties compare the two.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.URL.FastPath
  alias Web.URL.Parser

  defp full_parse(input), do: Map.merge(%Web.URL{}, Parser.parse!(input))

  @ipv4_hosts [
    "127.0.0.1",
    "0.0.0.0",
    "255.255.255.255",
    "10.0.20.255",
    "1.2.3",
    "01.2.3.4",
    "256.1.1.1",
    "1.2.3.4.5",
    "1.2.3.4.",
    "1..2.3"
  ]

  defp piece(chars, max_length) do
    chars |> list_of(max_length: max_length) |> map(&List.to_string/1)
  end

  # Mostly the bytes that the fast path accepts, and some bytes that it
  # refuses.
  defp url_chars do
    good = Enum.concat([?a..?c, ?A..?B, ?0..?1, ~c"-._~!$&'()*+,;=:@/?"])
    bad = ~c"#%. \\\"<>`{}^|"
    frequency([{12, member_of(good)}, {1, member_of(bad)}])
  end

  # Inputs near the class of the fast path: most are in it, and some are not.
  defp url_input do
    label = piece(member_of(Enum.concat([?a..?d, ?A..?C, ?0..?2, [?-]])), 5)

    gen all(
          scheme <-
            frequency([
              {6, member_of(["http", "https", "HTTP", "Wss", "ws"])},
              {1, member_of(["ftp", "file", "foo"])}
            ]),
          labels <-
            frequency([
              {3, list_of(label, min_length: 1, max_length: 3)},
              {1, map(member_of(@ipv4_hosts), &[&1])}
            ]),
          port <-
            frequency([
              {4, constant("")},
              {3, member_of([":80", ":443", ":8080", ":65535"])},
              {1, member_of([":", ":0", ":080", ":65536"])}
            ]),
          path <- one_of([constant(""), map(piece(url_chars(), 10), &("/" <> &1))]),
          query <- one_of([constant(""), map(piece(url_chars(), 8), &("?" <> &1))]),
          fragment <- one_of([constant(""), map(piece(url_chars(), 8), &("#" <> &1))])
        ) do
      "#{scheme}://#{Enum.join(labels, ".")}#{port}#{path}#{query}#{fragment}"
    end
  end

  property "the fast path gives the result of the full parser" do
    accepted = :counters.new(1, [])

    check all(input <- url_input(), max_runs: 3_000) do
      case FastPath.parse(input) do
        {:ok, fields} ->
          :counters.add(accepted, 1, 1)
          assert Map.merge(%Web.URL{}, fields) == full_parse(input), inspect(input)

        :error ->
          :ok
      end
    end

    # The property compares many inputs, not only the inputs that the fast
    # path refuses.
    assert :counters.get(accepted, 1) > 300
  end

  test "the fast path accepts the usual URLs" do
    for input <- [
          "http://127.0.0.1.example/small",
          "http://127.0.0.1:4472/small",
          "http://192.168.0.255/",
          "https://example.com/a/b?c=d&e#f",
          "HTTPS://Example.COM:443/a/b?c=d&e#f",
          "http://h",
          "http://h:8080?",
          "http://h/#",
          "ws://a.b-c.d/x~y_z.w",
          "wss://api.example.com:8443/v1/items?limit=10&page=2"
        ] do
      assert {:ok, fields} = FastPath.parse(input), input
      assert Map.merge(%Web.URL{}, fields) == full_parse(input), input
      assert Web.URL.new(input) == full_parse(input), input
    end
  end

  test "the fast path refuses each URL that needs the full parser" do
    for input <- [
          "http://127.1/",
          "http://127.0.0.01/",
          "http://0x7f.1/",
          "http://[::1]/",
          "http://user:pass@host/",
          "http://host:/",
          "http://host:080/",
          "http://host:99999/",
          "http://host./",
          "http://.host/",
          "http://a..b/",
          "http://host/a/../b",
          "http://host/./b",
          "http://host/a/%2e/b",
          "http://host/a b",
          "http://host/\\b",
          "http://host/?q=it's",
          "http://hÖst/",
          "foo://host/",
          "file:///etc",
          "http:host"
        ] do
      assert FastPath.parse(input) == :error, input
    end
  end

  test "a URL with a base uses the full parser" do
    assert Web.URL.href(Web.URL.new("http://a.example/x", "https://b.example/")) ==
             "http://a.example/x"
  end
end
