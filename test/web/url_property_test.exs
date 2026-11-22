defmodule Web.URLPropertyTest do
  # Properties of `Web.URL`, `Web.URLSearchParams`, and the host conversion,
  # for random input.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.URL
  alias Web.URL.Punycode
  alias Web.URLSearchParams

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp label do
    one_of([
      string(Enum.concat(?a..?z, ?0..?9), min_length: 1, max_length: 8),
      string([?a..?z, ?à..?ö, ?α..?ω, ?а..?я], min_length: 1, max_length: 6)
    ])
  end

  defp host do
    gen all(labels <- list_of(label(), min_length: 1, max_length: 3)) do
      Enum.join(labels, ".") <> ".example"
    end
  end

  defp segment, do: string([?a..?z, ?A..?Z, ?0..?9, ?-, ?_, ?., ?~, ?\s, ?é, ?%], max_length: 6)

  defp url_text do
    gen all(
          scheme <- member_of(["http", "https"]),
          host <- host(),
          port <- one_of([constant(""), map(integer(1..65_535), &":#{&1}")]),
          segments <- list_of(segment(), max_length: 4),
          query <- one_of([constant(""), map(segment(), &"?#{&1}")]),
          fragment <- one_of([constant(""), map(segment(), &"##{&1}")])
        ) do
      "#{scheme}://#{host}#{port}/#{Enum.join(segments, "/")}#{query}#{fragment}"
    end
  end

  defp parse(text) do
    {:ok, URL.new(text)}
  rescue
    Web.TypeError -> :error
  end

  # ---------------------------------------------------------------------------
  # URL
  # ---------------------------------------------------------------------------

  property "the text of a URL gives the same URL when it is read again" do
    check all(text <- url_text()) do
      url = URL.new(text)
      again = URL.new(URL.href(url))

      assert URL.href(again) == URL.href(url)
      assert URL.origin(again) == URL.origin(url)
    end
  end

  property "the same is true for each text that is a valid URL" do
    check all(text <- string(:printable, max_length: 40)) do
      with {:ok, url} <- parse("http://" <> text) do
        assert {:ok, again} = parse(URL.href(url))
        assert URL.href(again) == URL.href(url)
      end
    end
  end

  property "the parts of a URL make its text" do
    check all(text <- url_text()) do
      url = URL.new(text)

      port = if URL.port(url) == "", do: "", else: ":" <> URL.port(url)

      # The getters give "" for an empty query and for an empty fragment.
      # The text keeps their "?" and "#".
      search = if URL.search(url) == "" and url.search != nil, do: "?", else: URL.search(url)
      hash = if URL.hash(url) == "" and url.fragment != nil, do: "#", else: URL.hash(url)

      assert URL.href(url) ==
               URL.protocol(url) <>
                 "//" <> URL.hostname(url) <> port <> URL.pathname(url) <> search <> hash
    end
  end

  property "the host of a URL is ASCII and lowercase" do
    check all(text <- url_text()) do
      hostname = URL.hostname(URL.new(text))

      assert hostname == String.downcase(hostname)
      assert String.match?(hostname, ~r/^[\x21-\x7E]+$/)
    end
  end

  property "a relative reference gives a URL with the origin of its base" do
    check all(base <- url_text(), segments <- list_of(segment(), max_length: 3)) do
      reference = Enum.join(segments, "/")

      with {:ok, url} <- relative(reference, base) do
        assert URL.origin(url) == URL.origin(URL.new(base))
      end
    end
  end

  defp relative(reference, base) do
    # A reference that starts with a scheme or with "//" is not relative.
    # The parser removes the spaces at the start, as the URL Standard
    # specifies, thus the test examines the reference with no such spaces.
    if String.match?(String.trim_leading(reference), ~r/^([a-zA-Z][a-zA-Z0-9+.-]*:|\/\/|\\\\)/) do
      :error
    else
      {:ok, URL.new(reference, base)}
    end
  rescue
    Web.TypeError -> :error
  end

  # ---------------------------------------------------------------------------
  # The host conversion
  # ---------------------------------------------------------------------------

  property "the ASCII form of a valid host does not change when it is converted again" do
    check all(host <- host()) do
      if Punycode.valid_host?(host) do
        ascii = Punycode.host_to_ascii(host)

        assert Punycode.valid_host?(ascii)
        assert Punycode.host_to_ascii(ascii) == ascii
      end
    end
  end

  property "the host conversion gives a result for each text, and does not raise" do
    check all(text <- one_of([string(:printable, max_length: 20), binary(max_length: 12)])) do
      assert is_boolean(Punycode.valid_host?(text))
      assert is_binary(Punycode.host_to_ascii(text))
    end
  end

  # The final sigma is a deviation character of UTS #46: it stays as it is,
  # but its capital letter becomes the usual small sigma. Thus the property
  # does not include it.
  property "the conversion ignores the case of the letters" do
    check all(host <- filter(host(), &(not String.contains?(&1, "ς")))) do
      assert Punycode.valid_host?(String.upcase(host)) == Punycode.valid_host?(host)

      if Punycode.valid_host?(host) do
        assert Punycode.host_to_ascii(String.upcase(host)) == Punycode.host_to_ascii(host)
      end
    end
  end

  property "Punycode of a label decodes to the label" do
    check all(
            label <-
              string([?a..?z, ?à..?ö, ?α..?ω, ?一..?丁], min_length: 1, max_length: 10)
          ) do
      decoded = label |> Punycode.encode() |> String.to_charlist() |> :punycode.decode()
      assert List.to_string(decoded) == label
    end
  end

  # ---------------------------------------------------------------------------
  # URLSearchParams
  # ---------------------------------------------------------------------------

  defp pairs do
    list_of(tuple({string(:printable, max_length: 6), string(:printable, max_length: 6)}),
      max_length: 6
    )
  end

  property "search parameters stay the same through their text" do
    check all(pairs <- pairs()) do
      params =
        Enum.reduce(pairs, URLSearchParams.new(), fn {name, value}, params ->
          URLSearchParams.append(params, name, value)
        end)

      again = URLSearchParams.new(URLSearchParams.to_string(params))

      assert URLSearchParams.to_list(again) == URLSearchParams.to_list(params)
      assert URLSearchParams.to_list(params) == pairs
    end
  end

  property "get_all/2 gives each value of a name, in sequence" do
    check all(pairs <- pairs()) do
      params =
        Enum.reduce(pairs, URLSearchParams.new(), fn {name, value}, params ->
          URLSearchParams.append(params, name, value)
        end)

      for {name, _value} <- pairs do
        assert URLSearchParams.get_all(params, name) == for({^name, value} <- pairs, do: value)
      end
    end
  end

  property "set/3 leaves one value for the name, and keeps the other names" do
    check all(
            pairs <- pairs(),
            name <- string(:printable, max_length: 6),
            value <- string(:printable)
          ) do
      params =
        pairs
        |> Enum.reduce(URLSearchParams.new(), fn {name, value}, params ->
          URLSearchParams.append(params, name, value)
        end)
        |> URLSearchParams.set(name, value)

      assert URLSearchParams.get_all(params, name) == [value]

      assert Enum.reject(URLSearchParams.to_list(params), &(elem(&1, 0) == name)) ==
               Enum.reject(pairs, &(elem(&1, 0) == name))
    end
  end

  defp pair_text({name, value}) do
    URLSearchParams.to_string(URLSearchParams.new([{name, value}]))
  end

  property "the parser skips each empty sequence between two \"&\"" do
    check all(
            pairs <- pairs(),
            gaps <- list_of(integer(1..3), length: length(pairs) + 1),
            first <- integer(0..2)
          ) do
      [_ | separators] = Enum.map(gaps, &String.duplicate("&", &1))

      text =
        String.duplicate("&", first) <>
          (pairs
           |> Enum.map(&pair_text/1)
           |> Enum.zip(separators)
           |> Enum.map_join(&Tuple.to_list/1))

      assert URLSearchParams.to_list(URLSearchParams.new(text)) == pairs
    end
  end

  # The bytes that the serializer keeps: the URL Standard percent-encodes
  # each other byte, and changes a space to "+".
  @form_safe Enum.concat([?a..?z, ?A..?Z, ?0..?9, [?*, ?-, ?., ?_]])

  property "the serializer keeps the safe bytes, and percent-encodes each other byte" do
    check all(
            safe <- string(@form_safe, max_length: 8),
            other <- string(:printable, max_length: 8)
          ) do
      assert pair_text({safe, ""}) == safe <> "="

      encoded = pair_text({other, ""})
      assert encoded =~ ~r/\A([A-Za-z0-9*\-._+]|%[0-9A-F]{2})*=\z/

      kept = for <<byte <- other>>, byte in @form_safe, into: "", do: <<byte>>
      assert String.replace(encoded, ~r/%[0-9A-F]{2}|[+=]/, "") == kept
    end
  end

  # The UTF-16 code units of a text, as a list of integers.
  defp utf16_units(text) do
    text
    |> String.to_charlist()
    |> Enum.flat_map(fn
      char when char < 0x10000 ->
        [char]

      char ->
        offset = char - 0x10000
        [0xD800 + Bitwise.bsr(offset, 10), 0xDC00 + Bitwise.band(offset, 0x3FF)]
    end)
  end

  property "sort/1 sorts by UTF-16 code units, and keeps the sequence of equal names" do
    name = string([?a, ?b, 0xE9, 0xFB03, 0xFFFD, 0x1F308, 0x1F4A9], max_length: 3)

    check all(pairs <- list_of(tuple({name, string(?0..?9, max_length: 2)}), max_length: 8)) do
      expected =
        pairs
        |> Enum.with_index()
        |> Enum.sort_by(fn {{name, _value}, index} -> {utf16_units(name), index} end)
        |> Enum.map(&elem(&1, 0))

      sorted = pairs |> URLSearchParams.new() |> URLSearchParams.sort()
      assert URLSearchParams.to_list(sorted) == expected
    end
  end

  property "new/1 raises Web.TypeError for an inner list that does not have two items" do
    check all(
            item <-
              filter(
                list_of(string(:printable, max_length: 3), max_length: 4),
                &(length(&1) != 2)
              ),
            pairs <- pairs()
          ) do
      assert_raise Web.TypeError, fn -> URLSearchParams.new(pairs ++ [item]) end
    end
  end

  property "has/3 and delete/3 find the pairs with the name and the value" do
    small = string([?a, ?b], max_length: 2)

    check all(
            pairs <- list_of(tuple({small, small}), max_length: 6),
            name <- small,
            value <- small
          ) do
      params = URLSearchParams.new(pairs)

      assert URLSearchParams.has(params, name, value) == {name, value} in pairs
      assert URLSearchParams.has(params, name, nil) == URLSearchParams.has(params, name)

      assert URLSearchParams.to_list(URLSearchParams.delete(params, name, value)) ==
               Enum.reject(pairs, &(&1 == {name, value}))

      assert URLSearchParams.delete(params, name, nil) == URLSearchParams.delete(params, name)
      assert URLSearchParams.size(params) == length(pairs)
    end
  end

  property "parse/2 and can_parse/2 agree with new/2" do
    check all(
            text <- one_of([url_text(), string(:printable, max_length: 20)]),
            base <- one_of([constant(nil), url_text()])
          ) do
      expected =
        try do
          URL.new(text, base)
        rescue
          Web.TypeError -> nil
        end

      assert URL.parse(text, base) == expected
      assert URL.can_parse(text, base) == (expected != nil)
    end
  end

  property "search and hash give \"\" for an empty query and an empty fragment" do
    check all(text <- url_text()) do
      url = URL.new(text)
      href = URL.href(url)

      assert URL.search(url) != "?"
      assert URL.hash(url) != "#"
      assert String.contains?(href, "?") == (url.search != nil)
      assert String.contains?(href, "#") == (url.fragment != nil)
    end
  end

  property "the search of a URL and its parameters agree" do
    check all(text <- url_text(), pairs <- pairs()) do
      query =
        Enum.reduce(pairs, URLSearchParams.new(), fn {name, value}, params ->
          URLSearchParams.append(params, name, value)
        end)

      url = URL.search(URL.new(text), URLSearchParams.to_string(query))

      assert URLSearchParams.to_list(URL.search_params(url)) == pairs
      assert URLSearchParams.to_list(URL.search_params(URL.new(URL.href(url)))) == pairs
    end
  end
end
