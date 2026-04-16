defmodule Web.URL.Encoding do
  @moduledoc false

  @spec trim_c0_whitespace(term()) :: String.t()
  def trim_c0_whitespace(value) do
    value
    |> to_string()
    |> String.replace(~r/^[\x00-\x20]+|[\x00-\x20]+$/u, "")
  end

  @spec strip_ascii_tab_and_newline(term()) :: String.t()
  def strip_ascii_tab_and_newline(value) do
    String.replace(to_string(value), ~r/[\x09\x0A\x0D]/u, "")
  end

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
