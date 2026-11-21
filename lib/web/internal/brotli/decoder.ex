# credo:disable-for-this-file Credo.Check.Refactor.FunctionArity
defmodule Web.Internal.Brotli.Decoder do
  @moduledoc false

  # A decoder of the brotli format of RFC 7932, in Elixir: Erlang/OTP has no
  # brotli.
  #
  # The decoder works on input in chunks of each size. It gives its output in
  # pieces: `run/2` decodes until the output has `limit` bytes, or until the
  # decoder needs more input. Thus a small input that expands much does not
  # become one large binary.
  #
  # ## Steps
  #
  # The decoder is a state machine. Each step reads a small unit of the
  # input: a part of a header, one code length, one command, or one distance.
  # A step that finds the end of the input throws `:need_more`. The decoder
  # then continues from the state before that step when more input comes.
  # Thus each step is atomic. A step writes its output only after its last
  # read. The loops that read many symbols (the literals, the code lengths,
  # and the values of a context map) keep their progress in the state. Thus
  # small chunks do not make the decoder read the same bytes again and again.
  #
  # ## The fast loop
  #
  # A unit of the commands has 117 bits at most. Thus a unit that starts
  # with at least `@safe` bytes of input cannot find the end of the input.
  # While the input has that many bytes, the fast loop decodes the commands.
  # The loop keeps the values that change in each command (the bit reader,
  # the output, the block counts, and the last distances) in the arguments
  # of its functions, not in the state map. Thus a command makes no new map
  # and no tuple for a read. The arity of these functions is thus larger
  # than the usual limit. The loop writes the values back to the state when
  # it stops.
  #
  # Each entry of a prefix code table has the value of a symbol and the
  # length of its code. For the insert-and-copy lengths, the block counts,
  # and the distances, the value is not the symbol: it has the offsets and
  # the numbers of extra bits of section 4, 5, and 6. Thus one lookup gives
  # all that a read needs.
  #
  # ## The output
  #
  # `hist` has the last bytes of the output: the sliding window, or all the
  # output when it is smaller. A reference to earlier bytes copies from it.
  # `base` is the position of its first byte in the output, and `out` is the
  # position of the first byte that `run/2` did not give. The decoder appends
  # to `hist`, and reads it with functions such as `binary_part/3` only:
  # thus the runtime appends in place, and does not copy the window for each
  # byte. A match of `hist` with a binary pattern makes the next append copy
  # all of `hist`.

  import Bitwise

  alias Web.Internal.Brotli.Dictionary

  @compile {:inline,
            entry: 2,
            push: 2,
            short_distance: 2,
            context_id: 2,
            copy_bytes: 3,
            fast_after_insert: 12,
            fast_resolve: 13}

  @safe 32

  # The sequence of the code lengths of the code length alphabet, section 3.5.
  @code_length_order {1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15}

  # The fixed code of the code length code lengths, section 3.5: the value
  # and the bit length for each value of the next 4 bits.
  @code_length_code {{0, 2}, {4, 2}, {3, 2}, {2, 3}, {0, 2}, {4, 2}, {3, 2}, {1, 4}, {0, 2},
                     {4, 2}, {3, 2}, {2, 3}, {0, 2}, {4, 2}, {3, 2}, {5, 4}}

  # The offset and the number of extra bits of each block count code
  # (section 6), insert length code, and copy length code (section 5).
  @block_count {{1, 2}, {5, 2}, {9, 2}, {13, 2}, {17, 3}, {25, 3}, {33, 3}, {41, 3}, {49, 4},
                {65, 4}, {81, 4}, {97, 4}, {113, 5}, {145, 5}, {177, 5}, {209, 5}, {241, 6},
                {305, 6}, {369, 7}, {497, 8}, {753, 9}, {1265, 10}, {2289, 11}, {4337, 12},
                {8433, 13}, {16_625, 24}}

  @insert_length {{0, 0}, {1, 0}, {2, 0}, {3, 0}, {4, 0}, {5, 0}, {6, 1}, {8, 1}, {10, 2},
                  {14, 2}, {18, 3}, {26, 3}, {34, 4}, {50, 4}, {66, 5}, {98, 5}, {130, 6},
                  {194, 7}, {322, 8}, {578, 9}, {1090, 10}, {2114, 12}, {6210, 14}, {22_594, 24}}

  @copy_length {{2, 0}, {3, 0}, {4, 0}, {5, 0}, {6, 0}, {7, 0}, {8, 0}, {9, 0}, {10, 1}, {12, 1},
                {14, 2}, {18, 2}, {22, 3}, {30, 3}, {38, 4}, {54, 4}, {70, 5}, {102, 5}, {134, 6},
                {198, 7}, {326, 8}, {582, 9}, {1094, 10}, {2118, 24}}

  # The first insert length code and the first copy length code of each
  # cell of 64 insert-and-copy length codes, in the table of section 5.
  @cells {{0, 0}, {0, 8}, {0, 0}, {0, 8}, {8, 0}, {8, 8}, {0, 16}, {16, 0}, {8, 16}, {16, 8},
          {16, 16}}

  # The value of each insert-and-copy length code: the insert offset (bits
  # 23 and up), the insert extra bits (bits 18 to 22), the copy offset (bits
  # 6 to 17), the copy extra bits (bits 1 to 5), and 1 in bit 0 for a code
  # that uses the last distance (the codes 0 to 127).
  @command_values (for code <- 0..703 do
                     {insert_code, copy_code} = elem(@cells, code >>> 6)

                     {insert_offset, insert_bits} =
                       elem(@insert_length, insert_code + (code >>> 3 &&& 7))

                     {copy_offset, copy_bits} = elem(@copy_length, copy_code + (code &&& 7))
                     implicit = if code < 128, do: 1, else: 0

                     insert_offset <<< 23 ||| insert_bits <<< 18 ||| copy_offset <<< 6 |||
                       copy_bits <<< 1 ||| implicit
                   end)
                  |> List.to_tuple()

  # The value of each block count code: the offset, and the number of extra
  # bits in the 5 low bits.
  @count_values @block_count
                |> Tuple.to_list()
                |> Enum.map(fn {offset, bits} -> offset <<< 5 ||| bits end)
                |> List.to_tuple()

  # The tables Lut0, Lut1, and Lut2 of section 7.1, for the context modes
  # UTF8 and Signed. The text has the 256 values of a table, 16 on each line.
  table = fn text ->
    text |> String.split() |> Enum.map(&String.to_integer/1) |> :binary.list_to_bin()
  end

  @lut0 table.("""
        0 0 0 0 0 0 0 0 0 4 4 0 0 4 0 0
        0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
        8 12 16 12 12 20 12 16 24 28 12 12 32 12 36 12
        44 44 44 44 44 44 44 44 44 44 32 32 24 40 28 12
        12 48 52 52 52 48 52 52 52 48 52 52 52 52 52 48
        52 52 52 52 52 48 52 52 52 52 52 24 12 28 12 12
        12 56 60 60 60 56 60 60 60 56 60 60 60 60 60 56
        60 60 60 60 60 56 60 60 60 60 60 24 12 28 12 0
        0 1 0 1 0 1 0 1 0 1 0 1 0 1 0 1
        0 1 0 1 0 1 0 1 0 1 0 1 0 1 0 1
        0 1 0 1 0 1 0 1 0 1 0 1 0 1 0 1
        0 1 0 1 0 1 0 1 0 1 0 1 0 1 0 1
        2 3 2 3 2 3 2 3 2 3 2 3 2 3 2 3
        2 3 2 3 2 3 2 3 2 3 2 3 2 3 2 3
        2 3 2 3 2 3 2 3 2 3 2 3 2 3 2 3
        2 3 2 3 2 3 2 3 2 3 2 3 2 3 2 3
        """)

  @lut1 table.("""
        0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
        0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
        0 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
        2 2 2 2 2 2 2 2 2 2 1 1 1 1 1 1
        1 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2
        2 2 2 2 2 2 2 2 2 2 2 1 1 1 1 1
        1 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3
        3 3 3 3 3 3 3 3 3 3 3 1 1 1 1 0
        0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
        0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
        0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
        0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
        0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
        0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
        2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2
        2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2
        """)

  @lut2 table.("""
        0 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
        2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2
        2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2
        2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2
        3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3
        3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3
        3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3
        3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3
        4 4 4 4 4 4 4 4 4 4 4 4 4 4 4 4
        4 4 4 4 4 4 4 4 4 4 4 4 4 4 4 4
        4 4 4 4 4 4 4 4 4 4 4 4 4 4 4 4
        4 4 4 4 4 4 4 4 4 4 4 4 4 4 4 4
        5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5
        5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5
        5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5
        6 6 6 6 6 6 6 6 6 6 6 6 6 6 6 7
        """)

  # The value of each number of `bits` bits with its bits in the reverse
  # sequence, for `bits` from 0 to 8.
  @reversed (for bits <- 0..8 do
               for value <- 0..((1 <<< bits) - 1) do
                 Enum.reduce(0..(bits - 1)//1, 0, fn bit, acc ->
                   acc ||| (value >>> bit &&& 1) <<< (bits - 1 - bit)
                 end)
               end
               |> List.to_tuple()
             end)
            |> List.to_tuple()

  # The same tables as tuples: `elem/2` reads a tuple with no function call.
  @lut0_tuple @lut0 |> :binary.bin_to_list() |> List.to_tuple()
  @lut1_tuple @lut1 |> :binary.bin_to_list() |> List.to_tuple()
  @lut2_tuple @lut2 |> :binary.bin_to_list() |> List.to_tuple()

  @doc false
  # The tables of section 7.1, for a test of their CRC-32 values.
  def __tables__, do: {@lut0, @lut1, @lut2}

  @typedoc "The state of a decoder."
  @type t :: map()

  @doc "A new decoder, before the first byte of a stream."
  @spec new() :: t()
  def new do
    %{
      step: :window,
      bits: 0,
      nbits: 0,
      bin: <<>>,
      tasks: [],
      window: 0,
      hist: <<>>,
      base: 0,
      out: 0,
      dist: {4, 11, 15, 16},
      left: 0,
      last?: false,
      ins: 0,
      clen: 0,
      implicit?: false,
      bt_l: {0, 1},
      bt_i: {0, 1},
      bt_d: {0, 1},
      blen_l: 0,
      blen_i: 0,
      blen_d: 0,
      # The prefix codes of the current block types: the literal context
      # (see `literal_contexts/1`), the code of the commands, and the four
      # codes of the distances.
      lctx: nil,
      ictx: nil,
      dctx: nil,
      mb: %{
        counts: %{},
        trees: %{},
        switch: %{},
        cmodes: {},
        cmap_l: <<>>,
        cmap_d: <<>>,
        npostfix: 0,
        ndirect: 0,
        dvalues: {},
        lit: {},
        ic: {},
        dt: {},
        lctxs: {},
        dctxs: {}
      }
    }
  end

  @doc "Adds a chunk of input."
  @spec append(t(), binary()) :: t()
  def append(%{bin: <<>>} = state, data), do: %{state | bin: data}
  def append(%{bin: bin} = state, data), do: %{state | bin: bin <> data}

  @doc """
  Decodes until the output has `limit` bytes, or until the decoder needs
  more input. Returns `{:output, piece, state}` with a piece that is not
  empty, `{:more, state}` when the decoder needs more input, `{:end, state}`
  after the end of the stream, or `{:error, :invalid}` for data that is not
  valid.
  """
  @spec run(t(), pos_integer()) ::
          {:output, binary(), t()} | {:more, t()} | {:end, t()} | {:error, :invalid}
  def run(state, limit) do
    loop(state, limit)
  catch
    :throw, {:invalid, _reason} -> {:error, :invalid}
  end

  @doc """
  The number of bytes of input after the end of the stream: data that the
  stream does not use.
  """
  @spec rest(t()) :: non_neg_integer()
  def rest(%{step: :end, nbits: nbits, bin: bin}), do: div(nbits, 8) + byte_size(bin)

  defp loop(state, limit) do
    cond do
      pending(state) >= limit ->
        output(state, limit)

      state.step == :end ->
        if pending(state) > 0, do: output(state, limit), else: {:end, state}

      true ->
        state |> advance(limit) |> next(state, limit)
    end
  end

  defp next({:ok, state}, _before, limit), do: loop(state, limit)

  defp next(:need_more, state, limit),
    do: if(pending(state) > 0, do: output(state, limit), else: {:more, state})

  defp advance(state, limit) do
    {:ok, step(state, limit)}
  catch
    :throw, :need_more -> :need_more
  end

  defp pending(%{base: base, hist: hist, out: out}), do: base + byte_size(hist) - out

  # The piece is a copy: it does not keep the window in the memory of the
  # reader. A word of the dictionary can make the output longer than the
  # limit: the next piece then has the rest.
  defp output(%{hist: hist, base: base, out: out} = state, limit) do
    size = min(base + byte_size(hist) - out, limit)
    piece = :binary.copy(binary_part(hist, out - base, size))
    {:output, piece, trim(%{state | out: out + size})}
  end

  # The window becomes a new binary only after the history grew by half of
  # the window, thus the decoder copies each byte a small number of times.
  defp trim(%{hist: hist, window: window, base: base} = state) do
    size = byte_size(hist)

    if size > window + max(div(window, 2), 65_536) do
      kept = :binary.copy(binary_part(hist, size - window, window))
      %{state | hist: kept, base: base + size - window}
    else
      state
    end
  end

  @spec invalid(String.t()) :: no_return()
  defp invalid(reason), do: throw({:invalid, reason})

  # ---------------------------------------------------------------------------
  # The bit reader
  #
  # `bits` has the next `nbits` bits of the input, the first bit in the least
  # significant position. `bin` has the rest of the input. A refill adds
  # whole bytes: thus `nbits &&& 7` bits of the current byte are not read,
  # and `bits` stays a small integer.
  # ---------------------------------------------------------------------------

  defp take(0, bits, nbits, bin), do: {0, bits, nbits, bin}

  defp take(count, bits, nbits, bin) when nbits >= count,
    do: {bits &&& (1 <<< count) - 1, bits >>> count, nbits - count, bin}

  defp take(count, bits, nbits, <<byte::32-little, rest::binary>>) when nbits <= 24,
    do: take(count, bits ||| byte <<< nbits, nbits + 32, rest)

  defp take(count, bits, nbits, <<byte, rest::binary>>),
    do: take(count, bits ||| byte <<< nbits, nbits + 8, rest)

  defp take(_count, _bits, _nbits, <<>>), do: throw(:need_more)

  # Makes at least 15 bits ready when the input has them: the longest code.
  defp peek(bits, nbits, bin) when nbits >= 15, do: {bits, nbits, bin}

  defp peek(bits, nbits, <<byte::32-little, rest::binary>>),
    do: {bits ||| byte <<< nbits, nbits + 32, rest}

  defp peek(bits, nbits, <<byte, rest::binary>>),
    do: peek(bits ||| byte <<< nbits, nbits + 8, rest)

  defp peek(bits, nbits, <<>>), do: {bits, nbits, <<>>}

  # Makes at least `need` bits ready in the fast loop, for a `need` of 24
  # or less: the caller knows that the input has the bytes. The compiler
  # makes no tuple for the result of the `if`.
  defmacrop ensure(bits, nbits, bin, need) do
    quote do
      if unquote(nbits) < unquote(need) do
        <<word::32-little, rest::binary>> = unquote(bin)
        {unquote(bits) ||| word <<< unquote(nbits), unquote(nbits) + 32, rest}
      else
        {unquote(bits), unquote(nbits), unquote(bin)}
      end
    end
  end

  # A prefix code is `{mask, root, table}`: the table has an entry for each
  # value of the next `root` bits. An entry is `value <<< 4 ||| length`, or
  # `{mask, table}` of a second table for the codes that are longer than
  # `root` bits.
  defp entry({mask, root, table}, bits) do
    case elem(table, bits &&& mask) do
      {sub_mask, sub} -> elem(sub, bits >>> root &&& sub_mask)
      entry -> entry
    end
  end

  defp decode(tree, bits, nbits, bin) do
    {bits, nbits, bin} = peek(bits, nbits, bin)
    entry = entry(tree, bits)
    length = entry &&& 15
    if length > nbits, do: throw(:need_more)
    {entry >>> 4, bits >>> length, nbits - length, bin}
  end

  defp read(%{bits: bits, nbits: nbits, bin: bin} = state, count) do
    {value, bits, nbits, bin} = take(count, bits, nbits, bin)
    {value, %{state | bits: bits, nbits: nbits, bin: bin}}
  end

  defp read_symbol(%{bits: bits, nbits: nbits, bin: bin} = state, tree) do
    {value, bits, nbits, bin} = decode(tree, bits, nbits, bin)
    {value, %{state | bits: bits, nbits: nbits, bin: bin}}
  end

  # The bits up to the next byte boundary must be zero.
  defp align(%{nbits: nbits} = state) do
    case read(state, nbits &&& 7) do
      {0, state} -> state
      {_bits, _state} -> invalid("the bits before a byte boundary are not zero")
    end
  end

  # Whole bytes, after `align/1`: at most `count`, and at least one.
  defp take_bytes(%{bits: bits, nbits: nbits} = state, count) when nbits >= 8 do
    size = min(div(nbits, 8), count) * 8
    data = <<bits &&& (1 <<< size) - 1::size(size)-little>>
    {data, %{state | bits: bits >>> size, nbits: nbits - size}}
  end

  defp take_bytes(%{bin: <<>>}, _count), do: throw(:need_more)

  defp take_bytes(%{bin: bin} = state, count) do
    size = min(byte_size(bin), count)
    {binary_part(bin, 0, size), %{state | bin: binary_part(bin, size, byte_size(bin) - size)}}
  end

  # ---------------------------------------------------------------------------
  # The prefix codes, section 3
  # ---------------------------------------------------------------------------

  # Makes the table of a canonical prefix code from `{symbol, length}` pairs.
  # The code is complete: each value of the bits has one entry. A code with
  # one symbol has a length of zero. `values` gives the value of each
  # symbol, or is `nil` when the value is the symbol.
  #
  # The canonical codes of section 3.2 come in the sequence of their bits,
  # first bit in the most significant position. Thus the entries of the
  # codes come one after the other in a table that has the bits of each
  # index in the reverse sequence. The last step puts each entry at the
  # index of the bits in the sequence of the input.
  defp build([{symbol, _length}], values), do: {0, 0, {value(values, symbol) <<< 4}}

  defp build(lengths, values) do
    sorted = Enum.sort_by(lengths, fn {symbol, length} -> length <<< 10 ||| symbol end)
    {_symbol, longest} = List.last(sorted)
    root = min(longest, 8)
    {short, long} = Enum.split_while(sorted, fn {_symbol, length} -> length <= root end)

    {entries, code, previous} =
      Enum.reduce(short, {[], 0, 0}, fn {symbol, length}, {acc, code, previous} ->
        code = code <<< (length - previous)
        entry = value(values, symbol) <<< 4 ||| length
        {repeat(entry, 1 <<< (root - length), acc), code + 1, length}
      end)

    {long, _code} =
      Enum.map_reduce(long, {code, previous}, fn {symbol, length}, {code, previous} ->
        code = code <<< (length - previous)
        {{symbol, length, code >>> (length - root)}, {code + 1, length}}
      end)

    entries =
      long
      |> Enum.chunk_by(&elem(&1, 2))
      |> Enum.reduce(entries, fn group, acc ->
        {_symbol, longest, _prefix} = List.last(group)
        bits = longest - root

        sub =
          Enum.reduce(group, [], fn {symbol, length, _prefix}, acc ->
            repeat(value(values, symbol) <<< 4 ||| length, 1 <<< (longest - length), acc)
          end)

        [{(1 <<< bits) - 1, reversed_table(sub, bits)} | acc]
      end)

    {(1 <<< root) - 1, root, reversed_table(entries, root)}
  end

  defp value(nil, symbol), do: symbol
  defp value(values, symbol), do: elem(values, symbol)

  defp repeat(_entry, 0, acc), do: acc
  defp repeat(entry, count, acc), do: repeat(entry, count - 1, [entry | acc])

  # The table of the entries in `acc`, last entry first, at the indexes with
  # the reversed bits.
  defp reversed_table(acc, bits) do
    entries = acc |> :lists.reverse() |> List.to_tuple()
    reversed = elem(@reversed, bits)
    List.to_tuple(for index <- 0..((1 <<< bits) - 1), do: elem(entries, elem(reversed, index)))
  end

  # A simple prefix code of section 3.4.
  defp simple_code(state, key, size) do
    {count, state} = read(state, 2)
    bits = size |> Kernel.-(1) |> Integer.digits(2) |> length()
    {symbols, state} = Enum.map_reduce(0..count, state, fn _index, state -> read(state, bits) end)

    if Enum.any?(symbols, &(&1 >= size)) or length(Enum.uniq(symbols)) != count + 1,
      do: invalid("a symbol of a simple prefix code is not valid")

    {lengths, state} =
      case symbols do
        [a] ->
          {[{a, 0}], state}

        [a, b] ->
          {[{a, 1}, {b, 1}], state}

        [a, b, c] ->
          {[{a, 1}, {b, 2}, {c, 2}], state}

        [a, b, c, d] ->
          case read(state, 1) do
            {0, state} -> {[{a, 2}, {b, 2}, {c, 2}, {d, 2}], state}
            {1, state} -> {[{a, 1}, {b, 2}, {c, 3}, {d, 3}], state}
          end
      end

    put_tree(state, key, lengths)
  end

  # The code lengths of the code length alphabet of a complex prefix code,
  # section 3.5. The reading stops when the code is complete.
  defp code_length_lengths(state, index, space, acc) when index < 18 do
    %{bits: bits, nbits: nbits, bin: bin} = state
    {bits, nbits, bin} = peek(bits, nbits, bin)
    {length, size} = elem(@code_length_code, bits &&& 15)
    if size > nbits, do: throw(:need_more)
    state = %{state | bits: bits >>> size, nbits: nbits - size, bin: bin}

    cond do
      length == 0 ->
        code_length_lengths(state, index + 1, space, acc)

      space - (32 >>> length) <= 0 ->
        complete_code_lengths(state, space - (32 >>> length), [
          {elem(@code_length_order, index), length} | acc
        ])

      true ->
        code_length_lengths(state, index + 1, space - (32 >>> length), [
          {elem(@code_length_order, index), length} | acc
        ])
    end
  end

  defp code_length_lengths(state, _index, space, acc),
    do: complete_code_lengths(state, space, acc)

  defp complete_code_lengths(state, space, acc) do
    if length(acc) == 1 or space == 0,
      do: {build(acc, nil), state},
      else: invalid("the code length code is not complete")
  end

  # One step of the symbol code lengths of a complex prefix code. The state
  # of the loop is in the task.
  defp code_lengths(
         {_task, key, size, _code, symbol, acc, space, _prev, _repeat, _repeat_length},
         state
       )
       when symbol >= size or space <= 0 do
    if space != 0, do: invalid("a prefix code is not complete")
    put_tree(state, key, acc)
  end

  defp code_lengths(
         {task, key, size, code, symbol, acc, space, prev, repeat, repeat_length},
         state
       ) do
    {length, state} = read_symbol(state, code)

    {next, state} =
      if length < 16 do
        if length == 0 do
          {{task, key, size, code, symbol + 1, acc, space, prev, 0, repeat_length}, state}
        else
          {{task, key, size, code, symbol + 1, [{symbol, length} | acc],
            space - (32_768 >>> length), length, 0, repeat_length}, state}
        end
      else
        extra = length - 14
        new_length = if length == 16, do: prev, else: 0

        {repeat, repeat_length} =
          if repeat_length != new_length, do: {0, new_length}, else: {repeat, repeat_length}

        {value, state} = read(state, extra)
        new_repeat = if repeat > 0, do: ((repeat - 2) <<< extra) + value + 3, else: value + 3
        delta = new_repeat - repeat
        if symbol + delta > size, do: invalid("a repeat of a code length is too long")

        {acc, space} =
          if repeat_length == 0,
            do: {acc, space},
            else:
              {Enum.reduce(symbol..(symbol + delta - 1), acc, &[{&1, repeat_length} | &2]),
               space - (delta <<< (15 - repeat_length))}

        {{task, key, size, code, symbol + delta, acc, space, prev, new_repeat, repeat_length},
         state}
      end

    continue(next, state)
  end

  # A loop continues in the same step while the input cannot end in the
  # next unit.
  defp continue(next, %{bin: bin} = state) when byte_size(bin) >= @safe, do: task(next, state)
  defp continue(next, state), do: %{state | tasks: [next | state.tasks]}

  defp put_tree(state, key, lengths) do
    tree = build(lengths, values(key, state.mb))
    put_mb(state, :trees, Map.put(state.mb.trees, key, tree))
  end

  # The values in the table of a prefix code.
  defp values({:ic, _index}, _mb), do: @command_values
  defp values({:dt, _index}, mb), do: mb.dvalues
  defp values({:count, _category}, _mb), do: @count_values
  defp values(_key, _mb), do: nil

  # The fields of a meta-block that do not change in its commands.
  defp put_mb(%{mb: mb} = state, key, value), do: %{state | mb: Map.replace!(mb, key, value)}

  # ---------------------------------------------------------------------------
  # The stream header and the meta-block header, section 9
  # ---------------------------------------------------------------------------

  # The size of the window, section 9.1. The pattern 0010001 is not valid:
  # it is the large window of RFC 9841, which is not RFC 7932.
  defp step(%{step: :window} = state, _limit) do
    {wbits, state} = window(read(state, 1))
    %{state | step: :header, window: (1 <<< wbits) - 16}
  end

  defp step(%{step: :header} = state, _limit) do
    {last, state} = read(state, 1)
    {empty, state} = if last == 1, do: read(state, 1), else: {0, state}

    if empty == 1 do
      %{state | step: :finish}
    else
      case read(state, 2) do
        {3, state} -> metadata(state, last == 1)
        {code, state} -> meta_block(state, last == 1, code + 4)
      end
    end
  end

  defp step(%{step: {:skip, 0}} = state, _limit), do: %{state | step: block_end(state)}

  defp step(%{step: {:skip, count}} = state, _limit) do
    {data, state} = take_bytes(state, count)
    %{state | step: {:skip, count - byte_size(data)}}
  end

  # An uncompressed meta-block is never the last one.
  defp step(%{step: {:raw, 0}} = state, _limit), do: %{state | step: :header}

  defp step(%{step: {:raw, count}} = state, limit) do
    {data, state} = take_bytes(state, min(count, limit - pending(state)))
    %{put_output(state, data) | step: {:raw, count - byte_size(data)}}
  end

  # The bits after the last meta-block, up to the byte boundary, must be
  # zero.
  defp step(%{step: :finish} = state, _limit), do: %{align(state) | step: :end}

  defp step(%{step: :tasks, tasks: [task | tasks]} = state, _limit),
    do: task(task, %{state | tasks: tasks})

  defp step(%{bin: bin} = state, limit) when byte_size(bin) >= @safe, do: commands(state, limit)
  defp step(%{step: :command} = state, _limit), do: command(state)
  defp step(%{step: :literals} = state, _limit), do: literal(state)
  defp step(%{step: :distance} = state, _limit), do: distance(state)
  defp step(%{step: {:copy, _count, _distance}} = state, limit), do: copy(state, limit)

  defp window({0, state}), do: {16, state}
  defp window({1, state}), do: window_bits(read(state, 3))

  defp window_bits({0, state}), do: window_short(read(state, 3))
  defp window_bits({value, state}), do: {17 + value, state}

  defp window_short({0, state}), do: {17, state}
  defp window_short({1, _state}), do: invalid("the window size is not valid")
  defp window_short({value, state}), do: {8 + value, state}

  defp block_end(%{last?: true}), do: :finish
  defp block_end(_state), do: :header

  # A meta-block with no output, and with metadata to skip.
  defp metadata(state, last?) do
    {reserved, state} = read(state, 1)
    if reserved != 0, do: invalid("the reserved bit is not zero")
    {bytes, state} = read(state, 2)
    {value, state} = read(state, 8 * bytes)

    if bytes > 1 and value >>> (8 * (bytes - 1)) == 0,
      do: invalid("the length of the metadata has a zero byte")

    count = if bytes == 0, do: 0, else: value + 1
    %{align(state) | step: {:skip, count}, last?: last?}
  end

  defp meta_block(state, last?, nibbles) do
    {value, state} = read(state, 4 * nibbles)

    if nibbles > 4 and value >>> (4 * (nibbles - 1)) == 0,
      do: invalid("the length of the meta-block has a zero nibble")

    {raw, state} = if last?, do: {0, state}, else: read(state, 1)
    state = %{state | left: value + 1, last?: last?}

    if raw == 1 do
      %{align(state) | step: {:raw, value + 1}}
    else
      tasks = [
        {:types, :l},
        {:types, :i},
        {:types, :d},
        :distance_parameters,
        {:trees_count, :l},
        {:trees_count, :d},
        :trees
      ]

      put_mb(%{state | step: :tasks, tasks: tasks}, :trees, %{})
    end
  end

  # NBLTYPES and NTREES: a value from 1 to 256.
  defp read_count(state) do
    case read(state, 1) do
      {0, state} ->
        {1, state}

      {1, state} ->
        case read(state, 3) do
          {0, state} ->
            {2, state}

          {bits, state} ->
            {extra, state} = read(state, bits)
            {(1 <<< bits) + extra + 1, state}
        end
    end
  end

  defp task({:types, category}, state) do
    {count, state} = read_count(state)
    state = put_mb(state, :counts, Map.put(state.mb.counts, category, count))
    state = put_block(state, category, {0, 1}, 1 <<< 24)

    if count >= 2 do
      tasks = [
        {:tree, {:type, category}, count + 2},
        {:tree, {:count, category}, 26},
        {:first_count, category} | state.tasks
      ]

      %{state | tasks: tasks}
    else
      state
    end
  end

  defp task({:first_count, category}, state) do
    %{bits: bits, nbits: nbits, bin: bin, mb: %{trees: trees}} = state
    tree = Map.fetch!(trees, {:count, category})
    {count, bits, nbits, bin} = block_count(tree, bits, nbits, bin)
    put_block(%{state | bits: bits, nbits: nbits, bin: bin}, category, {0, 1}, count)
  end

  defp task(:distance_parameters, state) do
    {npostfix, state} = read(state, 2)
    {ndirect, state} = read(state, 4)
    count = Map.fetch!(state.mb.counts, :l)
    {modes, state} = Enum.map_reduce(1..count, state, fn _type, state -> read(state, 2) end)
    ndirect = ndirect <<< npostfix

    mb = %{
      state.mb
      | npostfix: npostfix,
        ndirect: ndirect,
        dvalues: distance_values(npostfix, ndirect),
        cmodes: List.to_tuple(modes)
    }

    %{state | mb: mb}
  end

  defp task({:trees_count, category}, state) do
    {count, state} = read_count(state)
    size = if category == :l, do: 64 * state.mb.counts.l, else: 4 * state.mb.counts.d
    state = put_mb(state, :counts, Map.put(state.mb.counts, {:trees, category}, count))

    if count >= 2,
      do: %{state | tasks: [{:context_map, category, count, size} | state.tasks]},
      else: put_context_map(state, category, :binary.copy(<<0>>, size))
  end

  # The context map of section 7.3: RLEMAX, a prefix code, the values, and
  # the bit of the inverse move-to-front transform.
  defp task({:context_map, category, count, size}, state) do
    {rle_max, state} =
      case read(state, 1) do
        {0, state} ->
          {0, state}

        {1, state} ->
          {value, state} = read(state, 4)
          {value + 1, state}
      end

    tasks = [
      {:tree, {:map, category}, count + rle_max},
      {:map_values, category, rle_max, size, 0, []} | state.tasks
    ]

    %{state | tasks: tasks}
  end

  defp task({:map_values, category, _rle_max, size, size, acc}, state) do
    {transform, state} = read(state, 1)
    values = acc |> Enum.reverse() |> IO.iodata_to_binary()
    values = if transform == 1, do: inverse_move_to_front(values), else: values
    put_context_map(state, category, values)
  end

  defp task({:map_values, category, rle_max, size, index, acc}, state) do
    {code, state} = read_symbol(state, Map.fetch!(state.mb.trees, {:map, category}))

    {index, acc, state} =
      cond do
        code == 0 ->
          {index + 1, [0 | acc], state}

        code <= rle_max ->
          {extra, state} = read(state, code)
          repeat = (1 <<< code) + extra
          if index + repeat > size, do: invalid("a run of zeros is too long")
          {index + repeat, [:binary.copy(<<0>>, repeat) | acc], state}

        true ->
          {index + 1, [code - rle_max | acc], state}
      end

    continue({:map_values, category, rle_max, size, index, acc}, state)
  end

  # A prefix code of section 3: simple or complex.
  defp task({:tree, key, size}, state) do
    case read(state, 2) do
      {1, state} ->
        simple_code(state, key, size)

      {skip, state} ->
        {code, state} = code_length_lengths(state, skip, 32, [])
        %{state | tasks: [{:lengths, key, size, code, 0, [], 32_768, 8, 0, 0} | state.tasks]}
    end
  end

  defp task(
         {:lengths, _key, _size, _code, _symbol, _acc, _space, _prev, _repeat, _rl} = task,
         state
       ),
       do: code_lengths(task, state)

  defp task(:trees, state) do
    %{counts: counts, ndirect: ndirect, npostfix: npostfix} = state.mb
    distance_size = 16 + ndirect + (48 <<< npostfix)

    reads =
      for(index <- 1..counts[{:trees, :l}], do: {:tree, {:lit, index}, 256}) ++
        for(index <- 1..counts.i, do: {:tree, {:ic, index}, 704}) ++
        for(index <- 1..counts[{:trees, :d}], do: {:tree, {:dt, index}, distance_size})

    %{state | tasks: reads ++ [:commands | state.tasks]}
  end

  defp task(:commands, state) do
    %{counts: counts, trees: trees} = state.mb
    trees_of = fn kind, count -> List.to_tuple(for i <- 1..count, do: trees[{kind, i}]) end

    switch =
      for category <- [:l, :i, :d], counts[category] >= 2, into: %{} do
        {category, {counts[category], trees[{:type, category}], trees[{:count, category}]}}
      end

    mb = %{
      state.mb
      | lit: trees_of.(:lit, counts[{:trees, :l}]),
        ic: trees_of.(:ic, counts.i),
        dt: trees_of.(:dt, counts[{:trees, :d}]),
        switch: switch,
        trees: %{}
    }

    mb = %{mb | lctxs: literal_contexts(mb), dctxs: distance_contexts(mb)}

    %{
      state
      | mb: mb,
        step: :command,
        lctx: elem(mb.lctxs, 0),
        ictx: elem(mb.ic, 0),
        dctx: elem(mb.dctxs, 0)
    }
  end

  defp put_context_map(state, :l, map), do: put_mb(state, :cmap_l, map)
  defp put_context_map(state, :d, map), do: put_mb(state, :cmap_d, map)

  defp put_block(state, :l, types, count), do: %{state | bt_l: types, blen_l: count}
  defp put_block(state, :i, types, count), do: %{state | bt_i: types, blen_i: count}
  defp put_block(state, :d, types, count), do: %{state | bt_d: types, blen_d: count}

  defp inverse_move_to_front(values) do
    {values, _mtf} =
      for <<index <- values>>, reduce: {[], Enum.to_list(0..255)} do
        {acc, mtf} ->
          {value, mtf} = move_to_front(mtf, index, [])
          {[value | acc], mtf}
      end

    values |> Enum.reverse() |> :binary.list_to_bin()
  end

  defp move_to_front([value | rest], 0, before),
    do: {value, [value | :lists.reverse(before, rest)]}

  defp move_to_front([head | rest], index, before),
    do: move_to_front(rest, index - 1, [head | before])

  # The value of each distance code, for the entries of its prefix code. A
  # value below 16 is a code of the last distances. Each other value is 16
  # plus `base <<< 8 ||| npostfix <<< 5 ||| extra_bits`: the distance is
  # `base + (extra <<< npostfix)`, section 4.
  defp distance_values(npostfix, ndirect) do
    List.to_tuple(
      for code <- 0..(15 + ndirect + (48 <<< npostfix)) do
        cond do
          code < 16 ->
            code

          code < 16 + ndirect ->
            16 + ((code - 15) <<< 8)

          true ->
            value = code - ndirect - 16
            extra_bits = 1 + (value >>> (npostfix + 1))
            high = value >>> npostfix
            low = value &&& (1 <<< npostfix) - 1
            offset = ((2 + (high &&& 1)) <<< extra_bits) - 4
            base = (offset <<< npostfix) + low + ndirect + 1
            16 + (base <<< 8 ||| npostfix <<< 5 ||| extra_bits)
        end
      end
    )
  end

  # The literal context of each block type: `{:one, tree}` when the 64
  # contexts of the type have one prefix code, else `{mode, trees}` with
  # the tree of each context ID of section 7.1.
  defp literal_contexts(%{cmap_l: cmap, lit: lit, cmodes: modes}) do
    List.to_tuple(
      for type <- 0..(tuple_size(modes) - 1) do
        <<first, _rest::binary>> = map = binary_part(cmap, type * 64, 64)

        if map == :binary.copy(<<first>>, 64),
          do: {:one, elem(lit, first)},
          else: {elem(modes, type), List.to_tuple(for(<<index <- map>>, do: elem(lit, index)))}
      end
    )
  end

  # The four distance codes of each block type, for the copy lengths 2, 3,
  # 4, and more than 4.
  defp distance_contexts(%{cmap_d: cmap, dt: dt}) do
    List.to_tuple(
      for <<map::binary-size(4) <- cmap>> do
        List.to_tuple(for(<<index <- map>>, do: elem(dt, index)))
      end
    )
  end

  # ---------------------------------------------------------------------------
  # The fast loop of the commands, section 9.3
  #
  # The arguments of each function are the bit reader (`bits`, `nbits`,
  # `bin`), the output (`hist`), the bytes of the meta-block that come after
  # the current command (`left`), the last four distances (`dist`), the
  # block counts of the three categories (`bi`, `bl`, `bd`), and `k`: the
  # values that change only at a block switch. `k` is `{stop, ictx, lctx,
  # dctx, window, base, state}`, with the size of `hist` at which the loop
  # stops.
  #
  # A refill in the loop reads 4 bytes, with no check: a command or a
  # distance, with its block switch, makes 6 refills at most. Thus it reads
  # 24 bytes at most, and a unit starts only with `@safe` bytes. A literal
  # needs 15 bits: the loop of the literals checks the 4 bytes of each
  # refill, and stops when the input does not have them.
  # ---------------------------------------------------------------------------

  defp commands(state, limit) do
    %{bits: bits, nbits: nbits, bin: bin, hist: hist, left: left, dist: dist} = state
    %{blen_i: bi, blen_l: bl, blen_d: bd, window: window, base: base} = state
    stop = state.out - base + limit
    k = {stop, state.ictx, state.lctx, state.dctx, window, base, state}

    case state.step do
      :command ->
        fast_command(bits, nbits, bin, hist, left, dist, bi, bl, bd, k)

      :literals ->
        %{ins: insert, clen: copy, implicit?: implicit?} = state
        fast_literals(bits, nbits, bin, hist, left, dist, bi, bl, bd, k, insert, copy, implicit?)

      :distance ->
        fast_distance(bits, nbits, bin, hist, left, dist, bi, bl, bd, k, state.clen)

      {:copy, count, distance} ->
        fast_copy(bits, nbits, bin, hist, left, dist, bi, bl, bd, k, count, distance)
    end
  end

  # The loop stops before a command when the input has less than `@safe`
  # bytes, or when the output has `limit` bytes.
  defp fast_command(bits, nbits, bin, hist, left, dist, bi, bl, bd, k)
       when byte_size(bin) < @safe or byte_size(hist) >= elem(k, 0),
       do: fast_exit(:command, bits, nbits, bin, hist, left, dist, bi, bl, bd, k)

  defp fast_command(bits, nbits, bin, hist, left, dist, 0, bl, bd, k) do
    {bits, nbits, bin, bi, state} = switch(:i, bits, nbits, bin, 0, elem(k, 6))
    k = k |> put_elem(1, state.ictx) |> put_elem(6, state)
    fast_command(bits, nbits, bin, hist, left, dist, bi, bl, bd, k)
  end

  defp fast_command(bits, nbits, bin, hist, left, dist, bi, bl, bd, k) do
    {bits, nbits, bin} = ensure(bits, nbits, bin, 15)
    entry = entry(elem(k, 1), bits)
    length = entry &&& 15
    bits = bits >>> length
    nbits = nbits - length
    value = entry >>> 4

    insert_bits = value >>> 18 &&& 31
    {bits, nbits, bin} = ensure(bits, nbits, bin, insert_bits)
    insert = (value >>> 23) + (bits &&& (1 <<< insert_bits) - 1)
    bits = bits >>> insert_bits
    nbits = nbits - insert_bits

    copy_bits = value >>> 1 &&& 31
    {bits, nbits, bin} = ensure(bits, nbits, bin, copy_bits)
    copy = (value >>> 6 &&& 4095) + (bits &&& (1 <<< copy_bits) - 1)
    bits = bits >>> copy_bits
    nbits = nbits - copy_bits

    if insert > left, do: invalid("the literals are longer than the meta-block")
    implicit? = (value &&& 1) == 1
    left = left - insert
    fast_literals(bits, nbits, bin, hist, left, dist, bi - 1, bl, bd, k, insert, copy, implicit?)
  end

  # The literals of a command. The loop stops in the literals when the
  # output has `limit` bytes, or when the input ends.
  defp fast_literals(bits, nbits, bin, hist, left, dist, bi, bl, bd, k, 0, copy, implicit?),
    do: fast_after_insert(bits, nbits, bin, hist, left, dist, bi, bl, bd, k, copy, implicit?)

  defp fast_literals(bits, nbits, bin, hist, left, dist, bi, bl, bd, k, insert, copy, implicit?) do
    count = min(insert, elem(k, 0) - byte_size(hist))
    {rest, bits, nbits, bin, hist, bl, k} = literal_run(count, bits, nbits, bin, hist, bl, k)

    case insert - count + rest do
      0 ->
        fast_after_insert(bits, nbits, bin, hist, left, dist, bi, bl, bd, k, copy, implicit?)

      insert ->
        step = {:literals, insert, copy, implicit?}
        fast_exit(step, bits, nbits, bin, hist, left, dist, bi, bl, bd, k)
    end
  end

  # The copy length of the last command is not used when the literals end
  # the meta-block.
  defp fast_after_insert(bits, nbits, bin, hist, left, dist, bi, bl, bd, k, copy, implicit?) do
    cond do
      left == 0 ->
        fast_exit(block_end(elem(k, 6)), bits, nbits, bin, hist, left, dist, bi, bl, bd, k)

      implicit? ->
        distance = elem(dist, 0)
        fast_resolve(bits, nbits, bin, hist, left, dist, bi, bl, bd, k, distance, false, copy)

      true ->
        fast_distance(bits, nbits, bin, hist, left, dist, bi, bl, bd, k, copy)
    end
  end

  defp fast_distance(bits, nbits, bin, hist, left, dist, bi, bl, bd, k, copy)
       when byte_size(bin) < @safe,
       do: fast_exit({:distance, copy}, bits, nbits, bin, hist, left, dist, bi, bl, bd, k)

  defp fast_distance(bits, nbits, bin, hist, left, dist, bi, bl, 0, k, copy) do
    {bits, nbits, bin, bd, state} = switch(:d, bits, nbits, bin, 0, elem(k, 6))
    k = k |> put_elem(3, state.dctx) |> put_elem(6, state)
    fast_distance(bits, nbits, bin, hist, left, dist, bi, bl, bd, k, copy)
  end

  defp fast_distance(bits, nbits, bin, hist, left, dist, bi, bl, bd, k, copy) do
    {bits, nbits, bin} = ensure(bits, nbits, bin, 15)
    entry = entry(elem(elem(k, 3), min(copy, 5) - 2), bits)
    length = entry &&& 15
    bits = bits >>> length
    nbits = nbits - length
    value = entry >>> 4

    if value < 16 do
      distance = short_distance(value, dist)
      push? = value != 0
      fast_resolve(bits, nbits, bin, hist, left, dist, bi, bl, bd - 1, k, distance, push?, copy)
    else
      value = value - 16
      extra_bits = value &&& 31
      {bits, nbits, bin} = ensure(bits, nbits, bin, extra_bits)
      extra = bits &&& (1 <<< extra_bits) - 1
      distance = (value >>> 8) + (extra <<< (value >>> 5 &&& 7))
      bits = bits >>> extra_bits
      nbits = nbits - extra_bits
      fast_resolve(bits, nbits, bin, hist, left, dist, bi, bl, bd - 1, k, distance, true, copy)
    end
  end

  # A distance up to the window and the output is a copy of earlier output.
  # A larger distance is a word of the static dictionary, section 8.
  defp fast_resolve(bits, nbits, bin, hist, left, dist, bi, bl, bd, k, distance, push?, copy) do
    max = min(elem(k, 4), elem(k, 5) + byte_size(hist))

    cond do
      distance > max ->
        word = dictionary_word(copy, distance - max - 1, left)
        hist = <<hist::binary, word::binary>>
        left = left - byte_size(word)

        if left == 0,
          do: fast_exit(block_end(elem(k, 6)), bits, nbits, bin, hist, left, dist, bi, bl, bd, k),
          else: fast_command(bits, nbits, bin, hist, left, dist, bi, bl, bd, k)

      copy > left ->
        invalid("a copy is longer than the meta-block")

      true ->
        dist = if push?, do: push(dist, distance), else: dist
        fast_copy(bits, nbits, bin, hist, left - copy, dist, bi, bl, bd, k, copy, distance)
    end
  end

  defp fast_copy(bits, nbits, bin, hist, left, dist, bi, bl, bd, k, count, distance) do
    size = min(count, elem(k, 0) - byte_size(hist))
    hist = copy_bytes(hist, distance, size)

    cond do
      size < count ->
        step = {:copy, count - size, distance}
        fast_exit(step, bits, nbits, bin, hist, left, dist, bi, bl, bd, k)

      left == 0 ->
        fast_exit(block_end(elem(k, 6)), bits, nbits, bin, hist, left, dist, bi, bl, bd, k)

      true ->
        fast_command(bits, nbits, bin, hist, left, dist, bi, bl, bd, k)
    end
  end

  # Puts the values of the loop back in the state.
  defp fast_exit(step, bits, nbits, bin, hist, left, dist, bi, bl, bd, k) do
    state = %{
      elem(k, 6)
      | bits: bits,
        nbits: nbits,
        bin: bin,
        hist: hist,
        left: left,
        dist: dist,
        blen_i: bi,
        blen_l: bl,
        blen_d: bd
    }

    case step do
      {:literals, insert, copy, implicit?} ->
        %{state | step: :literals, ins: insert, clen: copy, implicit?: implicit?}

      {:distance, copy} ->
        %{state | step: :distance, clen: copy}

      step ->
        %{state | step: step}
    end
  end

  # Decodes `count` literals at most. Returns `{rest, bits, nbits, bin,
  # hist, bl, k}` with the number of literals that it did not decode: the
  # loop stops before a refill when the input has less than 4 bytes, and
  # before a block switch when the input has less than `@safe` bytes.
  defp literal_run(0, bits, nbits, bin, hist, bl, k), do: {0, bits, nbits, bin, hist, bl, k}

  defp literal_run(count, bits, nbits, bin, hist, 0, k) when byte_size(bin) >= @safe do
    {bits, nbits, bin, bl, state} = switch(:l, bits, nbits, bin, 0, elem(k, 6))
    k = k |> put_elem(2, state.lctx) |> put_elem(6, state)
    literal_run(count, bits, nbits, bin, hist, bl, k)
  end

  defp literal_run(count, bits, nbits, bin, hist, 0, k), do: {count, bits, nbits, bin, hist, 0, k}

  # The literals up to the end of the block: no block switch in the loop.
  defp literal_run(count, bits, nbits, bin, hist, bl, k) do
    size = min(count, bl)

    {rest, bits, nbits, bin, hist} =
      case elem(k, 2) do
        {:one, tree} -> literal_one(size, bits, nbits, bin, hist, tree)
        {0, trees} -> literal_lsb6(size, bits, nbits, bin, hist, last_two(hist), trees)
        {1, trees} -> literal_msb6(size, bits, nbits, bin, hist, last_two(hist), trees)
        {2, trees} -> literal_utf8(size, bits, nbits, bin, hist, last_two(hist), trees)
        {3, trees} -> literal_signed(size, bits, nbits, bin, hist, last_two(hist), trees)
      end

    done = size - rest

    if rest > 0,
      do: {count - done, bits, nbits, bin, hist, bl - done, k},
      else: literal_run(count - done, bits, nbits, bin, hist, bl - done, k)
  end

  # The literals of a block type with one prefix code.
  defp literal_one(count, bits, nbits, bin, hist, tree) when count > 0 and nbits >= 15 do
    entry = entry(tree, bits)
    length = entry &&& 15
    byte = entry >>> 4
    literal_one(count - 1, bits >>> length, nbits - length, bin, <<hist::binary, byte>>, tree)
  end

  defp literal_one(count, bits, nbits, <<word::32-little, rest::binary>>, hist, tree)
       when count > 0,
       do: literal_one(count, bits ||| word <<< nbits, nbits + 32, rest, hist, tree)

  defp literal_one(count, bits, nbits, bin, hist, _tree), do: {count, bits, nbits, bin, hist}

  # The literals of a block type with a prefix code for each context ID, a
  # loop for each context mode. `p` has the last two bytes: `p2 <<< 8 |||
  # p1`.
  for {name, mode} <- [literal_lsb6: 0, literal_msb6: 1, literal_utf8: 2, literal_signed: 3] do
    defp unquote(name)(count, bits, nbits, bin, hist, p, trees) when count > 0 and nbits >= 15 do
      entry = entry(elem(trees, context_id(unquote(mode), p)), bits)
      length = entry &&& 15
      byte = entry >>> 4
      hist = <<hist::binary, byte>>
      p = (p &&& 255) <<< 8 ||| byte
      unquote(name)(count - 1, bits >>> length, nbits - length, bin, hist, p, trees)
    end

    defp unquote(name)(count, bits, nbits, <<word::32-little, rest::binary>>, hist, p, trees)
         when count > 0,
         do: unquote(name)(count, bits ||| word <<< nbits, nbits + 32, rest, hist, p, trees)

    defp unquote(name)(count, bits, nbits, bin, hist, _p, _trees),
      do: {count, bits, nbits, bin, hist}
  end

  # ---------------------------------------------------------------------------
  # The commands near the end of the input, section 9.3
  #
  # When the input has less than `@safe` bytes, each step decodes one unit
  # with the reads that throw `:need_more`.
  # ---------------------------------------------------------------------------

  defp command(state) do
    %{bits: bits, nbits: nbits, bin: bin, blen_i: blen, left: left} = state
    {bits, nbits, bin, blen, state} = switch(:i, bits, nbits, bin, blen, state)
    {value, bits, nbits, bin} = decode(state.ictx, bits, nbits, bin)
    {insert_extra, bits, nbits, bin} = take(value >>> 18 &&& 31, bits, nbits, bin)
    {copy_extra, bits, nbits, bin} = take(value >>> 1 &&& 31, bits, nbits, bin)
    insert = (value >>> 23) + insert_extra
    if insert > left, do: invalid("the literals are longer than the meta-block")

    %{
      state
      | bits: bits,
        nbits: nbits,
        bin: bin,
        blen_i: blen - 1,
        ins: insert,
        clen: (value >>> 6 &&& 4095) + copy_extra,
        implicit?: (value &&& 1) == 1,
        left: left - insert,
        step: :literals
    }
  end

  defp literal(%{ins: 0} = state), do: after_insert(state)

  defp literal(state) do
    %{bits: bits, nbits: nbits, bin: bin, blen_l: blen, hist: hist, ins: insert} = state
    {bits, nbits, bin, blen, state} = switch(:l, bits, nbits, bin, blen, state)
    {byte, bits, nbits, bin} = decode(literal_tree(state.lctx, hist), bits, nbits, bin)

    state = %{
      state
      | bits: bits,
        nbits: nbits,
        bin: bin,
        hist: <<hist::binary, byte>>,
        blen_l: blen - 1,
        ins: insert - 1
    }

    if insert == 1, do: after_insert(state), else: state
  end

  defp literal_tree({:one, tree}, _hist), do: tree
  defp literal_tree({mode, trees}, hist), do: elem(trees, context_id(mode, last_two(hist)))

  # The context ID of a literal, section 7.1, for `p = p2 <<< 8 ||| p1`.
  defp context_id(0, p), do: p &&& 63
  defp context_id(1, p), do: (p &&& 255) >>> 2

  defp context_id(2, p),
    do: elem(@lut0_tuple, p &&& 255) ||| elem(@lut1_tuple, p >>> 8)

  defp context_id(3, p),
    do: elem(@lut2_tuple, p &&& 255) <<< 3 ||| elem(@lut2_tuple, p >>> 8)

  # The last two bytes of the output. A byte before the start of the stream
  # is zero.
  defp last_two(hist) when byte_size(hist) >= 2 do
    <<p::16>> = binary_part(hist, byte_size(hist) - 2, 2)
    p
  end

  defp last_two(hist), do: :binary.decode_unsigned(hist)

  # The copy length of the last command is not used when the literals end
  # the meta-block.
  defp after_insert(%{left: 0} = state), do: %{state | step: block_end(state)}

  defp after_insert(%{implicit?: true, dist: {last, _, _, _}} = state),
    do: resolve(state, last, false)

  defp after_insert(state), do: %{state | step: :distance}

  defp distance(state) do
    %{bits: bits, nbits: nbits, bin: bin, blen_d: blen, clen: copy} = state
    {bits, nbits, bin, blen, state} = switch(:d, bits, nbits, bin, blen, state)
    {value, bits, nbits, bin} = decode(elem(state.dctx, min(copy, 5) - 2), bits, nbits, bin)
    {distance, push?, bits, nbits, bin} = distance_value(value, bits, nbits, bin, state.dist)
    resolve(%{state | bits: bits, nbits: nbits, bin: bin, blen_d: blen - 1}, distance, push?)
  end

  # Section 4. The code 0 is the last distance, and does not go in the
  # ring buffer of the last distances.
  defp distance_value(value, bits, nbits, bin, dist) when value < 16,
    do: {short_distance(value, dist), value != 0, bits, nbits, bin}

  defp distance_value(value, bits, nbits, bin, _dist) do
    value = value - 16
    {extra, bits, nbits, bin} = take(value &&& 31, bits, nbits, bin)
    {(value >>> 8) + (extra <<< (value >>> 5 &&& 7)), true, bits, nbits, bin}
  end

  defp short_distance(code, {d0, d1, d2, d3}) do
    distance =
      case code do
        0 -> d0
        1 -> d1
        2 -> d2
        3 -> d3
        _ when code < 10 -> d0 + elem({-1, 1, -2, 2, -3, 3}, code - 4)
        _ -> d1 + elem({-1, 1, -2, 2, -3, 3}, code - 10)
      end

    if distance <= 0, do: invalid("a distance is not positive")
    distance
  end

  defp resolve(state, distance, push?) do
    %{hist: hist, base: base, window: window, clen: length, left: left} = state
    max = min(window, base + byte_size(hist))

    cond do
      distance > max ->
        word = dictionary_word(length, distance - max - 1, left)
        after_copy(%{put_output(state, word) | left: left - byte_size(word)})

      length > left ->
        invalid("a copy is longer than the meta-block")

      true ->
        dist = if push?, do: push(state.dist, distance), else: state.dist
        %{state | step: {:copy, length, distance}, left: left - length, dist: dist}
    end
  end

  defp dictionary_word(length, id, left) do
    word = Dictionary.word(length, id)
    if word == :error, do: invalid("a reference to the dictionary is not valid")
    if byte_size(word) > left, do: invalid("a word is longer than the meta-block")
    word
  end

  defp push({d0, d1, d2, _d3}, distance), do: {distance, d0, d1, d2}

  defp copy(%{step: {:copy, count, distance}, hist: hist} = state, limit) do
    size = min(count, limit - pending(state))

    step =
      cond do
        size < count -> {:copy, count - size, distance}
        state.left == 0 -> block_end(state)
        true -> :command
      end

    %{state | hist: copy_bytes(hist, distance, size), step: step}
  end

  # Appends `size` bytes from `distance` bytes back. A copy that is longer
  # than its distance repeats its pattern.
  defp copy_bytes(hist, distance, size) when distance >= size,
    do: <<hist::binary, binary_part(hist, byte_size(hist) - distance, size)::binary>>

  defp copy_bytes(hist, distance, size) do
    pattern = binary_part(hist, byte_size(hist) - distance, distance)
    <<hist::binary, binary_part(:binary.copy(pattern, div(size, distance) + 1), 0, size)::binary>>
  end

  defp after_copy(%{left: 0} = state), do: %{state | step: block_end(state)}
  defp after_copy(state), do: %{state | step: :command}

  defp put_output(%{hist: hist} = state, data),
    do: %{state | hist: <<hist::binary, data::binary>>}

  # ---------------------------------------------------------------------------
  # The block switch commands, section 6
  # ---------------------------------------------------------------------------

  # A block count of zero needs a block switch command: a block type and a
  # block count. The count of a category with one block type does not end
  # in a meta-block.
  defp switch(category, bits, nbits, bin, 0, state) do
    {count, type_tree, count_tree} = Map.fetch!(state.mb.switch, category)
    {current, previous} = types(state, category)
    {code, bits, nbits, bin} = decode(type_tree, bits, nbits, bin)
    {blen, bits, nbits, bin} = block_count(count_tree, bits, nbits, bin)

    type =
      case code do
        0 -> previous
        1 -> current + 1
        _ -> code - 2
      end

    type = if type >= count, do: type - count, else: type
    state = put_block(state, category, {type, current}, blen)
    {bits, nbits, bin, blen, put_codes(state, category, type)}
  end

  defp switch(_category, bits, nbits, bin, blen, state), do: {bits, nbits, bin, blen, state}

  defp types(state, :l), do: state.bt_l
  defp types(state, :i), do: state.bt_i
  defp types(state, :d), do: state.bt_d

  # The prefix codes of the new block type.
  defp put_codes(state, :l, type), do: %{state | lctx: elem(state.mb.lctxs, type)}
  defp put_codes(state, :i, type), do: %{state | ictx: elem(state.mb.ic, type)}
  defp put_codes(state, :d, type), do: %{state | dctx: elem(state.mb.dctxs, type)}

  defp block_count(tree, bits, nbits, bin) do
    {value, bits, nbits, bin} = decode(tree, bits, nbits, bin)
    {extra, bits, nbits, bin} = take(value &&& 31, bits, nbits, bin)
    {(value >>> 5) + extra, bits, nbits, bin}
  end
end
