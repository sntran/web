defmodule Web.MIME do
  @moduledoc false

  @sniff_bytes 1445
  @token_re ~r/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/

  @spec parse(String.t() | nil) :: String.t() | nil
  def parse(nil), do: nil

  def parse(value) do
    raw = trim_http_whitespace(to_string(value))
    {essence, rest} = split_essence_and_params(raw)

    case parse_essence(essence) do
      {:ok, type, subtype} ->
        serialized =
          rest
          |> parse_parameters(MapSet.new(), [])
          |> Enum.reverse()
          |> Enum.map_join(fn {name, val} -> ";" <> name <> "=" <> serialize_value(val) end)

        String.downcase(type) <> "/" <> String.downcase(subtype) <> serialized

      _ ->
        nil
    end
  end

  @spec essence(String.t() | nil) :: String.t() | nil
  def essence(nil), do: nil

  def essence(value) do
    case parse(value) do
      nil -> nil
      parsed -> parsed |> String.split(";", parts: 2) |> hd() |> String.trim()
    end
  end

  @spec sniff(binary() | iodata()) :: String.t()
  def sniff(binary) when is_binary(binary) do
    sample = binary_part(binary, 0, min(byte_size(binary), @sniff_bytes))

    cond do
      html_signature?(sample) -> "text/html"
      xml_signature?(sample) -> "text/xml"
      png_signature?(sample) -> "image/png"
      jpeg_signature?(sample) -> "image/jpeg"
      gif_signature?(sample) -> "image/gif"
      pdf_signature?(sample) -> "application/pdf"
      json_signature?(sample) -> "application/json"
      true -> "application/octet-stream"
    end
  end

  def sniff(iodata) when is_list(iodata), do: iodata |> IO.iodata_to_binary() |> sniff()

  @spec generic_binary?(String.t() | nil) :: boolean()
  def generic_binary?(nil), do: true

  def generic_binary?(mime) do
    normalized =
      mime
      |> to_string()
      |> String.downcase()
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()

    normalized in ["", "application/octet-stream"]
  end

  defp split_essence_and_params(raw) do
    case String.split(raw, ";", parts: 2) do
      [essence, rest] -> {essence, rest}
      [essence] -> {essence, ""}
    end
  end

  defp parse_essence(essence) do
    case String.split(trim_http_whitespace(essence), "/", parts: 2) do
      [type, subtype] when type != "" and subtype != "" ->
        if valid_token?(type) and valid_token?(subtype) do
          {:ok, type, subtype}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp parse_parameters("", _seen, acc), do: acc

  defp parse_parameters(rest, seen, acc) do
    rest = rest |> String.trim_leading(";") |> trim_http_whitespace_leading()

    case rest do
      "" ->
        acc

      _ ->
        {segment, tail} = split_segment(rest)
        advance_parameters(parse_parameter(segment), tail, seen, acc)
    end
  end

  defp advance_parameters({:ok, name, value}, tail, seen, acc) do
    if MapSet.member?(seen, name) do
      parse_parameters(tail, seen, acc)
    else
      parse_parameters(tail, MapSet.put(seen, name), [{name, value} | acc])
    end
  end

  defp advance_parameters(_result, tail, seen, acc), do: parse_parameters(tail, seen, acc)

  defp split_segment(rest), do: split_segment(rest, "", false, false, false)
  defp split_segment("", acc, _quoted, _seen_equals, _value_quote_eligible), do: {acc, ""}

  defp split_segment("\\" <> rest, acc, quoted, seen_equals, value_quote_eligible) do
    case rest do
      <<char::utf8, tail::binary>> ->
        split_segment(
          tail,
          acc <> "\\" <> <<char::utf8>>,
          quoted,
          seen_equals,
          value_quote_eligible
        )

      "" ->
        {acc <> "\\", ""}
    end
  end

  defp split_segment("=" <> rest, acc, quoted, _seen_equals, _value_quote_eligible),
    do: split_segment(rest, acc <> "=", quoted, true, true)

  defp split_segment("\"" <> rest, acc, true, seen_equals, value_quote_eligible),
    do: split_segment(rest, acc <> "\"", false, seen_equals, value_quote_eligible)

  defp split_segment("\"" <> rest, acc, false, true, true),
    do: split_segment(rest, acc <> "\"", true, true, false)

  defp split_segment("\"" <> rest, acc, false, seen_equals, value_quote_eligible),
    do: split_segment(rest, acc <> "\"", false, seen_equals, value_quote_eligible)

  defp split_segment(";" <> rest, acc, false, _seen_equals, _value_quote_eligible),
    do: {acc, rest}

  defp split_segment(
         <<char::utf8, tail::binary>>,
         acc,
         quoted,
         seen_equals,
         _value_quote_eligible
       ) do
    split_segment(tail, acc <> <<char::utf8>>, quoted, seen_equals, false)
  end

  defp parse_parameter(""), do: :skip

  defp parse_parameter(segment) do
    case String.split(segment, "=", parts: 2) do
      [raw_name, raw_value] ->
        parse_named_parameter(raw_name, raw_value)

      _ ->
        :skip
    end
  end

  defp parse_named_parameter(raw_name, raw_value) do
    name = String.downcase(raw_name)

    cond do
      raw_name != String.trim_trailing(raw_name) ->
        :skip

      not valid_token?(name) ->
        :skip

      true ->
        build_parameter_result(name, parse_parameter_value(raw_value))
    end
  end

  defp build_parameter_result(name, {:ok, parsed}), do: {:ok, name, parsed}
  defp build_parameter_result(_name, :skip), do: :skip

  defp parse_parameter_value("\"" <> rest) do
    value = parse_quoted_value(rest, [])

    if contains_forbidden_controls?(value) do
      :skip
    else
      {:ok, value}
    end
  end

  defp parse_parameter_value(value) do
    parsed = trim_http_whitespace_trailing(value)

    cond do
      parsed == "" ->
        :skip

      String.contains?(parsed, ["\v", "\f"]) ->
        :skip

      contains_forbidden_controls?(parsed) ->
        :skip

      String.contains?(parsed, "�") ->
        :skip

      true ->
        {:ok, parsed}
    end
  end

  defp parse_quoted_value("", acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp parse_quoted_value("\\" <> rest, acc) do
    case rest do
      <<char::utf8, tail::binary>> -> parse_quoted_value(tail, [<<char::utf8>> | acc])
      "" -> parse_quoted_value("", ["\\" | acc])
    end
  end

  defp parse_quoted_value("\"" <> _rest, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp parse_quoted_value(<<char::utf8, rest::binary>>, acc) do
    parse_quoted_value(rest, [<<char::utf8>> | acc])
  end

  defp serialize_value(value) do
    if valid_token?(value) do
      value
    else
      escaped =
        value
        |> String.replace("\\", "\\\\")
        |> String.replace("\"", "\\\"")

      "\"" <> escaped <> "\""
    end
  end

  defp valid_token?(value), do: value != "" and Regex.match?(@token_re, value)

  defp contains_forbidden_controls?(value) do
    String.match?(value, ~r/[\x00-\x08\x0A-\x1F\x7F]/u)
  end

  defp trim_http_whitespace(value) do
    value |> trim_http_whitespace_leading() |> trim_http_whitespace_trailing()
  end

  defp trim_http_whitespace_leading(value) do
    String.replace(value, ~r/^[\x09\x0A\x0D\x20]+/u, "")
  end

  defp trim_http_whitespace_trailing(value) do
    String.replace(value, ~r/[\x09\x0A\x0D\x20]+$/u, "")
  end

  defp html_signature?(sample) do
    if String.valid?(sample) do
      normalized = sample |> trim_http_whitespace_leading() |> String.upcase()

      String.starts_with?(normalized, "<!DOCTYPE HTML") or
        String.starts_with?(normalized, "<HTML")
    else
      false
    end
  end

  defp xml_signature?(sample) do
    if String.valid?(sample) do
      sample
      |> trim_http_whitespace_leading()
      |> String.downcase()
      |> String.starts_with?("<?xml")
    else
      false
    end
  end

  defp png_signature?(<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: true
  defp png_signature?(_), do: false

  defp jpeg_signature?(<<0xFF, 0xD8, 0xFF, _::binary>>), do: true
  defp jpeg_signature?(_), do: false

  defp gif_signature?("GIF87a" <> _), do: true
  defp gif_signature?("GIF89a" <> _), do: true
  defp gif_signature?(_), do: false

  defp pdf_signature?("%PDF-" <> _), do: true
  defp pdf_signature?(_), do: false

  defp json_signature?(sample) do
    if String.valid?(sample) do
      trimmed = trim_http_whitespace(sample)
      String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[")
    else
      false
    end
  end
end
