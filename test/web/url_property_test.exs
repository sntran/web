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
    ArgumentError -> :error
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

      assert URL.href(url) ==
               URL.protocol(url) <>
                 "//" <>
                 URL.hostname(url) <>
                 port <> URL.pathname(url) <> URL.search(url) <> URL.hash(url)
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
    if String.match?(reference, ~r/^([a-zA-Z][a-zA-Z0-9+.-]*:|\/\/|\\\\)/) do
      :error
    else
      {:ok, URL.new(reference, base)}
    end
  rescue
    ArgumentError -> :error
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
