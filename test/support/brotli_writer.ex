defmodule Web.TestBrotliWriter do
  @moduledoc false

  # Writes brotli streams of RFC 7932 field by field, for the tests of the
  # decoder: a test can make each header, prefix code, and command, also
  # one that is not valid.
  #
  # A stream is a list of fields `{value, bits}`, in the sequence of the
  # format. The field `:align` adds zero bits up to the next byte boundary,
  # and `{:bytes, binary}` adds bytes. `bytes/1` packs the fields, first bit
  # in the least significant position, and fills the last byte with zeros.

  import Bitwise

  @doc "Packs the fields into bytes."
  def bytes(fields) do
    {acc, used} =
      fields
      |> List.flatten()
      |> Enum.flat_map(fn
        {:bytes, data} -> for <<byte <- data>>, do: {byte, 8}
        field -> [field]
      end)
      |> Enum.reduce({0, 0}, fn
        :align, {acc, used} -> {acc, used + rem(8 - rem(used, 8), 8)}
        {value, bits}, {acc, used} -> {acc ||| value <<< used, used + bits}
      end)

    size = div(used + 7, 8) * 8
    <<acc::size(size)-little>>
  end

  @doc "WBITS, section 9.1."
  def window(16), do: [{0, 1}]
  def window(17), do: [{1, 1}, {0, 3}, {0, 3}]
  def window(wbits) when wbits >= 18, do: [{1 ||| (wbits - 17) <<< 1, 4}]
  def window(wbits), do: [{1, 1}, {0, 3}, {wbits - 8, 3}]

  @doc "ISLAST, ISLASTEMPTY, MNIBBLES, MLEN - 1, and ISUNCOMPRESSED."
  def header(last?, length, uncompressed? \\ false) do
    nibbles =
      cond do
        length - 1 < 1 <<< 16 -> 4
        length - 1 < 1 <<< 20 -> 5
        true -> 6
      end

    [
      if(last?, do: [{1, 1}, {0, 1}], else: [{0, 1}]),
      {nibbles - 4, 2},
      {length - 1, 4 * nibbles},
      if(last?, do: [], else: [{if(uncompressed?, do: 1, else: 0), 1}])
    ]
  end

  @doc "The last meta-block, empty."
  def last_empty, do: [{1, 1}, {1, 1}]

  @doc "NBLTYPES or NTREES: a value from 1 to 256."
  def count(1), do: [{0, 1}]
  def count(2), do: [{1, 1}, {0, 3}]

  def count(value) do
    bits = log2(value - 1)
    [{1, 1}, {bits, 3}, {value - 1 - (1 <<< bits), bits}]
  end

  @doc """
  The fields of a meta-block header after MLEN for one block type of each
  category, NPOSTFIX and NDIRECT, the context mode, and one prefix code for
  each alphabet. The codes are fields: see `simple/3` and `complex/2`.
  """
  def one_of_each(literal, command, distance, npostfix \\ 0, ndirect \\ 0) do
    [
      count(1),
      count(1),
      count(1),
      {npostfix, 2},
      {ndirect >>> npostfix, 4},
      {0, 2},
      count(1),
      count(1),
      literal,
      command,
      distance
    ]
  end

  @doc """
  A simple prefix code of section 3.4 for the symbols, in their sequence.
  Returns `{fields, table}`: the table has `{bits, length}` for each
  symbol.
  """
  def simple(symbols, size, select \\ 0) do
    bits = log2(size - 1) + 1
    fields = [{1, 2}, {length(symbols) - 1, 2}, for(s <- symbols, do: {s, bits})]

    {fields, lengths} =
      case symbols do
        [a] -> {fields, [{a, 0}]}
        [a, b] -> {fields, [{a, 1}, {b, 1}]}
        [a, b, c] -> {fields, [{a, 1}, {b, 2}, {c, 2}]}
        [a, b, c, d] when select == 0 -> {[fields, {0, 1}], [{a, 2}, {b, 2}, {c, 2}, {d, 2}]}
        [a, b, c, d] -> {[fields, {1, 1}], [{a, 1}, {b, 2}, {c, 3}, {d, 3}]}
      end

    {fields, table(lengths)}
  end

  @doc """
  A complex prefix code of section 3.5. `code_lengths` has `{symbol,
  length}` for the code length alphabet, and `sequence` has the code
  length symbols `{symbol, extra}`. The option `:skip` gives HSKIP, and the
  option `:all` writes the code lengths after the last that is not zero.
  """
  def complex(code_lengths, sequence, options \\ []) do
    order = [1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15]
    by_symbol = Map.new(code_lengths)
    lengths = Enum.map(order, &Map.get(by_symbol, &1, 0))
    skip = Keyword.get(options, :skip, 0)
    written = Enum.drop(lengths, skip)

    written =
      if Keyword.get(options, :all, false),
        do: written,
        else: written |> Enum.reverse() |> Enum.drop_while(&(&1 == 0)) |> Enum.reverse()

    fixed = %{0 => {0, 2}, 1 => {7, 4}, 2 => {3, 3}, 3 => {2, 2}, 4 => {1, 2}, 5 => {15, 4}}

    code =
      case code_lengths do
        [{symbol, _length}] -> %{symbol => {0, 0}}
        lengths -> table(lengths)
      end

    symbols =
      for {symbol, extra} <- sequence do
        case symbol do
          16 -> [code[16], {extra, 2}]
          17 -> [code[17], {extra, 3}]
          _length -> code[symbol]
        end
      end

    [{skip, 2}, Enum.map(written, &fixed[&1]), symbols]
  end

  @doc """
  A complex prefix code for the `{symbol, length}` pairs, with each length
  as one code length symbol, and a code length code with the same length
  for each code length symbol that it uses. Returns `{fields, table}`.
  """
  def complex(lengths) do
    by_symbol = Map.new(lengths)
    last = lengths |> Enum.map(&elem(&1, 0)) |> Enum.max()
    sequence = for symbol <- 0..last, do: {Map.get(by_symbol, symbol, 0), 0}
    used = sequence |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
    {complex(equal_code(used), sequence), table(lengths)}
  end

  # A complete code with lengths k - 1 and k for the symbols.
  defp equal_code([symbol]), do: [{symbol, 1}]

  defp equal_code(symbols) do
    k = log2(length(symbols) - 1) + 1
    short = (1 <<< k) - length(symbols)

    symbols
    |> Enum.with_index()
    |> Enum.map(fn {symbol, index} -> {symbol, if(index < short, do: k - 1, else: k)} end)
  end

  @doc "The fields of a symbol of a table."
  def symbol(table, value), do: Map.fetch!(table, value)

  @doc "The canonical codes of section 3.2, first bit in the least significant position."
  def table(lengths) do
    lengths
    |> Enum.sort_by(fn {symbol, length} -> {length, symbol} end)
    |> Enum.map_reduce({0, 0}, fn {symbol, length}, {code, previous} ->
      code = code <<< (length - previous)
      {{symbol, {reverse(code, length, 0), length}}, {code + 1, length}}
    end)
    |> elem(0)
    |> Map.new()
  end

  @doc """
  The distance code with NPOSTFIX = 0 and NDIRECT = 0 for a distance of
  16 or more, and its extra bits: `{code, {extra, bits}}`.
  """
  def distance(distance) do
    value = distance + 3
    bits = log2(value) - 1
    top = value >>> bits
    {16 + 2 * (bits - 1) + top - 2, {value - (top <<< bits), bits}}
  end

  defp reverse(_code, 0, acc), do: acc
  defp reverse(code, length, acc), do: reverse(code >>> 1, length - 1, acc <<< 1 ||| (code &&& 1))

  defp log2(value, acc \\ 0)
  defp log2(value, acc) when value <= 1, do: acc
  defp log2(value, acc), do: log2(value >>> 1, acc + 1)
end
