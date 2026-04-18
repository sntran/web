defmodule Web.Platform.Test.JSHarvester do
  @moduledoc false

  import Bitwise

  @shared_reference_array "Array with identical property values"
  @shared_reference_object "Object with identical property values"
  @data_clone_error "Serializing a non-serializable platform object fails"
  @transfer_array_buffer "ArrayBuffer"
  @transfer_blob_error "Transferring a non-transferable platform object fails"
  @invocation_signature ~r/(check|structuredCloneBatteryOfTests\s*\.\s*push|test)\s*\(/

  @spec load!(String.t(), String.t()) :: [map()]
  def load!(url, source) when is_binary(url) and is_binary(source) do
    cases =
      source
      |> extract_blocks()
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(&harvest_invocation(source, &1))

    if cases == [] do
      raise ArgumentError, "Unsupported WPT JS dataset: #{url}"
    end

    cases
  end

  @doc false
  @spec parse_literal!(String.t()) :: term()
  def parse_literal!(text) do
    text
    |> String.trim()
    |> parse_value()
    |> finalize_literal!()
  end

  defp finalize_literal!({value, rest}) do
    case String.trim(rest) do
      "" ->
        value

      trailing ->
        raise ArgumentError,
              "Unsupported trailing JS literal content: #{inspect(trailing)}"
    end
  end

  defp extract_blocks(source) do
    extract_invocations(source, @invocation_signature, 0)
  end

  defp extract_invocations(source, signature, offset),
    do: extract_invocations(source, signature, offset, [])

  defp extract_invocations(source, signature, offset, acc) when offset < byte_size(source) do
    case next_invocation(source, signature, offset) do
      {:ok, index, callee, start} ->
        {invocation, next_offset} = extract_balanced!(source, start, ?))

        extract_invocations(
          source,
          signature,
          next_offset,
          [{index, invocation_kind(callee), invocation} | acc]
        )

      {:skip, next_offset} ->
        extract_invocations(source, signature, next_offset, acc)

      :nomatch ->
        Enum.reverse(acc)
    end
  end

  defp extract_invocations(_source, _signature, _offset, acc), do: Enum.reverse(acc)

  defp next_invocation(source, signature, offset) do
    case Regex.run(signature, source,
           capture: :all,
           offset: offset,
           return: :index
         ) do
      [{match_start, match_length}, {callee_start, callee_length}] ->
        callee = slice_binary(source, callee_start, callee_length)
        next_offset = match_start + max(match_length, 1)

        if standalone_signature?(source, callee_start) do
          {:ok, match_start, callee, match_start + match_length}
        else
          {:skip, next_offset}
        end

      nil ->
        :nomatch
    end
  end

  defp invocation_kind("check"), do: :check
  defp invocation_kind("test"), do: :test
  defp invocation_kind(_callee), do: :push

  defp standalone_signature?(_source, index) when index <= 0, do: true

  defp standalone_signature?(source, index) do
    previous_char = :binary.at(source, index - 1)
    prefix = signature_prefix(source, index)

    not identifier_char?(previous_char) and not function_definition?(prefix)
  end

  defp signature_prefix(source, index) do
    prefix_start = max(index - 24, 0)
    slice_binary(source, prefix_start, index - prefix_start)
  end

  defp function_definition?(prefix), do: Regex.match?(~r/function\s+\z/u, prefix)

  defp harvest_invocation(source, {_position, :check, invocation}),
    do: harvest_check_case(source, invocation)

  defp harvest_invocation(_source, {_position, :push, invocation}),
    do: harvest_push_case(invocation)

  defp harvest_invocation(_source, {_position, :test, invocation}),
    do: harvest_test_case(invocation)

  defp harvest_check_case(source, invocation) do
    with {:ok, description_expr, value_expr, comparator} <- parse_check_invocation(invocation),
         {:ok, description} <- maybe_parse_literal(description_expr) do
      build_check_case(source, description, comparator, value_expr)
    else
      :error ->
        []

      {:error, :unsupported_shape} ->
        raise ArgumentError,
              "Unsupported structured clone check block: #{inspect(invocation)}"
    end
  end

  defp parse_check_invocation(invocation) do
    case split_top_level(invocation, ?,) do
      [description_expr, value_expr, comparator_expr | _rest] ->
        {:ok, description_expr, value_expr, String.trim(comparator_expr)}

      _other ->
        {:error, :unsupported_shape}
    end
  end

  defp build_check_case(_source, @shared_reference_array, _comparator, _value_expr) do
    [%{"comment" => @shared_reference_array, "kind" => "shared_reference_array"}]
  end

  defp build_check_case(_source, @shared_reference_object, _comparator, _value_expr) do
    [%{"comment" => @shared_reference_object, "kind" => "shared_reference_object"}]
  end

  defp build_check_case(_source, description, "compare_primitive", value_expr)
       when is_binary(description) do
    maybe_parse_primitive_case(description, value_expr)
  end

  defp build_check_case(_source, description, "compare_Date", value_expr)
       when is_binary(description) do
    maybe_parse_date_case(description, value_expr)
  end

  defp build_check_case(source, description, "compare_Blob", value_expr)
       when is_binary(description) do
    maybe_parse_blob_case(source, description, value_expr)
  end

  defp build_check_case(_source, _description, _comparator, _value_expr), do: []

  defp maybe_parse_primitive_case(description, value_expr) do
    case maybe_parse_literal(value_expr) do
      {:ok, value} -> [%{"comment" => description, "kind" => "primitive", "value" => value}]
      :error -> []
    end
  end

  defp maybe_parse_date_case(description, value_expr) do
    case maybe_parse_literal(value_expr) do
      {:ok, {:date_ms, milliseconds}} ->
        [%{"comment" => description, "kind" => "date_time", "unix_ms" => milliseconds}]

      _other ->
        []
    end
  end

  defp maybe_parse_blob_case(source, description, value_expr) do
    case maybe_parse_blob(source, value_expr) do
      {:ok, {:blob, parts, opts}} ->
        [
          %{
            "comment" => description,
            "kind" => "blob",
            "parts" => parts,
            "type" => Map.get(opts, "type", "")
          }
        ]

      :error ->
        []
    end
  end

  defp harvest_push_case(invocation) do
    case extract_description(invocation) do
      {:ok, @data_clone_error} ->
        [%{"comment" => @data_clone_error, "kind" => "data_clone_error"}]

      {:ok, @transfer_blob_error} ->
        [%{"comment" => @transfer_blob_error, "kind" => "transfer_blob_error"}]

      {:ok, @transfer_array_buffer} ->
        bytes = extract_transfer_bytes!(invocation)

        [
          %{
            "comment" => @transfer_array_buffer,
            "kind" => "transfer_array_buffer",
            "bytes" => bytes
          }
        ]

      {:ok, _other} ->
        []

      :error ->
        []
    end
  end

  defp harvest_test_case(invocation) do
    invocation
    |> split_top_level(?,)
    |> extract_test_description()
    |> case do
      {:ok, description} -> [%{"comment" => description, "kind" => "test"}]
      :error -> []
    end
  end

  defp extract_test_description([first_arg, second_arg | _rest]) do
    first_arg
    |> maybe_parse_string_description()
    |> fallback_test_description(second_arg)
  end

  defp extract_test_description(_args), do: :error

  defp fallback_test_description({:ok, description}, _fallback), do: {:ok, description}

  defp fallback_test_description(:error, fallback) do
    maybe_parse_string_description(fallback)
  end

  defp maybe_parse_string_description(text) do
    case maybe_parse_literal(text) do
      {:ok, description} when is_binary(description) -> {:ok, description}
      _other -> :error
    end
  end

  defp resolve_helper_expression!(source, expression) do
    expression = String.trim(expression)

    case Regex.run(~r/\A([A-Za-z_][A-Za-z0-9_]*)\z/u, expression, capture: :all_but_first) do
      [function_name] -> extract_function_return!(source, function_name)
      _other -> expression
    end
  end

  defp extract_function_return!(source, function_name) do
    signature = "function #{function_name}("

    case :binary.match(source, signature) do
      {index, _length} ->
        search_offset = index + byte_size(signature)

        case :binary.match(source, "{", scope: {search_offset, byte_size(source) - search_offset}) do
          {brace_index, 1} ->
            {body, _next_offset} = extract_balanced!(source, brace_index + 1, ?})
            extract_return_expression!(body)

          :nomatch ->
            raise ArgumentError, "Unsupported WPT helper: #{function_name}"
        end

      :nomatch ->
        raise ArgumentError, "Unsupported WPT helper: #{function_name}"
    end
  end

  defp extract_return_expression!(body) do
    case :binary.match(body, "return") do
      {index, _length} ->
        body
        |> slice_binary(
          index + byte_size("return"),
          byte_size(body) - index - byte_size("return")
        )
        |> split_top_level(?;)
        |> List.first()
        |> case do
          nil -> raise ArgumentError, "Unsupported WPT helper return body: #{inspect(body)}"
          expression -> String.trim(expression)
        end

      :nomatch ->
        raise ArgumentError, "Unsupported WPT helper return body: #{inspect(body)}"
    end
  end

  defp extract_description(invocation) do
    case Regex.run(
           ~r/\bdescription\s*:\s*(?<value>'(?:\\.|[^'])*'|"(?:\\.|[^"])*")/s,
           invocation,
           capture: :all_names
         ) do
      [description] -> {:ok, parse_literal!(description)}
      _other -> :error
    end
  end

  defp extract_transfer_bytes!(invocation) do
    case Regex.run(
           ~r/(?:new\s+)?Uint8Array\(\[(?<bytes>[^\]]*)\]\)\.buffer/s,
           invocation,
           capture: :all_names
         ) do
      [bytes] ->
        parse_integer_list(bytes)

      _other ->
        raise ArgumentError, "Unsupported ArrayBuffer transfer block: #{inspect(invocation)}"
    end
  end

  defp extract_balanced!(source, start, closing_char) do
    do_extract_balanced(source, start, start, [closing_char], :code)
  end

  defp do_extract_balanced(source, start, index, _stack, _mode) when index >= byte_size(source) do
    raise ArgumentError,
          "Unterminated JS block starting at byte #{start}: #{inspect(slice_binary(source, start, byte_size(source) - start))}"
  end

  defp do_extract_balanced(source, start, index, stack, :code) do
    case next_balance_state(source, index, stack) do
      {:string, next_index, quote} ->
        do_extract_balanced(source, start, next_index, stack, {:string, quote})

      {:comment, next_index, :line} ->
        do_extract_balanced(source, start, next_index, stack, :line_comment)

      {:comment, next_index, :block} ->
        do_extract_balanced(source, start, next_index, stack, :block_comment)

      {:open, next_index, closer} ->
        do_extract_balanced(source, start, next_index, [closer | stack], :code)

      {:close, current_index, next_index} ->
        continue_after_close(source, start, current_index, next_index, stack)

      {:advance, next_index} ->
        do_extract_balanced(source, start, next_index, stack, :code)
    end
  end

  defp do_extract_balanced(source, start, index, stack, {:string, quote}) do
    char = :binary.at(source, index)

    cond do
      char == ?\\ and index + 1 < byte_size(source) ->
        do_extract_balanced(source, start, index + 2, stack, {:string, quote})

      char == quote ->
        do_extract_balanced(source, start, index + 1, stack, :code)

      true ->
        do_extract_balanced(source, start, index + 1, stack, {:string, quote})
    end
  end

  defp do_extract_balanced(source, start, index, stack, :line_comment) do
    if :binary.at(source, index) == ?\n do
      do_extract_balanced(source, start, index + 1, stack, :code)
    else
      do_extract_balanced(source, start, index + 1, stack, :line_comment)
    end
  end

  defp do_extract_balanced(source, start, index, stack, :block_comment) do
    if block_comment_terminator?(source, index) do
      do_extract_balanced(source, start, index + 2, stack, :code)
    else
      do_extract_balanced(source, start, index + 1, stack, :block_comment)
    end
  end

  defp block_comment_terminator?(source, index) do
    index + 1 < byte_size(source) and :binary.at(source, index) == ?* and
      :binary.at(source, index + 1) == ?/
  end

  defp next_balance_state(source, index, stack) do
    char = :binary.at(source, index)
    next_index = index + 1

    cond do
      quote_char?(char) ->
        {:string, next_index, char}

      line_comment_start?(source, index) ->
        {:comment, index + 2, :line}

      block_comment_start?(source, index) ->
        {:comment, index + 2, :block}

      opening_delimiter?(char) ->
        {:open, next_index, matching_closer(char)}

      stack != [] and char == hd(stack) ->
        {:close, index, next_index}

      true ->
        {:advance, next_index}
    end
  end

  defp continue_after_close(source, start, index, next_index, [_closing]) do
    {slice_binary(source, start, index - start), next_index}
  end

  defp continue_after_close(source, start, _index, next_index, [_closing | rest]) do
    do_extract_balanced(source, start, next_index, rest, :code)
  end

  defp quote_char?(char), do: char in [?', ?"]
  defp opening_delimiter?(char), do: char in [?(, ?[, ?{]

  defp line_comment_start?(source, index), do: comment_starter?(source, index, ?/)
  defp block_comment_start?(source, index), do: comment_starter?(source, index, ?*)

  defp comment_starter?(source, index, expected) do
    index + 1 < byte_size(source) and :binary.at(source, index) == ?/ and
      :binary.at(source, index + 1) == expected
  end

  defp split_top_level(text, separator), do: split_top_level(text, separator, 0, 0, [], :code, [])

  defp split_top_level(text, _separator, index, segment_start, _stack, _mode, acc)
       when index >= byte_size(text) do
    segment =
      text |> slice_binary(segment_start, byte_size(text) - segment_start) |> String.trim()

    Enum.reverse(
      if segment == "" do
        acc
      else
        [segment | acc]
      end
    )
  end

  defp split_top_level(text, separator, index, segment_start, stack, :code, acc) do
    char = :binary.at(text, index)

    cond do
      char in [?", ?'] ->
        split_top_level(text, separator, index + 1, segment_start, stack, {:string, char}, acc)

      char in [?(, ?[, ?{] ->
        split_top_level(
          text,
          separator,
          index + 1,
          segment_start,
          [matching_closer(char) | stack],
          :code,
          acc
        )

      stack != [] and char == hd(stack) ->
        split_top_level(text, separator, index + 1, segment_start, tl(stack), :code, acc)

      char == separator and stack == [] ->
        segment = text |> slice_binary(segment_start, index - segment_start) |> String.trim()

        next_acc =
          if segment == "" do
            acc
          else
            [segment | acc]
          end

        split_top_level(text, separator, index + 1, index + 1, stack, :code, next_acc)

      true ->
        split_top_level(text, separator, index + 1, segment_start, stack, :code, acc)
    end
  end

  defp split_top_level(text, separator, index, segment_start, stack, {:string, quote}, acc) do
    char = :binary.at(text, index)

    cond do
      char == ?\\ and index + 1 < byte_size(text) ->
        split_top_level(text, separator, index + 2, segment_start, stack, {:string, quote}, acc)

      char == quote ->
        split_top_level(text, separator, index + 1, segment_start, stack, :code, acc)

      true ->
        split_top_level(text, separator, index + 1, segment_start, stack, {:string, quote}, acc)
    end
  end

  defp parse_value(text) do
    text
    |> String.trim_leading()
    |> parse_prefixed_value()
  end

  defp parse_prefixed_value(<<"new Blob", _::binary>> = text), do: parse_blob(text)
  defp parse_prefixed_value(<<"new Date", _::binary>> = text), do: parse_date(text)
  defp parse_prefixed_value(<<"null", rest::binary>>), do: {nil, rest}
  defp parse_prefixed_value(<<"true", rest::binary>>), do: {true, rest}
  defp parse_prefixed_value(<<"false", rest::binary>>), do: {false, rest}
  defp parse_prefixed_value(<<"NaN", rest::binary>>), do: {{:js_special_number, :nan}, rest}

  defp parse_prefixed_value(<<"-Infinity", rest::binary>>) do
    {{:js_special_number, :negative_infinity}, rest}
  end

  defp parse_prefixed_value(<<"Infinity", rest::binary>>) do
    {{:js_special_number, :infinity}, rest}
  end

  defp parse_prefixed_value(<<"[", rest::binary>>), do: parse_array(rest, [])
  defp parse_prefixed_value(<<"{", rest::binary>>), do: parse_object(rest, [])

  defp parse_prefixed_value(<<quote, _::binary>> = text) when quote in [?', ?"],
    do: parse_string(text)

  defp parse_prefixed_value(text), do: parse_number(text)

  defp parse_blob(text) do
    rest = text |> consume("new") |> consume("Blob") |> consume("(")
    {parts, rest} = parse_value(rest)
    rest = String.trim_leading(rest)

    {opts, rest} =
      case rest do
        <<",", tail::binary>> -> parse_value(tail)
        _other -> {%{}, rest}
      end

    {{:blob, parts, opts}, consume(rest, ")")}
  end

  defp parse_date(text) do
    rest = text |> consume("new") |> consume("Date") |> consume("(")
    {milliseconds, rest} = parse_value(rest)
    {{:date_ms, milliseconds}, consume(rest, ")")}
  end

  defp parse_array(text, acc) do
    text = String.trim_leading(text)

    case text do
      <<"]", rest::binary>> ->
        {Enum.reverse(acc), rest}

      _other ->
        {value, rest} = parse_value(text)
        rest = String.trim_leading(rest)

        case rest do
          <<",", tail::binary>> -> parse_array(tail, [value | acc])
          <<"]", tail::binary>> -> {Enum.reverse([value | acc]), tail}
          _other -> raise ArgumentError, "Unsupported JS array literal: #{inspect(rest)}"
        end
    end
  end

  defp parse_object(text, acc) do
    text = String.trim_leading(text)

    case text do
      <<"}", rest::binary>> ->
        {Map.new(Enum.reverse(acc)), rest}

      _other ->
        {key, rest} = parse_object_key(text)
        rest = consume(rest, ":")
        {value, rest} = parse_value(rest)
        rest = String.trim_leading(rest)

        case rest do
          <<",", tail::binary>> -> parse_object(tail, [{key, value} | acc])
          <<"}", tail::binary>> -> {Map.new(Enum.reverse([{key, value} | acc])), tail}
          _other -> raise ArgumentError, "Unsupported JS object literal: #{inspect(rest)}"
        end
    end
  end

  defp parse_object_key(text) when is_binary(text) do
    if starts_with_quote?(text) do
      parse_string(text)
    else
      case Regex.run(~r/\A([A-Za-z_][A-Za-z0-9_]*)/u, text, capture: :all_but_first) do
        [identifier] ->
          {identifier,
           slice_binary(text, byte_size(identifier), byte_size(text) - byte_size(identifier))}

        _other ->
          raise ArgumentError, "Unsupported JS object key: #{inspect(text)}"
      end
    end
  end

  defp parse_string(<<quote, rest::binary>>) when quote in [?", ?'] do
    parse_string_chars(rest, [], quote)
  end

  defp parse_string_chars(<<quote, rest::binary>>, acc, quote), do: finish_string(rest, acc)

  defp parse_string_chars(<<"\\u", h1, h2, h3, h4, rest::binary>>, acc, quote) do
    codepoint = decode_hex_escape(h1, h2, h3, h4)
    {encoded, next_rest} = parse_unicode_escape(codepoint, rest)
    append_string_fragment(next_rest, acc, encoded, quote)
  end

  defp parse_string_chars(<<"\\", char, rest::binary>>, acc, quote) do
    append_string_fragment(rest, acc, escape_char(char), quote)
  end

  defp parse_string_chars(<<char::utf8, rest::binary>>, acc, quote) do
    append_string_fragment(rest, acc, <<char::utf8>>, quote)
  end

  defp append_string_fragment(rest, acc, fragment, quote) do
    parse_string_chars(rest, [fragment | acc], quote)
  end

  defp finish_string(rest, acc) do
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  end

  defp decode_hex_escape(h1, h2, h3, h4), do: String.to_integer(<<h1, h2, h3, h4>>, 16)

  defp parse_number(text) do
    case Regex.run(~r/\A-?(?:0|[1-9]\d*)n/u, text) do
      [match] ->
        rest = slice_binary(text, byte_size(match), byte_size(text) - byte_size(match))
        {decode_bigint(match), rest}

      _other ->
        case Regex.run(~r/\A-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/u, text) do
          [match] ->
            rest = slice_binary(text, byte_size(match), byte_size(text) - byte_size(match))
            {decode_number(match), rest}

          _other ->
            raise ArgumentError, "Unsupported JS numeric literal: #{inspect(text)}"
        end
    end
  end

  defp decode_bigint(match) do
    match
    |> String.trim_trailing("n")
    |> String.to_integer()
  end

  defp decode_number("-0"), do: -0.0

  defp decode_number(match) do
    if String.contains?(match, [".", "e", "E"]) do
      String.to_float(match)
    else
      String.to_integer(match)
    end
  end

  defp consume(text, prefix) do
    text = String.trim_leading(text)

    if String.starts_with?(text, prefix) do
      slice_binary(text, byte_size(prefix), byte_size(text) - byte_size(prefix))
    else
      raise ArgumentError, "Expected #{inspect(prefix)} in JS literal, got: #{inspect(text)}"
    end
  end

  defp escape_char(?n), do: "\n"
  defp escape_char(?r), do: "\r"
  defp escape_char(?t), do: "\t"
  defp escape_char(?f), do: "\f"
  defp escape_char(?b), do: <<8>>
  defp escape_char(?0), do: <<0>>
  defp escape_char(?'), do: "'"
  defp escape_char(?"), do: "\""
  defp escape_char(?\\), do: "\\"
  defp escape_char(?/), do: "/"
  defp escape_char(?v), do: <<11>>
  defp escape_char(char), do: <<char>>

  defp parse_unicode_escape(codepoint, <<"\\u", l1, l2, l3, l4, rest::binary>>)
       when codepoint in 0xD800..0xDBFF do
    low = String.to_integer(<<l1, l2, l3, l4>>, 16)

    if low in 0xDC00..0xDFFF do
      combined = 0x10000 + (codepoint - 0xD800) * 0x400 + (low - 0xDC00)
      {<<combined::utf8>>, rest}
    else
      {encode_js_codepoint(codepoint), <<"\\u", l1, l2, l3, l4, rest::binary>>}
    end
  end

  defp parse_unicode_escape(codepoint, rest) when codepoint in 0xD800..0xDFFF do
    {encode_js_codepoint(codepoint), rest}
  end

  defp parse_unicode_escape(codepoint, rest), do: {<<codepoint::utf8>>, rest}

  defp encode_js_codepoint(codepoint) do
    <<0xE0 ||| codepoint >>> 12, 0x80 ||| (codepoint >>> 6 &&& 0x3F),
      0x80 ||| (codepoint &&& 0x3F)>>
  end

  defp parse_integer_list(text) do
    text
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.to_integer/1)
  end

  defp maybe_parse_literal(text) do
    {:ok, parse_literal!(text)}
  rescue
    ArgumentError -> :error
  end

  defp maybe_parse_blob(source, text) do
    {:ok, source |> resolve_helper_expression!(text) |> parse_literal!()}
  rescue
    ArgumentError -> :error
  end

  defp identifier_char?(char) when char in ?a..?z, do: true
  defp identifier_char?(char) when char in ?A..?Z, do: true
  defp identifier_char?(char) when char in ?0..?9, do: true
  defp identifier_char?(?_), do: true
  defp identifier_char?(?$), do: true
  defp identifier_char?(?.), do: true
  defp identifier_char?(_char), do: false

  defp matching_closer(40), do: 41
  defp matching_closer(91), do: 93
  defp matching_closer(123), do: 125

  defp starts_with_quote?(<<quote, _rest::binary>>) when quote in [?", ?'], do: true
  defp starts_with_quote?(_text), do: false

  defp slice_binary(_text, _start, length) when length <= 0, do: ""
  defp slice_binary(text, start, length), do: :binary.part(text, start, length)
end
