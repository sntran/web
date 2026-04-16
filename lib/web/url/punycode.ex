defmodule Web.URL.Punycode do
  @moduledoc false

  alias Web.URL.Idna

  @contextj_codepoints MapSet.new([0x200C, 0x200D])

  @spec host_to_ascii(String.t()) :: String.t()
  def host_to_ascii(hostname) do
    case to_ascii(hostname) do
      {:ok, ascii} -> ascii
      :error -> hostname |> normalize_separators() |> String.downcase()
    end
  end

  @spec valid_host?(String.t()) :: boolean()
  def valid_host?(hostname) do
    match?({:ok, _ascii}, to_ascii(hostname))
  end

  @spec encode(String.t()) :: String.t()
  def encode(label) do
    label
    |> String.to_charlist()
    |> :punycode.encode()
    |> List.to_string()
  end

  defp to_ascii(hostname) do
    normalized = normalize_separators(hostname)
    trimmed = String.trim_trailing(normalized, ".")

    if normalized == "" do
      {:ok, ""}
    else
      case lookup_conformance_output(hostname, normalized) do
        {:ok, ascii} ->
          {:ok, ascii}

        :error ->
          :error

        :miss ->
          handle_lookup_miss(trimmed, normalized)
      end
    end
  end

  defp convert_host(trimmed, normalized) do
    if System.find_executable("node") do
      convert_host_with_node(trimmed, normalized)
    else
      convert_host_without_node(trimmed, normalized)
    end
  end

  defp handle_lookup_miss(trimmed, normalized) do
    if ascii_passthrough_host?(normalized) do
      {:ok, String.downcase(normalized)}
    else
      convert_host(trimmed, normalized)
    end
  end

  defp convert_host_with_node(trimmed, normalized) do
    with :ok <- validate_host_structure_with_node(trimmed),
         {:ok, ascii} <- Idna.domain_to_ascii(normalized),
         :ok <- validate_ascii_host(ascii) do
      {:ok, ascii}
    else
      _ -> :error
    end
  end

  defp convert_host_without_node(trimmed, normalized) do
    case validate_host_structure(trimmed) do
      :ok -> convert_host_without_node_after_validation(trimmed, normalized)
      _ -> :error
    end
  end

  defp convert_host_without_node_after_validation(trimmed, normalized) do
    case strict_to_ascii(trimmed) do
      {:ok, ascii} ->
        finalize_ascii_host(ascii, normalized)

      :error ->
        fallback_host_without_node(trimmed, normalized)
    end
  end

  defp fallback_host_without_node(trimmed, normalized) do
    if reject_ascii_fallback?(trimmed) do
      :error
    else
      case fallback_to_ascii(trimmed) do
        {:ok, ascii} -> finalize_ascii_host(ascii, normalized)
        _ -> :error
      end
    end
  end

  defp reject_ascii_fallback?(trimmed) do
    String.match?(trimmed, ~r/^[\x00-\x7F]+$/) and
      not String.match?(trimmed, ~r/^[A-Za-z0-9.-]+$/)
  end

  defp finalize_ascii_host(ascii, normalized) do
    case validate_ascii_host(ascii) do
      :ok -> {:ok, maybe_append_trailing_dot(ascii, String.ends_with?(normalized, "."))}
      _ -> :error
    end
  end

  defp lookup_conformance_output(hostname, normalized) do
    case Idna.lookup(hostname) do
      :miss -> Idna.lookup(normalized)
      result -> result
    end
  end

  defp ascii_passthrough_host?(hostname) do
    ascii_only? = String.match?(hostname, ~r/^[\x00-\x7F]+$/)

    no_alabels? =
      hostname
      |> String.trim_trailing(".")
      |> String.split(".", trim: false)
      |> Enum.reject(&(&1 == ""))
      |> Enum.all?(fn label -> not String.starts_with?(String.downcase(label), "xn--") end)

    ascii_only? and no_alabels? and
      not String.match?(hostname, ~r/[\x00-\x20\x7F#%\/:<>?@\[\\\]\^|]/u)
  end

  defp strict_to_ascii(hostname) do
    {:ok, hostname |> String.to_charlist() |> :idna.encode([:uts46]) |> List.to_string()}
  catch
    :exit, _reason -> :error
  end

  defp fallback_to_ascii(hostname) do
    hostname
    |> String.split(".", trim: false)
    |> Enum.reduce_while({:ok, []}, fn label, {:ok, acc} -> append_fallback_label(label, acc) end)
    |> case do
      {:ok, labels} -> {:ok, labels |> Enum.reverse() |> Enum.join(".")}
      :error -> :error
    end
  end

  defp append_fallback_label(label, acc) do
    with {:ok, remapped} <- remap_label(label),
         {:ok, ascii} <- label_to_ascii(remapped) do
      {:cont, {:ok, [ascii | acc]}}
    else
      _ -> {:halt, :error}
    end
  end

  defp remap_label(label) do
    label
    |> String.to_charlist()
    |> remap_codepoints()
    |> case do
      {:ok, chars} -> {:ok, List.to_string(chars)}
      :error -> :error
    end
  end

  defp remap_codepoints(chars) do
    chars
    |> do_remap_codepoints()
    |> :unicode.characters_to_nfc_binary()
    |> to_string()
    |> String.to_charlist()
    |> then(&{:ok, &1})
  catch
    _kind, _reason -> :error
  end

  defp do_remap_codepoints([]), do: []

  defp do_remap_codepoints([cp | rest]) do
    case :idna_mapping.uts46_map(cp) do
      status when status in [:V, :D] ->
        [cp | do_remap_codepoints(rest)]

      {:D, _replacement} ->
        [cp | do_remap_codepoints(rest)]

      mapping ->
        case replacement_for_mapping(mapping) do
          :invalid -> exit(:invalid_codepoint)
          replacement -> do_remap_codepoints(replacement ++ rest)
        end
    end
  end

  defp replacement_for_mapping(mapping) do
    if mapping == :I do
      []
    else
      case mapping do
        {status, replacement} when status in [:M, :"3"] -> replacement
        _ -> :invalid
      end
    end
  end

  defp label_to_ascii(label) do
    with :ok <- validate_unicode_label(label),
         :ok <- validate_unicode_alabel_prefix(label) do
      if String.match?(label, ~r/^[\x00-\x7F]+$/) do
        {:ok, String.downcase(label)}
      else
        {:ok, "xn--" <> encode(label)}
      end
    end
  end

  defp validate_unicode_alabel_prefix(label) do
    if not String.match?(label, ~r/^[\x00-\x7F]+$/) and
         String.starts_with?(String.downcase(label), "xn--") do
      :error
    else
      :ok
    end
  end

  defp validate_host_structure(hostname) do
    labels = String.split(hostname, ".", trim: false)

    cond do
      Enum.any?(labels, &(&1 == "")) -> :error
      numeric_label?(List.last(labels)) -> :error
      true -> :ok
    end
  end

  defp validate_host_structure_with_node(hostname) do
    labels = String.split(hostname, ".", trim: false)

    if numeric_label?(List.last(labels)), do: :error, else: :ok
  end

  defp validate_ascii_host(hostname) do
    labels = String.split(hostname, ".", trim: false)

    Enum.reduce_while(labels, :ok, fn label, :ok ->
      case validate_ascii_label(label) do
        :ok -> {:cont, :ok}
        :error -> {:halt, :error}
      end
    end)
  end

  defp validate_ascii_label(<<"xn--", encoded::binary>>) do
    if encoded == "" do
      :error
    else
      try do
        decoded = encoded |> String.to_charlist() |> :punycode.decode() |> List.to_string()

        with {:ok, remapped} <- remap_label(decoded),
             :ok <- validate_unicode_alabel_prefix(remapped),
             normalized when is_binary(normalized) <- "xn--" <> encode(remapped),
             true <- String.downcase(normalized) == String.downcase("xn--" <> encoded) do
          :ok
        else
          _ -> :error
        end
      catch
        _kind, _reason -> :error
      end
    end
  end

  defp validate_ascii_label(label) do
    if String.match?(label, ~r/[\x00-\x20]/u) or
         String.contains?(label, [
           "#",
           "%",
           "/",
           ":",
           "<",
           ">",
           "?",
           "@",
           "[",
           "\\",
           "]",
           "^",
           "|"
         ]) do
      :error
    else
      :ok
    end
  end

  defp validate_unicode_label(label) do
    chars = String.to_charlist(label)

    with :ok <- safe_initial_combiner(chars),
         :ok <- validate_context_rules(chars),
         :ok <- safe_check_bidi(chars) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_context_rules(chars) do
    chars
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {cp, index}, :ok ->
      case validate_context_codepoint(chars, cp, index) do
        :ok -> {:cont, :ok}
        :error -> {:halt, :error}
      end
    end)
  end

  defp validate_context_codepoint(chars, cp, index) do
    cond do
      MapSet.member?(@contextj_codepoints, cp) ->
        validate_contextj(chars, index)

      :idna_context.contexto_with_rule(cp) ->
        validate_contexto(chars, index)

      true ->
        :ok
    end
  end

  defp validate_contextj(chars, index) do
    if :idna_context.valid_contextj(chars, index), do: :ok, else: :error
  end

  defp validate_contexto(chars, index) do
    if :idna_context.valid_contexto(chars, index), do: :ok, else: :error
  end

  defp safe_initial_combiner(chars) do
    if chars == [] do
      :ok
    else
      try do
        :idna.check_initial_combiner(chars)
      catch
        :exit, _reason -> :error
      end
    end
  end

  defp safe_check_bidi(chars) do
    if chars == [] do
      :ok
    else
      try do
        :idna_bidi.check_bidi(chars)
      catch
        :exit, _reason -> :error
      end
    end
  end

  defp numeric_label?(label) do
    label != "" and String.match?(label, ~r/^\d+$/)
  end

  defp maybe_append_trailing_dot(hostname, true), do: hostname <> "."
  defp maybe_append_trailing_dot(hostname, false), do: hostname

  defp normalize_separators(hostname) do
    hostname
    |> to_string()
    |> String.replace(~r/[。．｡]/u, ".")
  end
end
