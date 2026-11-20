defmodule Web.Encoding.Indexes do
  @moduledoc false
  # The indexes of the multi-byte encodings of the Encoding Standard: index
  # gb18030, index gb18030 ranges, index Big5, index jis0208, index jis0212,
  # and index EUC-KR. `Web.Encoding.MultiByte` uses this module.
  #
  # The data comes from `multi_byte_indexes.txt`, which this module reads
  # when it compiles. Each index becomes one binary, with an entry of fixed
  # size for each pointer: 2 bytes for an index that has only code points of
  # the Basic Multilingual Plane, and 3 bytes for index Big5. The entry 0 is a
  # pointer with no code point: no index has the code point U+0000. Thus a
  # lookup is one match of a binary, and the module has no large map or
  # tuple.

  @data_file Path.join(__DIR__, "multi_byte_indexes.txt")
  @external_resource @data_file

  lines =
    @data_file
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.map(&String.split(&1, " "))
    |> Enum.group_by(&hd/1, &tl/1)

  # An entry of a line gives the code points of one or more pointers.
  expand = fn
    "-" ->
      [nil]

    "-" <> count ->
      List.duplicate(nil, String.to_integer(count))

    entry ->
      case String.split(entry, "+") do
        [hex] ->
          [String.to_integer(hex, 16)]

        [hex, count] ->
          first = String.to_integer(hex, 16)
          Enum.to_list(first..(first + String.to_integer(count)))
      end
  end

  # The binary of an index: `bits` bits for each pointer, from the pointer 0
  # to the last pointer of the index.
  table = fn name, bits ->
    code_points =
      for [start | entries] <- Map.fetch!(lines, name),
          {code_point, pointer} <-
            entries |> Enum.flat_map(expand) |> Enum.with_index(String.to_integer(start)),
          code_point != nil,
          into: %{},
          do: {pointer, code_point}

    last = code_points |> Map.keys() |> Enum.max()
    for pointer <- 0..last, into: <<>>, do: <<Map.get(code_points, pointer, 0)::size(bits)>>
  end

  @gb18030 table.("gb18030", 16)
  @big5 table.("big5", 24)
  @jis0208 table.("jis0208", 16)
  @jis0212 table.("jis0212", 16)
  @euc_kr table.("euc-kr", 16)

  # The pairs of index gb18030 ranges, in the sequence of their pointers.
  @ranges lines
          |> Map.fetch!("gb18030-ranges")
          |> Enum.concat()
          |> Enum.chunk_every(2)
          |> Enum.map(fn [pointer, hex] ->
            {String.to_integer(pointer), String.to_integer(hex, 16)}
          end)
          |> List.to_tuple()

  @doc "The index code point for `pointer` in index gb18030, or `nil`."
  @spec gb18030(non_neg_integer()) :: non_neg_integer() | nil
  def gb18030(pointer), do: lookup(@gb18030, pointer, 16)

  @doc "The index code point for `pointer` in index Big5, or `nil`."
  @spec big5(non_neg_integer()) :: non_neg_integer() | nil
  def big5(pointer), do: lookup(@big5, pointer, 24)

  @doc "The index code point for `pointer` in index jis0208, or `nil`."
  @spec jis0208(non_neg_integer()) :: non_neg_integer() | nil
  def jis0208(pointer), do: lookup(@jis0208, pointer, 16)

  @doc "The index code point for `pointer` in index jis0212, or `nil`."
  @spec jis0212(non_neg_integer()) :: non_neg_integer() | nil
  def jis0212(pointer), do: lookup(@jis0212, pointer, 16)

  @doc "The index code point for `pointer` in index EUC-KR, or `nil`."
  @spec euc_kr(non_neg_integer()) :: non_neg_integer() | nil
  def euc_kr(pointer), do: lookup(@euc_kr, pointer, 16)

  defp lookup(table, pointer, bits) do
    skip = pointer * div(bits, 8)

    case table do
      <<_::binary-size(^skip), code_point::size(^bits), _::binary>> when code_point != 0 ->
        code_point

      _other ->
        nil
    end
  end

  @doc """
  The index gb18030 ranges code point for `pointer`, or `nil`, as the
  Encoding Standard specifies.
  """
  @spec gb18030_ranges(non_neg_integer()) :: non_neg_integer() | nil
  def gb18030_ranges(pointer)
      when (pointer > 39_419 and pointer < 189_000) or pointer > 1_237_575,
      do: nil

  def gb18030_ranges(7457), do: 0xE7C7

  def gb18030_ranges(pointer) do
    {offset, code_point_offset} = last_range(pointer, 0, tuple_size(@ranges) - 1)
    code_point_offset + pointer - offset
  end

  # A binary search for the last pair with a pointer that is not larger than
  # `pointer`. The first pair has the pointer 0, thus the search always
  # finds a pair.
  defp last_range(_pointer, low, low), do: elem(@ranges, low)

  defp last_range(pointer, low, high) do
    middle = div(low + high + 1, 2)
    {offset, _code_point} = elem(@ranges, middle)

    if offset <= pointer,
      do: last_range(pointer, middle, high),
      else: last_range(pointer, low, middle - 1)
  end
end
