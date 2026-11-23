defmodule Web.URL.Encoding do
  @moduledoc false

  alias Web.Internal.Ascii

  # Removes the C0 control characters and the spaces at the start and at the
  # end. Raises `Web.TypeError` for a value that is not valid UTF-8.
  @spec trim_c0_whitespace(term()) :: String.t()
  def trim_c0_whitespace(value), do: value |> to_string() |> valid_utf8!() |> trim_c0()

  # `trim_c0_whitespace/1` for a binary that is valid UTF-8 already.
  @spec trim_c0(binary()) :: binary()
  def trim_c0(value) do
    value
    |> Ascii.trim_leading(&c0_or_space?/1)
    |> Ascii.trim_trailing(&c0_or_space?/1)
  end

  defp c0_or_space?(char), do: char <= 0x20

  # Removes each tab, line feed, and carriage return. Raises `Web.TypeError`
  # for a value that is not valid UTF-8.
  @spec strip_ascii_tab_and_newline(term()) :: String.t()
  def strip_ascii_tab_and_newline(value) do
    value |> to_string() |> valid_utf8!() |> strip_tab_newline()
  end

  # `strip_ascii_tab_and_newline/1` for a binary that is valid UTF-8 already.
  @spec strip_tab_newline(binary()) :: binary()
  def strip_tab_newline(value) do
    if tab_or_newline?(value),
      do: :binary.replace(value, ["\t", "\n", "\r"], "", [:global]),
      else: value
  end

  defp tab_or_newline?(<<char, _rest::binary>>) when char in [?\t, ?\n, ?\r], do: true
  defp tab_or_newline?(<<_char, rest::binary>>), do: tab_or_newline?(rest)
  defp tab_or_newline?(<<>>), do: false

  @spec valid_utf8!(binary()) :: binary()
  def valid_utf8!(value) do
    if String.valid?(value),
      do: value,
      else: raise(Web.TypeError, "The URL is not valid UTF-8.")
  end

  # The type of a path segment: "." and ".." are dot segments, also when a
  # dot is written as "%2e" or "%2E".
  @spec dot_segment_type(String.t()) :: :single | :double | :none
  def dot_segment_type(segment) do
    case count_dots(segment, 0) do
      1 -> :single
      2 -> :double
      _other -> :none
    end
  end

  defp count_dots(<<>>, count), do: count
  defp count_dots(<<?., rest::binary>>, count) when count < 2, do: count_dots(rest, count + 1)

  defp count_dots(<<?%, ?2, e, rest::binary>>, count) when e in [?e, ?E] and count < 2,
    do: count_dots(rest, count + 1)

  defp count_dots(_segment, _count), do: 3

  @spec normalize_special_path_separators(term(), boolean()) :: String.t()
  def normalize_special_path_separators(value, false), do: to_string(value)

  def normalize_special_path_separators(value, true) do
    value
    |> to_string()
    |> do_normalize_special_path_separators(:path, [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  @spec encode_userinfo_component(term()) :: String.t()
  def encode_userinfo_component(value) do
    URI.encode(to_string(value), &userinfo_char?/1)
  end

  @spec encode_query_component(term(), boolean()) :: String.t()
  def encode_query_component(value, special? \\ false) do
    percent_encode_with_set(to_string(value), &query_char_requires_encoding?(&1, special?))
  end

  @spec encode_fragment_component(term()) :: String.t()
  def encode_fragment_component(value) do
    percent_encode_with_set(to_string(value), &fragment_char_requires_encoding?/1)
  end

  @spec encode_path_component(term()) :: String.t()
  def encode_path_component(value) do
    percent_encode_with_set(to_string(value), &path_char_requires_encoding?/1)
  end

  @spec percent_encode_non_ascii(String.t()) :: String.t()
  def percent_encode_non_ascii(input) do
    percent_encode_non_ascii(input, "")
  end

  @spec percent_encode_utf8(String.t()) :: String.t()
  def percent_encode_utf8(input) do
    percent_encode_utf8(input, "")
  end

  defp do_normalize_special_path_separators("", _state, acc), do: acc

  defp do_normalize_special_path_separators("?" <> rest, :path, acc) do
    do_normalize_special_path_separators(rest, :query, ["?" | acc])
  end

  defp do_normalize_special_path_separators("#" <> rest, state, acc)
       when state in [:path, :query] do
    do_normalize_special_path_separators(rest, :fragment, ["#" | acc])
  end

  defp do_normalize_special_path_separators("\\" <> rest, :path, acc) do
    do_normalize_special_path_separators(rest, :path, ["/" | acc])
  end

  defp do_normalize_special_path_separators(<<char::utf8, rest::binary>>, state, acc) do
    do_normalize_special_path_separators(rest, state, [<<char::utf8>> | acc])
  end

  defp percent_encode_non_ascii("", acc), do: acc

  defp percent_encode_non_ascii(<<"%", a::utf8, b::utf8, rest::binary>>, acc)
       when a in ?0..?9 or a in ?a..?f or a in ?A..?F do
    percent_encode_non_ascii(rest, acc <> "%" <> <<a::utf8>> <> <<b::utf8>>)
  end

  defp percent_encode_non_ascii(<<char::utf8, rest::binary>>, acc) when char <= 0x7F do
    percent_encode_non_ascii(rest, acc <> <<char::utf8>>)
  end

  defp percent_encode_non_ascii(<<char::utf8, rest::binary>>, acc) do
    encoded =
      <<char::utf8>>
      |> :binary.bin_to_list()
      |> Enum.map_join("", fn byte ->
        "%" <> String.upcase(Integer.to_string(byte, 16) |> String.pad_leading(2, "0"))
      end)

    percent_encode_non_ascii(rest, acc <> encoded)
  end

  defp percent_encode_utf8("", acc), do: acc

  defp percent_encode_utf8(<<"%", a::utf8, b::utf8, rest::binary>>, acc)
       when a in ?0..?9 or a in ?a..?f or a in ?A..?F do
    percent_encode_utf8(rest, acc <> "%" <> <<a::utf8>> <> <<b::utf8>>)
  end

  defp percent_encode_utf8(<<char::utf8, rest::binary>>, acc)
       when char > 0x7F or char <= 0x20 or char == 0x7F do
    encoded =
      <<char::utf8>>
      |> :binary.bin_to_list()
      |> Enum.map_join("", fn byte ->
        "%" <> String.upcase(Integer.to_string(byte, 16) |> String.pad_leading(2, "0"))
      end)

    percent_encode_utf8(rest, acc <> encoded)
  end

  defp percent_encode_utf8(<<char::utf8, rest::binary>>, acc) do
    percent_encode_utf8(rest, acc <> <<char::utf8>>)
  end

  defp percent_encode_with_set(input, predicate) do
    percent_encode_with_set(input, predicate, "")
  end

  defp percent_encode_with_set("", _predicate, acc), do: acc

  defp percent_encode_with_set(<<"%", a::utf8, b::utf8, rest::binary>>, predicate, acc) do
    if hex_digit?(a) and hex_digit?(b) do
      percent_encode_with_set(rest, predicate, acc <> "%" <> <<a::utf8>> <> <<b::utf8>>)
    else
      percent_encode_with_set(<<a::utf8, b::utf8, rest::binary>>, predicate, acc <> "%")
    end
  end

  defp percent_encode_with_set(<<char::utf8, rest::binary>>, predicate, acc) do
    chunk = if predicate.(char), do: percent_encode_codepoint(char), else: <<char::utf8>>
    percent_encode_with_set(rest, predicate, acc <> chunk)
  end

  defp percent_encode_codepoint(char) do
    <<char::utf8>>
    |> :binary.bin_to_list()
    |> Enum.map_join("", fn byte ->
      "%" <> String.upcase(Integer.to_string(byte, 16) |> String.pad_leading(2, "0"))
    end)
  end

  defp query_char_requires_encoding?(char, special?) do
    c0_control_percent_encode?(char) or char in [0x20, 0x22, 0x23, 0x3C, 0x3E] or
      (special? and char == 0x27)
  end

  defp fragment_char_requires_encoding?(char) do
    c0_control_percent_encode?(char) or char in [0x20, 0x22, 0x3C, 0x3E, 0x60]
  end

  defp path_char_requires_encoding?(char) do
    query_char_requires_encoding?(char, false) or char in [0x3F, 0x5E, 0x60, 0x7B, 0x7D]
  end

  defp c0_control_percent_encode?(char), do: char <= 0x1F or char > 0x7E

  defp hex_digit?(char) do
    (char >= ?0 and char <= ?9) or (char >= ?a and char <= ?f) or (char >= ?A and char <= ?F)
  end

  defp userinfo_char?(char)
       when (char >= ?a and char <= ?z) or (char >= ?A and char <= ?Z) or
              (char >= ?0 and char <= ?9) do
    true
  end

  defp userinfo_char?(char)
       when char in [?-, ?., ?_, ?~, ?!, ?$, ?%, ?&, ?', ?(, ?), ?*, ?+, ?,], do: true

  defp userinfo_char?(_char), do: false
end
