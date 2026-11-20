defmodule Web.URLPattern.ConstructorString do
  @moduledoc false

  # "Parse a constructor string" of the URL Pattern Standard ("1.6.
  # Constructor string parsing"). The result is a map of the components
  # that the string gives, with the keys of a URLPatternInit:
  # `:protocol`, `:username`, `:password`, `:hostname`, `:port`,
  # `:pathname`, `:search`, and `:hash`.

  alias Web.URLPattern.{Canonical, Compiler, Parser}

  @default_options %{delimiter: "", prefix: "", ignore_case: false}

  @doc false
  @spec parse(String.t()) :: %{optional(atom()) => String.t()}
  def parse(input) when is_binary(input) do
    tokens = input |> Parser.tokenize(:lenient) |> List.to_tuple()

    parser = %{
      input: input |> String.to_charlist() |> List.to_tuple(),
      tokens: tokens,
      result: %{},
      component_start: 0,
      index: 0,
      increment: 1,
      group_depth: 0,
      ipv6_depth: 0,
      special?: false,
      state: :init
    }

    parser = parse_loop(parser)
    result = parser.result

    if Map.has_key?(result, :hostname) and not Map.has_key?(result, :port),
      do: Map.put(result, :port, ""),
      else: result
  end

  # The loop of the Standard runs while the token index is less than the
  # size of the token list. The last token is "end", and its steps end the
  # loop or go back to an earlier token. Thus the index is always less.
  defp parse_loop(parser) do
    parser = %{parser | increment: 1}

    case token(parser, parser.index) do
      {:end, _index, _value} -> parse_end(parser)
      _token -> parser |> parse_token() |> advance() |> parse_loop()
    end
  end

  defp parse_end(%{state: :init} = parser) do
    parser = rewind(parser)

    cond do
      hash_prefix?(parser) -> change_state(parser, :hash, 1)
      search_prefix?(parser) -> change_state(parser, :search, 1)
      true -> change_state(parser, :pathname, 0)
    end
    |> advance()
    |> parse_loop()
  end

  defp parse_end(%{state: :authority} = parser) do
    parser |> rewind_and_set_state(:hostname) |> advance() |> parse_loop()
  end

  defp parse_end(parser), do: change_state(parser, :done, 0)

  defp parse_token(parser) do
    cond do
      group_open?(parser) ->
        %{parser | group_depth: parser.group_depth + 1}

      parser.group_depth > 0 and group_close?(parser) ->
        parser |> Map.update!(:group_depth, &(&1 - 1)) |> parse_state()

      parser.group_depth > 0 ->
        parser

      true ->
        parse_state(parser)
    end
  end

  defp parse_state(%{state: :init} = parser) do
    if protocol_suffix?(parser), do: rewind_and_set_state(parser, :protocol), else: parser
  end

  defp parse_state(%{state: :protocol} = parser) do
    if protocol_suffix?(parser) do
      parser = compute_special(parser)

      cond do
        next_is_authority_slashes?(parser) -> change_state(parser, :authority, 3)
        parser.special? -> change_state(parser, :authority, 1)
        true -> change_state(parser, :pathname, 1)
      end
    else
      parser
    end
  end

  defp parse_state(%{state: :authority} = parser) do
    cond do
      identity_terminator?(parser) ->
        rewind_and_set_state(parser, :username)

      pathname_start?(parser) or search_prefix?(parser) or hash_prefix?(parser) ->
        rewind_and_set_state(parser, :hostname)

      true ->
        parser
    end
  end

  defp parse_state(%{state: :username} = parser) do
    cond do
      password_prefix?(parser) -> change_state(parser, :password, 1)
      identity_terminator?(parser) -> change_state(parser, :hostname, 1)
      true -> parser
    end
  end

  defp parse_state(%{state: :password} = parser) do
    if identity_terminator?(parser), do: change_state(parser, :hostname, 1), else: parser
  end

  defp parse_state(%{state: :hostname} = parser) do
    cond do
      ipv6_open?(parser) -> %{parser | ipv6_depth: parser.ipv6_depth + 1}
      ipv6_close?(parser) -> %{parser | ipv6_depth: parser.ipv6_depth - 1}
      port_prefix?(parser) and parser.ipv6_depth == 0 -> change_state(parser, :port, 1)
      true -> after_host(parser)
    end
  end

  defp parse_state(%{state: :port} = parser), do: after_host(parser)

  defp parse_state(%{state: :pathname} = parser) do
    cond do
      search_prefix?(parser) -> change_state(parser, :search, 1)
      hash_prefix?(parser) -> change_state(parser, :hash, 1)
      true -> parser
    end
  end

  defp parse_state(%{state: :search} = parser) do
    if hash_prefix?(parser), do: change_state(parser, :hash, 1), else: parser
  end

  defp parse_state(%{state: :hash} = parser), do: parser

  # The steps of the states "hostname" and "port" after the port prefix.
  defp after_host(parser) do
    cond do
      pathname_start?(parser) -> change_state(parser, :pathname, 0)
      search_prefix?(parser) -> change_state(parser, :search, 1)
      hash_prefix?(parser) -> change_state(parser, :hash, 1)
      true -> parser
    end
  end

  defp advance(parser), do: %{parser | index: parser.index + parser.increment}

  # "Change state".
  defp change_state(parser, new_state, skip) do
    old = parser.state

    result =
      if old in [:init, :authority, :done],
        do: parser.result,
        else: Map.put(parser.result, old, component_string(parser))

    result =
      if old != :init and new_state != :done,
        do: default_components(result, old, new_state, parser.special?),
        else: result

    index = parser.index + skip

    %{
      parser
      | result: result,
        state: new_state,
        index: index,
        component_start: index,
        increment: 0
    }
  end

  defp default_components(result, old, new_state, special?) do
    result
    |> put_new_if(
      old in [:protocol, :authority, :username, :password] and
        new_state in [:port, :pathname, :search, :hash],
      :hostname,
      ""
    )
    |> put_new_if(
      old in [:protocol, :authority, :username, :password, :hostname, :port] and
        new_state in [:search, :hash],
      :pathname,
      if(special?, do: "/", else: "")
    )
    |> put_new_if(
      old in [:protocol, :authority, :username, :password, :hostname, :port, :pathname] and
        new_state == :hash,
      :search,
      ""
    )
  end

  defp put_new_if(result, true, key, value), do: Map.put_new(result, key, value)
  defp put_new_if(result, false, _key, _value), do: result

  defp rewind(parser), do: %{parser | index: parser.component_start, increment: 0}

  defp rewind_and_set_state(parser, state), do: %{rewind(parser) | state: state}

  # "Get a safe token". The Standard gives the "end" token for an index
  # after the end. Here no index is after the end: the parser examines the
  # token after a "/" only when the "/" is not the "end" token.
  defp token(parser, index), do: elem(parser.tokens, index)

  # "Is a non-special pattern char".
  defp pattern_char?(parser, index, value) do
    case token(parser, index) do
      {type, _index, ^value} -> type in [:char, :escaped_char, :invalid_char]
      _other -> false
    end
  end

  defp protocol_suffix?(parser), do: pattern_char?(parser, parser.index, ":")

  defp next_is_authority_slashes?(parser),
    do:
      pattern_char?(parser, parser.index + 1, "/") and
        pattern_char?(parser, parser.index + 2, "/")

  defp identity_terminator?(parser), do: pattern_char?(parser, parser.index, "@")
  defp password_prefix?(parser), do: pattern_char?(parser, parser.index, ":")
  defp port_prefix?(parser), do: pattern_char?(parser, parser.index, ":")
  defp pathname_start?(parser), do: pattern_char?(parser, parser.index, "/")
  defp hash_prefix?(parser), do: pattern_char?(parser, parser.index, "#")
  defp ipv6_open?(parser), do: pattern_char?(parser, parser.index, "[")
  defp ipv6_close?(parser), do: pattern_char?(parser, parser.index, "]")

  # "Is a search prefix": a "?" is also a search prefix when it is not a
  # modifier of the token before it.
  defp search_prefix?(parser) do
    cond do
      pattern_char?(parser, parser.index, "?") ->
        true

      elem(token(parser, parser.index), 2) != "?" ->
        false

      parser.index == 0 ->
        true

      true ->
        {type, _index, _value} = token(parser, parser.index - 1)
        type not in [:name, :regexp, :close, :asterisk]
    end
  end

  defp group_open?(parser), do: match?({:open, _index, _value}, elem(parser.tokens, parser.index))

  defp group_close?(parser),
    do: match?({:close, _index, _value}, elem(parser.tokens, parser.index))

  # "Make a component string".
  defp component_string(parser) do
    {_type, end_index, _value} = elem(parser.tokens, parser.index)
    {_type, start_index, _value} = token(parser, parser.component_start)

    start_index..(end_index - 1)//1
    |> Enum.map(&elem(parser.input, &1))
    |> List.to_string()
  end

  # "Compute protocol matches a special scheme flag".
  defp compute_special(parser) do
    component =
      Compiler.compile(component_string(parser), &Canonical.protocol/1, @default_options)

    if Enum.any?(~w(ftp file http https ws wss), &(Compiler.match(component, &1) != nil)),
      do: %{parser | special?: true},
      else: parser
  end
end
