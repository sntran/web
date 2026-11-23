defmodule Web.Internal.Brotli.Dictionary do
  @moduledoc false

  # The static dictionary of brotli and its word transformations: RFC 7932,
  # section 8, appendix A, and appendix B.
  #
  # The bytes of the dictionary come from `dictionary.txt`, which this module
  # reads when it compiles. The bytes are one binary: a word is a part of
  # it.

  import Bitwise

  @data_file Path.join(__DIR__, "dictionary.txt")
  @external_resource @data_file

  @bytes @data_file
         |> File.read!()
         |> String.split("\n", trim: true)
         |> Enum.reject(&String.starts_with?(&1, "#"))
         |> Enum.join()
         |> Base.decode16!(case: :lower)

  # NDBITS of appendix A: the number of words of each length is
  # `1 <<< NDBITS[length]`, for a length from 4 to 24.
  @ndbits {0, 0, 0, 0, 10, 10, 11, 11, 10, 10, 10, 10, 10, 9, 9, 8, 7, 7, 8, 7, 7, 6, 6, 5, 5}

  # DOFFSET of section 8: the offset of the first word of each length.
  @doffset 0..24
           |> Enum.map_reduce(0, fn length, offset ->
             words = if length < 4, do: 0, else: 1 <<< elem(@ndbits, length)
             {offset, offset + length * words}
           end)
           |> elem(0)
           |> List.to_tuple()

  # The 121 transforms of appendix B: the prefix, the elementary transform,
  # and the suffix.
  @transforms {
    {"", :identity, ""},
    {"", :identity, " "},
    {" ", :identity, " "},
    {"", {:omit_first, 1}, ""},
    {"", :ferment_first, " "},
    {"", :identity, " the "},
    {" ", :identity, ""},
    {"s ", :identity, " "},
    {"", :identity, " of "},
    {"", :ferment_first, ""},
    {"", :identity, " and "},
    {"", {:omit_first, 2}, ""},
    {"", {:omit_last, 1}, ""},
    {", ", :identity, " "},
    {"", :identity, ", "},
    {" ", :ferment_first, " "},
    {"", :identity, " in "},
    {"", :identity, " to "},
    {"e ", :identity, " "},
    {"", :identity, "\""},
    {"", :identity, "."},
    {"", :identity, "\">"},
    {"", :identity, "\n"},
    {"", {:omit_last, 3}, ""},
    {"", :identity, "]"},
    {"", :identity, " for "},
    {"", {:omit_first, 3}, ""},
    {"", {:omit_last, 2}, ""},
    {"", :identity, " a "},
    {"", :identity, " that "},
    {" ", :ferment_first, ""},
    {"", :identity, ". "},
    {".", :identity, ""},
    {" ", :identity, ", "},
    {"", {:omit_first, 4}, ""},
    {"", :identity, " with "},
    {"", :identity, "'"},
    {"", :identity, " from "},
    {"", :identity, " by "},
    {"", {:omit_first, 5}, ""},
    {"", {:omit_first, 6}, ""},
    {" the ", :identity, ""},
    {"", {:omit_last, 4}, ""},
    {"", :identity, ". The "},
    {"", :ferment_all, ""},
    {"", :identity, " on "},
    {"", :identity, " as "},
    {"", :identity, " is "},
    {"", {:omit_last, 7}, ""},
    {"", {:omit_last, 1}, "ing "},
    {"", :identity, "\n\t"},
    {"", :identity, ":"},
    {" ", :identity, ". "},
    {"", :identity, "ed "},
    {"", {:omit_first, 9}, ""},
    {"", {:omit_first, 7}, ""},
    {"", {:omit_last, 6}, ""},
    {"", :identity, "("},
    {"", :ferment_first, ", "},
    {"", {:omit_last, 8}, ""},
    {"", :identity, " at "},
    {"", :identity, "ly "},
    {" the ", :identity, " of "},
    {"", {:omit_last, 5}, ""},
    {"", {:omit_last, 9}, ""},
    {" ", :ferment_first, ", "},
    {"", :ferment_first, "\""},
    {".", :identity, "("},
    {"", :ferment_all, " "},
    {"", :ferment_first, "\">"},
    {"", :identity, "=\""},
    {" ", :identity, "."},
    {".com/", :identity, ""},
    {" the ", :identity, " of the "},
    {"", :ferment_first, "'"},
    {"", :identity, ". This "},
    {"", :identity, ","},
    {".", :identity, " "},
    {"", :ferment_first, "("},
    {"", :ferment_first, "."},
    {"", :identity, " not "},
    {" ", :identity, "=\""},
    {"", :identity, "er "},
    {" ", :ferment_all, " "},
    {"", :identity, "al "},
    {" ", :ferment_all, ""},
    {"", :identity, "='"},
    {"", :ferment_all, "\""},
    {"", :ferment_first, ". "},
    {" ", :identity, "("},
    {"", :identity, "ful "},
    {" ", :ferment_first, ". "},
    {"", :identity, "ive "},
    {"", :identity, "less "},
    {"", :ferment_all, "'"},
    {"", :identity, "est "},
    {" ", :ferment_first, "."},
    {"", :ferment_all, "\">"},
    {" ", :identity, "='"},
    {"", :ferment_first, ","},
    {"", :identity, "ize "},
    {"", :ferment_all, "."},
    {"\xC2\xA0", :identity, ""},
    {" ", :identity, ","},
    {"", :ferment_first, "=\""},
    {"", :ferment_all, "=\""},
    {"", :identity, "ous "},
    {"", :ferment_all, ", "},
    {"", :ferment_first, "='"},
    {" ", :ferment_first, ","},
    {" ", :ferment_all, "=\""},
    {" ", :ferment_all, ", "},
    {"", :ferment_all, ","},
    {"", :ferment_all, "("},
    {"", :ferment_all, ". "},
    {" ", :ferment_all, "."},
    {"", :ferment_all, "='"},
    {" ", :ferment_all, ". "},
    {" ", :ferment_first, "=\""},
    {" ", :ferment_all, "='"},
    {" ", :ferment_first, "='"}
  }

  @doc "The bytes of the dictionary: the array DICT of appendix A."
  @spec bytes() :: binary()
  def bytes, do: @bytes

  @doc """
  The transforms of appendix B, as a list of `{prefix, transform, suffix}`.
  """
  @spec transforms() :: [{binary(), atom() | {atom(), pos_integer()}, binary()}]
  def transforms, do: Tuple.to_list(@transforms)

  @doc """
  The word of the dictionary for a copy length and a word identifier, as
  section 8 specifies. Returns `:error` for a length out of the range 4 to
  24, or a transform identifier larger than 120.
  """
  @spec word(non_neg_integer(), non_neg_integer()) :: binary() | :error
  def word(length, word_id) when length >= 4 and length <= 24 do
    bits = elem(@ndbits, length)
    transform_id = word_id >>> bits

    if transform_id < tuple_size(@transforms) do
      index = word_id &&& (1 <<< bits) - 1
      base = binary_part(@bytes, elem(@doffset, length) + index * length, length)
      {prefix, transform, suffix} = elem(@transforms, transform_id)
      <<prefix::binary, apply_transform(transform, base)::binary, suffix::binary>>
    else
      :error
    end
  end

  def word(_length, _word_id), do: :error

  defp apply_transform(:identity, word), do: word
  defp apply_transform(:ferment_first, word), do: ferment(word, <<>>, :first)
  defp apply_transform(:ferment_all, word), do: ferment(word, <<>>, :all)

  defp apply_transform({:omit_first, count}, word) when byte_size(word) < count, do: <<>>

  defp apply_transform({:omit_first, count}, word),
    do: binary_part(word, count, byte_size(word) - count)

  defp apply_transform({:omit_last, count}, word) when byte_size(word) < count, do: <<>>

  defp apply_transform({:omit_last, count}, word),
    do: binary_part(word, 0, byte_size(word) - count)

  # The function `Ferment` of section 8. A byte below 192 is ASCII: a letter
  # becomes upper case. A byte below 224 starts a sequence of two bytes, and
  # the second byte changes. A larger byte starts a sequence of three bytes,
  # and the third byte changes. A sequence that the word cuts does not
  # change.
  defp ferment(<<>>, acc, _scope), do: acc

  defp ferment(<<byte, rest::binary>>, acc, scope) when byte < 192 do
    byte = if byte >= ?a and byte <= ?z, do: bxor(byte, 32), else: byte
    continue(rest, <<acc::binary, byte>>, scope)
  end

  defp ferment(<<byte, next, rest::binary>>, acc, scope) when byte < 224,
    do: continue(rest, <<acc::binary, byte, bxor(next, 32)>>, scope)

  defp ferment(<<byte, second, third, rest::binary>>, acc, scope) when byte >= 224,
    do: continue(rest, <<acc::binary, byte, second, bxor(third, 5)>>, scope)

  defp ferment(rest, acc, _scope), do: acc <> rest

  defp continue(rest, acc, :first), do: acc <> rest
  defp continue(rest, acc, :all), do: ferment(rest, acc, :all)
end
