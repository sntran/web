defmodule Web.URL.IP do
  @moduledoc false

  import Bitwise

  alias Web.URL.{Encoding, Punycode}

  @default_ports %{"ftp" => "21", "http" => "80", "https" => "443", "ws" => "80", "wss" => "443"}
  @host_cache_table :web_url_host_cache
  @host_cache_owner :web_url_host_cache_owner

  @spec split_host_and_port(String.t()) :: {String.t(), String.t()}
  def split_host_and_port(host_port) do
    host_port
    |> host_port_value()
    |> split_host_port_value()
  end

  @spec normalize_host(String.t(), String.t()) :: String.t()
  def normalize_host(hostname, protocol) do
    cache_key = {protocol, hostname}

    case host_cache_get(cache_key) do
      {:ok, cached} ->
        cached

      :miss ->
        normalized = do_normalize_host(hostname, protocol)
        host_cache_put(cache_key, normalized)
        normalized
    end
  end

  @spec valid_host?(String.t(), String.t()) :: boolean()
  def valid_host?(hostname, protocol) do
    host = decoded_special_host(hostname, protocol)

    case valid_host_kind(host, protocol) do
      :empty -> true
      :file_localhost -> true
      :file_dot -> true
      :dot -> true
      :bracketed_ipv6 -> valid_bracketed_ipv6?(host)
      :ipv6 -> ipv6_address?(host)
      :domain -> valid_domain_host?(host)
    end
  end

  @spec valid_opaque_host?(String.t()) :: boolean()
  def valid_opaque_host?(hostname) do
    not String.match?(to_string(hostname), ~r/[\x00\x09\x0A\x0D\x20#\/:<>?@\[\\\]\^|]/u)
  end

  @spec normalize_opaque_host(String.t()) :: String.t()
  def normalize_opaque_host(hostname) do
    hostname
    |> to_string()
    |> do_normalize_opaque_host([])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  @spec default_port(String.t()) :: String.t() | nil
  def default_port(protocol) do
    protocol
    |> to_string()
    |> String.trim_trailing(":")
    |> String.downcase()
    |> then(&Map.get(@default_ports, &1))
  end

  defp do_normalize_host(hostname, protocol) do
    host = normalized_special_host(hostname, protocol)

    case normalize_host_kind(host, protocol) do
      :empty -> ""
      :file_localhost -> ""
      :file_dot -> ""
      :dot -> host
      :ipv6 -> normalize_ipv6(host)
      :domain -> normalize_domain_host(host)
    end
  end

  defp host_port_value(host_port) do
    host_port
    |> Encoding.strip_ascii_tab_and_newline()
    |> String.split(["/", "?", "#"], parts: 2)
    |> hd()
  end

  defp split_host_port_value("[" <> _ = value), do: split_bracketed_host_port(value)
  defp split_host_port_value(value), do: split_regular_host_port(value)

  defp split_bracketed_host_port(value) do
    case Regex.run(~r/^\[([^\]]+)\](?::(.*))?$/, value, capture: :all_but_first) do
      [host, port] -> maybe_split_ipv6_host_port(host, port, value)
      [host] -> maybe_split_ipv6_host_port(host, "", value)
      _ -> {value, ""}
    end
  end

  defp maybe_split_ipv6_host_port(host, port, value) do
    if ipv6_address?(host) do
      {host, port}
    else
      {value, ""}
    end
  end

  defp split_regular_host_port(value) do
    case String.split(value, ":", parts: 2) do
      [host] -> {host, ""}
      [host, port] -> {host, port}
    end
  end

  defp decoded_special_host(hostname, protocol) do
    hostname
    |> to_string()
    |> maybe_percent_decode_special_host(protocol)
  end

  defp normalized_special_host(hostname, protocol) do
    hostname
    |> decoded_special_host(protocol)
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
  end

  defp valid_host_kind("", _protocol), do: :empty
  defp valid_host_kind(host, "file:") when host in [".", ".."], do: :file_dot

  defp valid_host_kind(host, "file:") do
    if file_localhost?(host), do: :file_localhost, else: valid_non_file_host_kind(host)
  end

  defp valid_host_kind(host, _protocol), do: valid_non_file_host_kind(host)

  defp valid_non_file_host_kind(host) when host in [".", ".."], do: :dot

  defp valid_non_file_host_kind(host) do
    cond do
      String.starts_with?(host, "[") and String.ends_with?(host, "]") -> :bracketed_ipv6
      String.contains?(host, ":") -> :ipv6
      true -> :domain
    end
  end

  defp normalize_host_kind("", _protocol), do: :empty
  defp normalize_host_kind(host, "file:") when host in [".", ".."], do: :file_dot

  defp normalize_host_kind(host, "file:") do
    if file_localhost?(host), do: :file_localhost, else: normalize_non_file_host_kind(host)
  end

  defp normalize_host_kind(host, _protocol), do: normalize_non_file_host_kind(host)

  defp normalize_non_file_host_kind(host) when host in [".", ".."], do: :dot

  defp normalize_non_file_host_kind(host) do
    if String.contains?(host, ":"), do: :ipv6, else: :domain
  end

  defp valid_bracketed_ipv6?(host) do
    host
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> ipv6_address?()
  end

  defp valid_domain_host?(host) do
    not String.match?(host, ~r/[\x00\x09\x0A\x0D\x20#%\/:?@\[\\\]]/u) and
      (normalize_ipv4(host) != nil or
         (not numeric_ipv4_candidate?(host) and Punycode.valid_host?(host)))
  end

  defp normalize_domain_host(host) do
    ascii_host = Punycode.host_to_ascii(host)

    normalize_ipv4(host) ||
      if(numeric_ipv4_candidate?(host),
        do: host,
        else: normalize_ipv4(ascii_host) || ascii_host
      )
  end

  defp do_normalize_opaque_host("", acc), do: acc

  defp do_normalize_opaque_host(<<"%", a::utf8, b::utf8, rest::binary>>, acc)
       when a in ?0..?9 or a in ?a..?f or a in ?A..?F do
    do_normalize_opaque_host(rest, [<<"%", a::utf8, b::utf8>> | acc])
  end

  defp do_normalize_opaque_host(<<char::utf8, rest::binary>>, acc)
       when char <= 0x20 or char == 0x7F or char > 0x7F do
    encoded =
      <<char::utf8>>
      |> :binary.bin_to_list()
      |> Enum.map_join("", fn byte ->
        "%" <> String.upcase(Integer.to_string(byte, 16) |> String.pad_leading(2, "0"))
      end)

    do_normalize_opaque_host(rest, [encoded | acc])
  end

  defp do_normalize_opaque_host(<<char::utf8, rest::binary>>, acc) do
    do_normalize_opaque_host(rest, [<<char::utf8>> | acc])
  end

  defp normalize_ipv6(host) do
    case :inet.parse_ipv6strict_address(String.to_charlist(host)) do
      {:ok, ipv6} -> ipv6 |> Tuple.to_list() |> serialize_ipv6()
      _ -> String.downcase(host)
    end
  end

  defp normalize_ipv4(host) do
    parts = host |> String.split(".", trim: false) |> trim_single_trailing_empty_ipv4_part()

    with true <- parts != [] and length(parts) <= 4,
         true <- Enum.all?(parts, &(&1 != "")),
         {:ok, numbers} <- parse_ipv4_numbers(parts),
         true <- valid_ipv4_number_list?(numbers),
         integer when is_integer(integer) <- ipv4_numbers_to_integer(numbers) do
      <<a::8, b::8, c::8, d::8>> = <<integer::32>>
      "#{a}.#{b}.#{c}.#{d}"
    else
      _ -> nil
    end
  end

  defp parse_ipv4_numbers(parts) do
    parts
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case parse_ipv4_part(part) do
        {:ok, num} -> {:cont, {:ok, [num | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      :error -> :error
    end
  end

  defp parse_ipv4_part(part) do
    cond do
      Regex.match?(~r/^0[xX][0-9A-Fa-f]*$/, part) ->
        digits = String.slice(part, 2..-1//1)

        if digits == "" do
          {:ok, 0}
        else
          {int, ""} = Integer.parse(digits, 16)
          {:ok, int}
        end

      String.length(part) > 1 and String.starts_with?(part, "0") ->
        if Regex.match?(~r/^[0-7]+$/, part) do
          {int, ""} = Integer.parse(part, 8)
          {:ok, int}
        else
          :error
        end

      Regex.match?(~r/^\d+$/, part) ->
        {int, ""} = Integer.parse(part, 10)
        {:ok, int}

      true ->
        :error
    end
  end

  defp valid_ipv4_number_list?(numbers) do
    last_index = length(numbers) - 1

    Enum.with_index(numbers)
    |> Enum.all?(fn {part, idx} ->
      if idx < last_index do
        part <= 255
      else
        max_last = trunc(:math.pow(256, 5 - length(numbers))) - 1
        part <= max_last
      end
    end)
  end

  defp ipv4_numbers_to_integer(numbers) do
    last = List.last(numbers)

    prefix =
      numbers
      |> Enum.drop(-1)
      |> Enum.with_index()
      |> Enum.reduce(0, fn {part, idx}, acc ->
        acc + (part <<< (8 * (3 - idx)))
      end)

    prefix + last
  end

  defp serialize_ipv6(segments) do
    {run_start, run_length} = longest_zero_run(segments)

    if run_length >= 2 do
      left = segments |> Enum.take(run_start) |> Enum.map_join(":", &hex_segment/1)

      right =
        segments
        |> Enum.drop(run_start + run_length)
        |> Enum.map_join(":", &hex_segment/1)

      cond do
        left == "" and right == "" -> "::"
        left == "" -> "::" <> right
        right == "" -> left <> "::"
        true -> left <> "::" <> right
      end
    else
      Enum.map_join(segments, ":", &hex_segment/1)
    end
  end

  defp longest_zero_run(segments) do
    segments
    |> Enum.with_index()
    |> Enum.reduce({0, 0, nil, 0}, fn {segment, index},
                                      {best_start, best_len, current_start, current_len} ->
      cond do
        segment == 0 and is_nil(current_start) ->
          {best_start, best_len, index, 1}

        segment == 0 ->
          {best_start, best_len, current_start, current_len + 1}

        current_len > best_len ->
          {current_start, current_len, nil, 0}

        true ->
          {best_start, best_len, nil, 0}
      end
    end)
    |> case do
      {_best_start, best_len, current_start, current_len} when current_len > best_len ->
        {current_start, current_len}

      {best_start, best_len, _current_start, _current_len} ->
        {best_start, best_len}
    end
  end

  defp hex_segment(segment) do
    segment
    |> Integer.to_string(16)
    |> String.downcase()
  end

  defp numeric_ipv4_candidate?(host) do
    host
    |> String.split(".", trim: false)
    |> trim_single_trailing_empty_ipv4_part()
    |> List.last()
    |> Kernel.||("")
    |> case do
      "" ->
        false

      label ->
        String.match?(label, ~r/^\d+$/) or match?({:ok, _}, parse_ipv4_part(label))
    end
  end

  defp trim_single_trailing_empty_ipv4_part(parts) do
    if List.last(parts) == "" and length(parts) > 1 do
      Enum.drop(parts, -1)
    else
      parts
    end
  end

  defp file_localhost?(host) do
    decoded = maybe_percent_decode_special_host(host, "file:")

    if is_binary(decoded) and String.valid?(decoded) do
      ascii = Punycode.host_to_ascii(decoded)

      String.downcase(decoded) == "localhost" or
        (is_binary(ascii) and String.valid?(ascii) and String.downcase(ascii) == "localhost")
    else
      false
    end
  end

  defp maybe_percent_decode_special_host(host, protocol) do
    if special_protocol?(protocol) and is_binary(host) and String.valid?(host) do
      URI.decode(host)
    else
      host
    end
  end

  defp special_protocol?(protocol) do
    protocol == "file:" or Map.has_key?(@default_ports, String.trim_trailing(protocol, ":"))
  end

  defp host_cache_get(key) do
    table = ensure_host_cache_table!()

    case :ets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :miss
    end
  end

  defp host_cache_put(key, value) do
    table = ensure_host_cache_table!()

    true = :ets.insert(table, {key, value})

    value
  end

  defp ensure_host_cache_table! do
    case :ets.whereis(@host_cache_table) do
      :undefined ->
        :global.trans(
          {__MODULE__, @host_cache_table},
          &ensure_host_cache_table_inside_transaction/0
        )

      table ->
        table
    end
  end

  defp ensure_host_cache_table_inside_transaction do
    case :ets.whereis(@host_cache_table) do
      :undefined ->
        start_host_cache_owner!()
        @host_cache_table

      table ->
        table
    end
  end

  defp start_host_cache_owner! do
    if is_nil(Process.whereis(@host_cache_owner)) do
      _ =
        Agent.start(
          fn ->
            :ets.new(@host_cache_table, [:named_table, :set, :public, read_concurrency: true])
          end,
          name: @host_cache_owner
        )
    end

    :ok
  end

  defp ipv6_address?(host) do
    match?({:ok, _}, :inet.parse_ipv6strict_address(String.to_charlist(host)))
  end
end
