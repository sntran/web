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
  # A unit of the commands has 117 bits at most. Thus a step that has at
  # least `@safe` bytes of input cannot find the end of the input. While the
  # input has that many bytes, the loop of the commands and of the literals
  # does many units in one step.
  #
  # ## The output
  #
  # `hist` has the last bytes of the output: the sliding window, or all the
  # output when it is smaller. A reference to earlier bytes copies from it.
  # `base` is the position of its first byte in the output, and `out` is the
  # position of the first byte that `run/2` did not give. The decoder appends
  # to `hist` and reads it with `binary_part/3` only: thus the runtime
  # appends in place, and does not copy the window for each byte.

  import Bitwise

  alias Web.Internal.Brotli.Dictionary

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
      p1: 0,
      p2: 0,
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
      lctx: nil,
      mb: %{
        counts: %{},
        trees: %{},
        switch: %{},
        cmodes: {},
        cmap_l: <<>>,
        cmap_d: <<>>,
        npostfix: 0,
        ndirect: 0,
        lit: {},
        ic: {},
        dt: {}
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
        output(state)

      state.step == :end ->
        if pending(state) > 0, do: output(state), else: {:end, state}

      true ->
        state |> advance(limit) |> next(state, limit)
    end
  end

  defp next({:ok, state}, _before, limit), do: loop(state, limit)

  defp next(:need_more, state, _limit),
    do: if(pending(state) > 0, do: output(state), else: {:more, state})

  defp advance(state, limit) do
    {:ok, step(state, limit)}
  catch
    :throw, :need_more -> :need_more
  end

  defp pending(%{base: base, hist: hist, out: out}), do: base + byte_size(hist) - out

  # The piece is a copy: it does not keep the window in the memory of the
  # reader.
  defp output(%{hist: hist, base: base, out: out} = state) do
    total = base + byte_size(hist)
    piece = :binary.copy(binary_part(hist, out - base, total - out))
    {:output, piece, trim(%{state | out: total})}
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

  # A prefix code is `{mask, root, table}`: the table has an entry for each
  # value of the next `root` bits. An entry is `symbol <<< 4 ||| length`, or
  # `{mask, table}` of a second table for the codes that are longer than
  # `root` bits.
  defp decode({mask, root, table}, bits, nbits, bin) do
    {bits, nbits, bin} = peek(bits, nbits, bin)

    entry =
      case elem(table, bits &&& mask) do
        {sub_mask, sub} -> elem(sub, bits >>> root &&& sub_mask)
        entry -> entry
      end

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
  # one symbol has a length of zero.
  defp build([{symbol, _length}]), do: {0, 0, {symbol <<< 4}}

  defp build(lengths) do
    codes = canonical(lengths)
    root = codes |> Enum.map(&elem(&1, 1)) |> Enum.max() |> min(8)
    {short, long} = Enum.split_with(codes, fn {_symbol, length, _code} -> length <= root end)

    entries =
      for {symbol, length, code} <- short,
          step <- 0..((1 <<< (root - length)) - 1),
          do: {code ||| step <<< length, symbol <<< 4 ||| length}

    subtables =
      long
      |> Enum.group_by(fn {_symbol, _length, code} -> code &&& (1 <<< root) - 1 end)
      |> Enum.map(fn {prefix, group} ->
        bits = (group |> Enum.map(&elem(&1, 1)) |> Enum.max()) - root

        sub =
          for {symbol, length, code} <- group,
              step <- 0..((1 <<< (bits - length + root)) - 1),
              do: {code >>> root ||| step <<< (length - root), symbol <<< 4 ||| length}

        {prefix, {(1 <<< bits) - 1, table(sub)}}
      end)

    {(1 <<< root) - 1, root, table(entries ++ subtables)}
  end

  defp table(entries), do: entries |> List.keysort(0) |> Enum.map(&elem(&1, 1)) |> List.to_tuple()

  # The codes of section 3.2, with the bits in the sequence of the input:
  # the first bit of a code is the least significant bit.
  defp canonical(lengths) do
    lengths
    |> Enum.sort_by(fn {symbol, length} -> {length, symbol} end)
    |> Enum.map_reduce({0, 0}, fn {symbol, length}, {code, previous} ->
      code = code <<< (length - previous)
      {{symbol, length, reverse(code, length, 0)}, {code + 1, length}}
    end)
    |> elem(0)
  end

  defp reverse(_code, 0, acc), do: acc
  defp reverse(code, length, acc), do: reverse(code >>> 1, length - 1, acc <<< 1 ||| (code &&& 1))

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

    put_tree(state, key, build(lengths))
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
      do: {build(acc), state},
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
    put_tree(state, key, build(acc))
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

  defp put_tree(state, key, tree), do: put_mb(state, :trees, Map.put(state.mb.trees, key, tree))

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

  defp step(%{step: {:copy, _count, _distance}} = state, limit), do: copy(state, limit)

  defp step(%{bin: bin} = state, limit) when byte_size(bin) >= @safe, do: commands(state, limit)
  defp step(%{step: :command} = state, _limit), do: command(state)
  defp step(%{step: :literals} = state, limit), do: literals(state, limit)
  defp step(%{step: :distance} = state, _limit), do: distance(state)

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

    mb = %{
      state.mb
      | npostfix: npostfix,
        ndirect: ndirect <<< npostfix,
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

    state = %{state | mb: mb, step: :command}

    %{state | lctx: literal_context(state, 0)}
  end

  defp put_context_map(state, :l, map), do: put_mb(state, :cmap_l, map)
  defp put_context_map(state, :d, map), do: put_mb(state, :cmap_d, map)

  defp put_block(state, :l, types, count), do: %{state | bt_l: types, blen_l: count}
  defp put_block(state, :i, types, count), do: %{state | bt_i: types, blen_i: count}
  defp put_block(state, :d, types, count), do: %{state | bt_d: types, blen_d: count}

  defp inverse_move_to_front(values) do
    {values, _mtf} =
      values
      |> :binary.bin_to_list()
      |> Enum.map_reduce(Enum.to_list(0..255), fn index, mtf ->
        value = Enum.at(mtf, index)
        {value, [value | List.delete_at(mtf, index)]}
      end)

    :binary.list_to_bin(values)
  end

  # ---------------------------------------------------------------------------
  # The commands, section 9.3
  # ---------------------------------------------------------------------------

  # Many units in one step, while the input has `@safe` bytes before each
  # unit: no unit throws.
  defp commands(state, limit), do: commands(state, limit, state.out - state.base + limit)

  # The loop stops when the history has `stop` bytes: then the output has
  # `limit` bytes.
  defp commands(%{bin: bin, hist: hist} = state, limit, stop)
       when byte_size(bin) >= @safe and byte_size(hist) < stop do
    case state.step do
      :command -> commands(command(state), limit, stop)
      :literals -> commands(literals(state, limit), limit, stop)
      :distance -> commands(distance(state), limit, stop)
      {:copy, _count, _distance} -> commands(copy(state, limit), limit, stop)
      _other -> state
    end
  end

  defp commands(state, _limit, _stop), do: state

  defp command(state) do
    %{bits: bits, nbits: nbits, bin: bin, blen_i: blen} = state
    {bits, nbits, bin, blen, state} = switch(:i, bits, nbits, bin, blen, state)
    {type, _previous} = state.bt_i
    {code, bits, nbits, bin} = decode(elem(state.mb.ic, type), bits, nbits, bin)
    {insert_code, copy_code} = elem(@cells, code >>> 6)
    {insert_offset, insert_bits} = elem(@insert_length, insert_code + (code >>> 3 &&& 7))
    {copy_offset, copy_bits} = elem(@copy_length, copy_code + (code &&& 7))
    {insert_extra, bits, nbits, bin} = take(insert_bits, bits, nbits, bin)
    {copy_extra, bits, nbits, bin} = take(copy_bits, bits, nbits, bin)
    insert = insert_offset + insert_extra
    if insert > state.left, do: invalid("the literals are longer than the meta-block")

    %{
      state
      | bits: bits,
        nbits: nbits,
        bin: bin,
        blen_i: blen - 1,
        ins: insert,
        clen: copy_offset + copy_extra,
        implicit?: code < 128,
        left: state.left - insert,
        step: if(insert == 0 and code >= 128, do: :distance, else: :literals)
    }
  end

  defp literals(%{ins: 0} = state, _limit), do: after_insert(state)

  defp literals(state, limit) do
    %{bits: bits, nbits: nbits, bin: bin, hist: hist, p1: p1, p2: p2} = state
    %{blen_l: blen, lctx: context, ins: insert} = state

    {left, bits, nbits, bin, hist, p1, p2, blen, state} =
      if byte_size(bin) >= @safe do
        count = min(insert, limit - pending(state))

        {left, bits, nbits, bin, hist, p, blen, state} =
          literal_loop(count, bits, nbits, bin, hist, p1 <<< 8 ||| p2, blen, state)

        {insert - count + left, bits, nbits, bin, hist, p >>> 8, p &&& 255, blen, state}
      else
        {byte, bits, nbits, bin, blen, _context, state} =
          literal(bits, nbits, bin, p1, p2, blen, context, state)

        {insert - 1, bits, nbits, bin, <<hist::binary, byte>>, byte, p1, blen, state}
      end

    state = %{
      state
      | bits: bits,
        nbits: nbits,
        bin: bin,
        hist: hist,
        p1: p1,
        p2: p2,
        blen_l: blen,
        ins: left
    }

    if left == 0, do: after_insert(state), else: state
  end

  # The loop of the literals while the input has `@safe` bytes: `left`
  # literals, and `p` has the last two bytes. The decode of a literal makes
  # no tuple: this loop is the most frequent work of the decoder. A block
  # switch puts the new context in the state.
  defp literal_loop(left, bits, nbits, bin, hist, p, blen, state)
       when left > 0 and byte_size(bin) >= @safe do
    cond do
      blen == 0 ->
        {bits, nbits, bin, blen, state} = switch(:l, bits, nbits, bin, 0, state)
        literal_loop(left, bits, nbits, bin, hist, p, blen, state)

      nbits < 15 ->
        <<byte::32-little, rest::binary>> = bin
        literal_loop(left, bits ||| byte <<< nbits, nbits + 32, rest, hist, p, blen, state)

      true ->
        {mask, root, table} = literal_tree(state.lctx, p >>> 8, p &&& 255, state.mb)

        entry =
          case elem(table, bits &&& mask) do
            {sub_mask, sub} -> elem(sub, bits >>> root &&& sub_mask)
            entry -> entry
          end

        length = entry &&& 15
        byte = entry >>> 4
        p = byte <<< 8 ||| p >>> 8
        hist = <<hist::binary, byte>>
        literal_loop(left - 1, bits >>> length, nbits - length, bin, hist, p, blen - 1, state)
    end
  end

  defp literal_loop(left, bits, nbits, bin, hist, p, blen, state),
    do: {left, bits, nbits, bin, hist, p, blen, state}

  defp literal(bits, nbits, bin, p1, p2, 0, _context, state) do
    {bits, nbits, bin, blen, state} = switch(:l, bits, nbits, bin, 0, state)
    literal(bits, nbits, bin, p1, p2, blen, state.lctx, state)
  end

  defp literal(bits, nbits, bin, p1, p2, blen, context, state) do
    tree = literal_tree(context, p1, p2, state.mb)
    {byte, bits, nbits, bin} = decode(tree, bits, nbits, bin)
    {byte, bits, nbits, bin, blen - 1, context, state}
  end

  defp literal_tree({:one, tree}, _p1, _p2, _mb), do: tree

  defp literal_tree({mode, offset}, p1, p2, %{lit: lit, cmap_l: map}),
    do: elem(lit, :binary.at(map, offset + context(mode, p1, p2)))

  # The context ID of a literal, section 7.1.
  defp context(0, p1, _p2), do: p1 &&& 63
  defp context(1, p1, _p2), do: p1 >>> 2
  defp context(2, p1, p2), do: :binary.at(@lut0, p1) ||| :binary.at(@lut1, p2)
  defp context(3, p1, p2), do: :binary.at(@lut2, p1) <<< 3 ||| :binary.at(@lut2, p2)

  defp literal_context(state, type) do
    offset = type * 64
    %{cmap_l: cmap, lit: lit, cmodes: modes} = state.mb
    <<first, _rest::binary>> = map = binary_part(cmap, offset, 64)

    if map == :binary.copy(<<first>>, 64),
      do: {:one, elem(lit, first)},
      else: {elem(modes, type), offset}
  end

  # The copy length of the last command is not used when the literals end
  # the meta-block.
  defp after_insert(%{left: 0} = state), do: %{state | step: block_end(state)}

  defp after_insert(%{implicit?: true, dist: {last, _, _, _}} = state),
    do: resolve(state, last, false)

  defp after_insert(state), do: %{state | step: :distance}

  defp distance(state) do
    %{bits: bits, nbits: nbits, bin: bin, blen_d: blen, clen: copy} = state
    {bits, nbits, bin, blen, state} = switch(:d, bits, nbits, bin, blen, state)
    {type, _previous} = state.bt_d
    map = :binary.at(state.mb.cmap_d, type * 4 + min(copy, 5) - 2)
    {code, bits, nbits, bin} = decode(elem(state.mb.dt, map), bits, nbits, bin)
    {distance, bits, nbits, bin} = distance_value(code, bits, nbits, bin, state)
    %{hist: hist, base: base, window: window, left: left, dist: last} = state

    if distance > min(window, base + byte_size(hist)) or copy > left do
      resolve(
        %{state | bits: bits, nbits: nbits, bin: bin, blen_d: blen - 1},
        distance,
        code != 0
      )
    else
      %{
        state
        | bits: bits,
          nbits: nbits,
          bin: bin,
          blen_d: blen - 1,
          dist: if(code == 0, do: last, else: push(last, distance)),
          step: {:copy, copy, distance},
          left: left - copy
      }
    end
  end

  # Section 4.
  defp distance_value(code, bits, nbits, bin, %{dist: {d0, d1, d2, d3}}) when code < 16 do
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
    {distance, bits, nbits, bin}
  end

  defp distance_value(code, bits, nbits, bin, %{mb: %{ndirect: ndirect}})
       when code < 16 + ndirect,
       do: {code - 15, bits, nbits, bin}

  defp distance_value(code, bits, nbits, bin, %{mb: %{ndirect: ndirect, npostfix: npostfix}}) do
    value = code - ndirect - 16
    extra_bits = 1 + (value >>> (npostfix + 1))
    high = value >>> npostfix
    low = value &&& (1 <<< npostfix) - 1
    offset = ((2 + (high &&& 1)) <<< extra_bits) - 4
    {extra, bits, nbits, bin} = take(extra_bits, bits, nbits, bin)
    {((offset + extra) <<< npostfix) + low + ndirect + 1, bits, nbits, bin}
  end

  # A distance up to the window and the output is a copy of earlier output.
  # A larger distance is a word of the static dictionary, section 8.
  defp resolve(state, distance, push?) do
    %{hist: hist, base: base, window: window, clen: length, left: left} = state
    max = min(window, base + byte_size(hist))

    cond do
      distance > max ->
        word = Dictionary.word(length, distance - max - 1)
        if word == :error, do: invalid("a reference to the dictionary is not valid")
        if byte_size(word) > left, do: invalid("a word is longer than the meta-block")
        after_copy(%{put_output(state, word) | left: left - byte_size(word)})

      length > left ->
        invalid("a copy is longer than the meta-block")

      true ->
        dist = if push?, do: push(state.dist, distance), else: state.dist
        %{state | step: {:copy, length, distance}, left: left - length, dist: dist}
    end
  end

  defp push({d0, d1, d2, _d3}, distance), do: {distance, d0, d1, d2}

  # One update of the state for each copy: the most frequent step after the
  # literals.
  defp copy(%{step: {:copy, count, distance}, hist: hist, p1: p1} = state, limit) do
    size = min(count, limit - pending(state))

    data =
      if distance >= size do
        binary_part(hist, byte_size(hist) - distance, size)
      else
        pattern = binary_part(hist, byte_size(hist) - distance, distance)
        binary_part(:binary.copy(pattern, div(size, distance) + 1), 0, size)
      end

    step =
      cond do
        size < count -> {:copy, count - size, distance}
        state.left == 0 -> block_end(state)
        true -> :command
      end

    if size == 1 do
      %{state | hist: <<hist::binary, data::binary>>, p1: :binary.first(data), p2: p1, step: step}
    else
      p2 = :binary.at(data, size - 2)
      %{state | hist: <<hist::binary, data::binary>>, p1: :binary.last(data), p2: p2, step: step}
    end
  end

  defp after_copy(%{left: 0} = state), do: %{state | step: block_end(state)}
  defp after_copy(state), do: %{state | step: :command}

  defp put_output(%{hist: hist, p1: p1} = state, data) do
    state = %{state | hist: <<hist::binary, data::binary>>}

    case byte_size(data) do
      0 -> state
      1 -> %{state | p1: :binary.first(data), p2: p1}
      size -> %{state | p1: :binary.at(data, size - 1), p2: :binary.at(data, size - 2)}
    end
  end

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
    state = if category == :l, do: %{state | lctx: literal_context(state, type)}, else: state
    {bits, nbits, bin, blen, state}
  end

  defp switch(_category, bits, nbits, bin, blen, state), do: {bits, nbits, bin, blen, state}

  defp types(state, :l), do: state.bt_l
  defp types(state, :i), do: state.bt_i
  defp types(state, :d), do: state.bt_d

  defp block_count(tree, bits, nbits, bin) do
    {code, bits, nbits, bin} = decode(tree, bits, nbits, bin)
    {offset, extra_bits} = elem(@block_count, code)
    {extra, bits, nbits, bin} = take(extra_bits, bits, nbits, bin)
    {offset + extra, bits, nbits, bin}
  end
end
