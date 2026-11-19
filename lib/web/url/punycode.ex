defmodule Web.URL.Punycode do
  @moduledoc false

  # The "domain to ASCII" operation of the URL Standard.
  #
  # The operation is ToASCII of Unicode Technical Standard #46, with these
  # settings: CheckHyphens false, CheckBidi true, CheckJoiners true,
  # UseSTD3ASCIIRules false, Transitional_Processing false, VerifyDnsLength
  # false, and IgnoreInvalidPunycode false.
  #
  # The data tables come from the `idna` package. This module does not use
  # the `encode` function of that package, because it applies the IDNA2008
  # rules, which are not the rules of the URL Standard.

  @virama_combining_class 9
  @right_to_left_classes [~c"R", ~c"AL", ~c"AN"]
  @forbidden_domain_code_points ~r/[\x00-\x20\x7F#%\/:<>?@\[\\\]\^|]/

  @spec host_to_ascii(String.t()) :: String.t()
  def host_to_ascii(hostname) do
    case to_ascii(hostname) do
      {:ok, ascii} -> ascii
      :error -> invalid_host_text(hostname)
    end
  end

  # The text that `host_to_ascii/1` returns for a host that is not valid.
  defp invalid_host_text(hostname) do
    if String.valid?(hostname) do
      hostname |> normalize_separators() |> String.downcase()
    else
      hostname
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
    if String.valid?(hostname) do
      hostname |> normalize_separators() |> valid_text_to_ascii()
    else
      :error
    end
  end

  defp valid_text_to_ascii(normalized) do
    cond do
      normalized == "" -> {:ok, ""}
      ascii_passthrough_host?(normalized) -> {:ok, String.downcase(normalized)}
      ends_in_number?(normalized) -> :error
      true -> unicode_to_ascii(normalized)
    end
  end

  # The URL Standard permits this short procedure for an ASCII domain that
  # has no label with the prefix "xn--".
  defp ascii_passthrough_host?(hostname) do
    ascii_only? = String.match?(hostname, ~r/^[\x00-\x7F]+$/)

    no_alabels? =
      hostname
      |> String.split(".", trim: false)
      |> Enum.all?(fn label -> not String.starts_with?(String.downcase(label), "xn--") end)

    ascii_only? and no_alabels? and not String.match?(hostname, @forbidden_domain_code_points)
  end

  # A host that ends in a number is an IPv4 address, not a domain.
  defp ends_in_number?(hostname) do
    last_label =
      hostname
      |> String.trim_trailing(".")
      |> String.split(".", trim: false)
      |> List.last()

    String.match?(last_label, ~r/^[0-9]+$/)
  end

  defp unicode_to_ascii(domain) do
    with {:ok, mapped} <- map_code_points(String.to_charlist(domain), []),
         normalized when is_list(normalized) <- :unicode.characters_to_nfc_list(mapped),
         {:ok, labels} <- normalized |> split_labels([], []) |> decode_labels([]),
         true <- valid_labels?(labels),
         ascii = Enum.map_join(labels, ".", &label_to_ascii/1),
         false <- ascii == "",
         false <- String.match?(ascii, @forbidden_domain_code_points) do
      {:ok, ascii}
    else
      _ -> :error
    end
  end

  # ---------------------------------------------------------------------------
  # UTS #46 processing, step 1: map
  # ---------------------------------------------------------------------------

  defp map_code_points([], acc), do: {:ok, Enum.reverse(acc)}

  defp map_code_points([code_point | rest], acc) do
    case status(code_point) do
      :valid -> map_code_points(rest, [code_point | acc])
      {:mapped, replacement} -> map_code_points(rest, Enum.reverse(replacement, acc))
      :ignored -> map_code_points(rest, acc)
      :disallowed -> :error
    end
  end

  # A deviation character is valid, because the processing is not
  # transitional.
  defp status(code_point) do
    case :idna_mapping.uts46_map(code_point) do
      :V -> :valid
      {:D, _replacement} -> :valid
      {:M, replacement} -> {:mapped, replacement}
      :I -> :ignored
      :X -> :disallowed
    end
  rescue
    ArgumentError -> :disallowed
  end

  # ---------------------------------------------------------------------------
  # UTS #46 processing, step 3: break into labels
  # ---------------------------------------------------------------------------

  defp split_labels([], label, labels) do
    Enum.reverse([Enum.reverse(label) | labels])
  end

  defp split_labels([?. | rest], label, labels) do
    split_labels(rest, [], [Enum.reverse(label) | labels])
  end

  defp split_labels([code_point | rest], label, labels) do
    split_labels(rest, [code_point | label], labels)
  end

  # ---------------------------------------------------------------------------
  # UTS #46 processing, step 4: convert and validate
  # ---------------------------------------------------------------------------

  defp decode_labels([], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_labels([label | rest], acc) do
    case decode_label(label) do
      {:ok, decoded} -> decode_labels(rest, [decoded | acc])
      :error -> :error
    end
  end

  # A label with the prefix "xn--" must be ASCII, must contain valid Punycode,
  # and must decode to a label that has a character that is not ASCII. The
  # decoded label must be in the mapped and normalized form.
  defp decode_label([?x, ?n, ?-, ?- | encoded] = label) do
    with true <- ascii?(label),
         {:ok, decoded} <- punycode_decode(encoded),
         false <- decoded == [] or ascii?(decoded),
         true <- Enum.all?(decoded, &(status(&1) == :valid)),
         true <- :unicode.characters_to_nfc_list(decoded) == decoded do
      {:ok, decoded}
    else
      _ -> :error
    end
  end

  defp decode_label(label), do: {:ok, label}

  defp punycode_decode(encoded) do
    {:ok, :punycode.decode(encoded)}
  catch
    _kind, _reason -> :error
  end

  defp valid_labels?(labels) do
    bidi_domain? = Enum.any?(labels, &right_to_left?/1)
    Enum.all?(labels, &valid_label?(&1, bidi_domain?))
  end

  # VerifyDnsLength is false, thus an empty label is permitted.
  defp valid_label?([], _bidi_domain?), do: true

  defp valid_label?(label, bidi_domain?) do
    not match?([?x, ?n, ?-, ?- | _], label) and
      not initial_combining_mark?(label) and
      valid_joiners?(label) and
      (not bidi_domain? or valid_bidi?(label))
  end

  defp initial_combining_mark?(label) do
    :idna.check_initial_combiner(label)
    false
  catch
    _kind, _reason -> true
  end

  # The ContextJ rules of RFC 5892, appendix A.1 and A.2.
  #
  # U+200D ZERO WIDTH JOINER must follow a virama.
  #
  # U+200C ZERO WIDTH NON-JOINER must follow a virama, or it must be between
  # a character that joins to the left and a character that joins to the
  # right. Transparent characters between them have no effect.
  defp valid_joiners?(label) do
    valid_joiners?([], label)
  end

  defp valid_joiners?(_before, []), do: true

  defp valid_joiners?(before, [0x200D | rest]) do
    after_virama?(before) and valid_joiners?([0x200D | before], rest)
  end

  defp valid_joiners?(before, [0x200C | rest]) do
    (after_virama?(before) or
       (joining_type_after_transparent(before) in [~c"L", ~c"D"] and
          joining_type_after_transparent(rest) in [~c"R", ~c"D"])) and
      valid_joiners?([0x200C | before], rest)
  end

  defp valid_joiners?(before, [code_point | rest]) do
    valid_joiners?([code_point | before], rest)
  end

  # `before` has the previous code points, the nearest one first.
  defp after_virama?([previous | _]) do
    match?(%{ccc: @virama_combining_class}, :unicode_util.lookup(previous))
  end

  defp after_virama?([]), do: false

  defp joining_type_after_transparent([]), do: nil

  defp joining_type_after_transparent([code_point | rest]) do
    case joining_type(code_point) do
      ~c"T" -> joining_type_after_transparent(rest)
      type -> type
    end
  end

  # The table of the `idna` package has the explicit joining types only. The
  # Unicode Standard gives the type T (transparent) to each other character
  # with the general category Mn, Me, or Cf.
  defp joining_type(code_point) do
    case :idna_data.joining_types(code_point) do
      :undefined -> derived_joining_type(:idna_data.lookup(code_point))
      type -> type
    end
  end

  defp derived_joining_type({category, _bidi_class}) when category in [~c"Mn", ~c"Me", ~c"Cf"] do
    ~c"T"
  end

  defp derived_joining_type(_other), do: ~c"U"

  defp right_to_left?(label) do
    Enum.any?(label, &(:idna_data.bidirectional(&1) in @right_to_left_classes))
  end

  # The Bidi rule of RFC 5893, section 2. In a Bidi domain name, the rule
  # applies to each label.
  defp valid_bidi?(label) do
    :idna_bidi.check_bidi(label, true)
    true
  catch
    _kind, _reason -> false
  end

  # ---------------------------------------------------------------------------
  # UTS #46 ToASCII
  # ---------------------------------------------------------------------------

  defp label_to_ascii(label) do
    if ascii?(label) do
      List.to_string(label)
    else
      "xn--" <> List.to_string(:punycode.encode(label))
    end
  end

  defp ascii?(code_points), do: Enum.all?(code_points, &(&1 < 0x80))

  defp normalize_separators(hostname) do
    String.replace(hostname, ~r/[。．｡]/u, ".")
  end
end
