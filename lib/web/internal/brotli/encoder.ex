defmodule Web.Internal.Brotli.Encoder do
  @moduledoc false

  # A simple encoder of the brotli format of RFC 7932, in Elixir: Erlang/OTP
  # has no brotli.
  #
  # The encoder keeps the input until it has a block of `@block` bytes, and
  # makes one meta-block for each block. It finds repeated strings with a
  # hash table of the positions of 4 bytes (LZ77, with one candidate for
  # each hash). One prefix code codes the literals, one the insert-and-copy
  # lengths, and one the distances. A copy can refer to the earlier blocks
  # in the window. A block that does not compress becomes an uncompressed
  # meta-block.
  #
  # The encoder uses no block switch and one context, and NPOSTFIX and
  # NDIRECT are 0. It does not use the static dictionary.
  #
  # The hash table is an `:atomics` array: the encoder changes an entry for
  # each byte, and the array changes in place.

  import Bitwise

  @wbits 18
  @window (1 <<< @wbits) - 16
  @block 65_536
  @hash_size 32_768

  # The fixed code of the code length code lengths, section 3.5: the bits,
  # first bit in the least significant position, and the number of bits.
  @code_length_code {{0, 2}, {7, 4}, {3, 3}, {2, 2}, {1, 2}, {15, 4}}
  @code_length_order [1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15]

  # The offset and the number of extra bits of the insert length codes and
  # the copy length codes of section 5.
  @insert_length {{0, 0}, {1, 0}, {2, 0}, {3, 0}, {4, 0}, {5, 0}, {6, 1}, {8, 1}, {10, 2},
                  {14, 2}, {18, 3}, {26, 3}, {34, 4}, {50, 4}, {66, 5}, {98, 5}, {130, 6},
                  {194, 7}, {322, 8}, {578, 9}, {1090, 10}, {2114, 12}, {6210, 14}, {22_594, 24}}

  @copy_length {{2, 0}, {3, 0}, {4, 0}, {5, 0}, {6, 0}, {7, 0}, {8, 0}, {9, 0}, {10, 1}, {12, 1},
                {14, 2}, {18, 2}, {22, 3}, {30, 3}, {38, 4}, {54, 4}, {70, 5}, {102, 5}, {134, 6},
                {198, 7}, {326, 8}, {582, 9}, {1094, 10}, {2118, 24}}

  @typedoc "The state of an encoder."
  @type t :: map()

  @doc "A new encoder."
  @spec new() :: t()
  def new do
    %{
      writer: {0, 0, []},
      started?: false,
      pending: <<>>,
      history: <<>>,
      base: 0,
      last: 4,
      table: :atomics.new(@hash_size, signed: true)
    }
  end

  @doc "Adds input. Returns the output that is ready, which can be empty."
  @spec push(t(), binary()) :: {binary(), t()}
  def push(state, data) do
    %{state | pending: state.pending <> data}
    |> start()
    |> full_blocks()
    |> flush()
  end

  @doc "Ends the stream, and returns the last output."
  @spec finish(t()) :: binary()
  def finish(state) do
    state = start(state)

    %{writer: {acc, used, out}} =
      case state.pending do
        <<>> -> %{state | writer: bits(state.writer, 0b11, 2)}
        data -> block(%{state | pending: <<>>}, data, true)
      end

    # The bits after the last meta-block are zero, up to the byte boundary.
    IO.iodata_to_binary([out, <<acc::size(div(used + 7, 8) * 8)-little>>])
  end

  # The stream header: WBITS, section 9.1.
  defp start(%{started?: true} = state), do: state

  defp start(state),
    do: %{state | started?: true, writer: bits(state.writer, 1 ||| (@wbits - 17) <<< 1, 4)}

  defp full_blocks(%{pending: pending} = state) when byte_size(pending) >= @block do
    data = binary_part(pending, 0, @block)
    rest = binary_part(pending, @block, byte_size(pending) - @block)
    full_blocks(block(%{state | pending: rest}, data, false))
  end

  defp full_blocks(state), do: state

  # Gives the whole bytes. The bits of the last byte stay in the writer.
  defp flush(%{writer: {acc, used, out}} = state) do
    size = div(used, 8) * 8
    output = IO.iodata_to_binary([out, <<acc::size(size)-little>>])
    {output, %{state | writer: {acc >>> size, used - size, []}}}
  end

  # ---------------------------------------------------------------------------
  # The bit writer
  #
  # A writer is `{acc, used, out}`: `used` bits that are not in the output
  # yet, the first bit in the least significant position, and the output as
  # an iolist. A write has 24 bits at most, thus `acc` stays a small integer.
  # ---------------------------------------------------------------------------

  defp bits({acc, used, out}, value, count) do
    acc = acc ||| value <<< used
    used = used + count

    if used >= 32,
      do: {acc >>> 32, used - 32, [out | <<acc::32-little>>]},
      else: {acc, used, out}
  end

  defp size({_acc, used, out}), do: IO.iodata_length(out) * 8 + used

  # ---------------------------------------------------------------------------
  # The meta-blocks, section 9.2
  # ---------------------------------------------------------------------------

  defp block(state, data, last?) do
    %{history: history, base: base, writer: {acc, used, out}, last: last} = state
    buffer = history <> data
    start = byte_size(history)

    {commands, next} =
      parse(buffer, start, byte_size(buffer), start, {base, state.table}, last, [])

    compressed = compressed({acc, used, []}, buffer, commands, byte_size(data), last?)
    raw = raw({acc, used, []}, data, last?)

    # An uncompressed meta-block has no distances: the last distance of the
    # decoder does not change.
    {{acc, used, block_out}, last} =
      if size(raw) < size(compressed), do: {raw, last}, else: {compressed, next}

    keep = min(byte_size(buffer), @window)

    %{
      state
      | writer: {acc, used, [out | block_out]},
        last: last,
        history: binary_part(buffer, byte_size(buffer) - keep, keep),
        base: base + byte_size(buffer) - keep
    }
  end

  # ISLAST, ISLASTEMPTY, MNIBBLES, and MLEN - 1. A block has 64 KiB at
  # most: MLEN has 4 nibbles.
  defp length_header(writer, last?, length) do
    writer = if last?, do: bits(writer, 0b01, 2), else: bits(writer, 0, 1)
    writer |> bits(0, 2) |> bits(length - 1, 16)
  end

  # An uncompressed meta-block is never the last one: the last meta-block is
  # then an empty one.
  defp raw(writer, data, last?) do
    writer = writer |> length_header(false, byte_size(data)) |> bits(1, 1)
    {acc, used, out} = bits(writer, 0, rem(8 - rem(writer |> elem(1), 8), 8))
    writer = {0, 0, [out, <<acc::size(used)-little>>, data]}
    if last?, do: bits(writer, 0b11, 2), else: writer
  end

  defp compressed(writer, buffer, commands, length, last?) do
    writer = length_header(writer, last?, length)
    writer = if last?, do: writer, else: bits(writer, 0, 1)
    # NBLTYPESL, NBLTYPESI, and NBLTYPESD are 1, NPOSTFIX and NDIRECT are 0,
    # the context mode is LSB6, and NTREESL and NTREESD are 1.
    writer = bits(writer, 0, 13)

    literal_counts = :counters.new(256, [])
    command_counts = :counters.new(704, [])
    distance_counts = :counters.new(64, [])

    for {start, insert, _copy, _insert_code, _copy_code, code, distance} <- commands do
      count_bytes(binary_part(buffer, start, insert), literal_counts)
      :counters.add(command_counts, code + 1, 1)
      if distance, do: :counters.add(distance_counts, elem(distance, 0) + 1, 1)
    end

    {writer, literals} = prefix_code(writer, counts(literal_counts, 256), 256)
    {writer, codes} = prefix_code(writer, counts(command_counts, 704), 704)
    {writer, distances} = prefix_code(writer, counts(distance_counts, 64), 64)
    write_commands(commands, buffer, writer, {literals, codes, distances})
  end

  defp count_bytes(<<byte, rest::binary>>, counters) do
    :counters.add(counters, byte + 1, 1)
    count_bytes(rest, counters)
  end

  defp count_bytes(<<>>, _counters), do: :ok

  defp counts(counters, size), do: for(index <- 1..size, do: :counters.get(counters, index))

  defp write_commands([], _buffer, writer, _tables), do: writer

  defp write_commands([command | rest], buffer, writer, tables) do
    {start, insert, copy, insert_code, copy_code, code, distance} = command
    {literals, codes, distances} = tables
    {insert_offset, insert_bits} = elem(@insert_length, insert_code)
    {copy_offset, copy_bits} = elem(@copy_length, copy_code)

    writer =
      writer
      |> symbol(codes, code)
      |> bits(insert - insert_offset, insert_bits)
      |> bits(copy - copy_offset, copy_bits)

    writer = write_literals(binary_part(buffer, start, insert), writer, literals)

    writer =
      case distance do
        {symbol, count, extra} -> writer |> symbol(distances, symbol) |> bits(extra, count)
        nil -> writer
      end

    write_commands(rest, buffer, writer, tables)
  end

  defp write_literals(<<byte, rest::binary>>, writer, literals),
    do: write_literals(rest, symbol(writer, literals, byte), literals)

  defp write_literals(<<>>, writer, _literals), do: writer

  defp symbol(writer, table, value) do
    {code, length} = elem(table, value)
    bits(writer, code, length)
  end

  # ---------------------------------------------------------------------------
  # The LZ77 parse
  # ---------------------------------------------------------------------------

  # Returns the commands of a block in their sequence, and the last distance
  # after them. A command is `{start, insert, copy, insert_code, copy_code,
  # code, distance}`: the position of its literals in the buffer, the insert
  # length, the copy length, their codes, the insert-and-copy length code,
  # and the distance code with its extra bits (`nil` for the last distance
  # that the code gives).
  defp parse(buffer, position, stop, start, hash, last, acc) when position + 4 <= stop do
    {base, table} = hash
    <<_skip::binary-size(^position), key::32-little, _rest::binary>> = buffer
    slot = :erlang.phash2(key, @hash_size) + 1
    candidate = :atomics.get(table, slot) - 1 - base
    :atomics.put(table, slot, base + position + 1)
    distance = position - candidate

    length =
      if candidate >= 0 and distance <= @window do
        :binary.longest_common_prefix([
          binary_part(buffer, candidate, stop - position),
          binary_part(buffer, position, stop - position)
        ])
      else
        0
      end

    if length >= 4 do
      next = position + length
      add_positions(buffer, position + 1, min(next, stop - 3), hash)
      {command, last} = command(start, position - start, length, distance, last)
      parse(buffer, next, stop, next, hash, last, [command | acc])
    else
      parse(buffer, position + 1, stop, start, hash, last, acc)
    end
  end

  # The literals at the end of the block: the meta-block ends after them,
  # thus the copy length is not used.
  defp parse(_buffer, _position, stop, start, _hash, last, acc) do
    acc =
      if start < stop do
        insert = stop - start
        insert_code = insert_code(insert)
        [{start, insert, 2, insert_code, 0, code(insert_code, 0, insert_code < 8), nil} | acc]
      else
        acc
      end

    {Enum.reverse(acc), last}
  end

  defp add_positions(buffer, position, stop, {base, table} = hash) when position < stop do
    <<_skip::binary-size(^position), key::32-little, _rest::binary>> = buffer
    :atomics.put(table, :erlang.phash2(key, @hash_size) + 1, base + position + 1)
    add_positions(buffer, position + 1, stop, hash)
  end

  defp add_positions(_buffer, _position, _stop, _hash), do: :ok

  # The insert-and-copy length codes 0 to 127 use the last distance with no
  # distance code. The distance code 0 is also the last distance. The other
  # distances go into the ring buffer of the decoder.
  defp command(start, insert, copy, distance, last) do
    insert_code = insert_code(insert)
    copy_code = copy_code(copy)

    cond do
      distance == last and insert_code < 8 and copy_code < 16 ->
        {{start, insert, copy, insert_code, copy_code, code(insert_code, copy_code, true), nil},
         last}

      distance == last ->
        {{start, insert, copy, insert_code, copy_code, code(insert_code, copy_code, false),
          {0, 0, 0}}, last}

      true ->
        {{start, insert, copy, insert_code, copy_code, code(insert_code, copy_code, false),
          distance_code(distance)}, distance}
    end
  end

  # The insert-and-copy length code of section 5.
  defp code(insert_code, copy_code, true) do
    if(copy_code < 8, do: 0, else: 64) + ((insert_code &&& 7) <<< 3) + (copy_code &&& 7)
  end

  # The first code of each cell, for the insert length codes 0-7, 8-15,
  # and 16-23, and the copy length codes 0-7, 8-15, and 16-23.
  defp code(insert_code, copy_code, false) do
    cell =
      elem(
        {128, 192, 384, 256, 320, 512, 448, 576, 640},
        3 * (insert_code >>> 3) + (copy_code >>> 3)
      )

    cell + ((insert_code &&& 7) <<< 3) + (copy_code &&& 7)
  end

  @doc false
  def __insert_code__(length), do: insert_code(length)
  @doc false
  def __copy_code__(length), do: copy_code(length)

  defp insert_code(length) when length < 6, do: length

  defp insert_code(length) when length < 130 do
    bits = log2(length - 2) - 1
    (bits <<< 1) + ((length - 2) >>> bits) + 2
  end

  defp insert_code(length) when length < 2114, do: log2(length - 66) + 10
  defp insert_code(length) when length < 6210, do: 21
  defp insert_code(length) when length < 22_594, do: 22
  defp insert_code(_length), do: 23

  defp copy_code(length) when length < 10, do: length - 2

  defp copy_code(length) when length < 134 do
    bits = log2(length - 6) - 1
    (bits <<< 1) + ((length - 6) >>> bits) + 4
  end

  defp copy_code(length) when length < 2118, do: log2(length - 70) + 12
  defp copy_code(_length), do: 23

  # The distance code of section 4 with NPOSTFIX = 0 and NDIRECT = 0, and
  # its extra bits: `{code, bits, extra}`.
  defp distance_code(distance) do
    value = distance + 3
    bits = log2(value) - 1
    top = value >>> bits
    {16 + 2 * (bits - 1) + top - 2, bits, value - (top <<< bits)}
  end

  defp log2(value, acc \\ 0)
  defp log2(value, acc) when value <= 1, do: acc
  defp log2(value, acc), do: log2(value >>> 1, acc + 1)

  # ---------------------------------------------------------------------------
  # The prefix codes, section 3
  # ---------------------------------------------------------------------------

  # Writes the prefix code for the counts of an alphabet of `size` symbols.
  # Returns the writer and a table of `{bits, length}` for each symbol.
  defp prefix_code(writer, counts, size) do
    used = for {count, symbol} <- Enum.with_index(counts), count > 0, do: {symbol, count}

    case used do
      [] -> simple_code(writer, [{0, 0}], size)
      [{symbol, _count}] -> simple_code(writer, [{symbol, 0}], size)
      used when length(used) <= 4 -> simple_code(writer, lengths(used, 15), size)
      used -> complex_code(writer, lengths(used, 15), size)
    end
  end

  # A simple prefix code of section 3.4: the symbols in the sequence of
  # their lengths.
  defp simple_code(writer, lengths, size) do
    lengths = Enum.sort_by(lengths, fn {symbol, length} -> {length, symbol} end)
    alphabet_bits = log2(size - 1) + 1
    writer = writer |> bits(1, 2) |> bits(length(lengths) - 1, 2)

    writer =
      Enum.reduce(lengths, writer, fn {symbol, _length}, w -> bits(w, symbol, alphabet_bits) end)

    writer =
      case Enum.map(lengths, &elem(&1, 1)) do
        [2, 2, 2, 2] -> bits(writer, 0, 1)
        [1, 2, 3, 3] -> bits(writer, 1, 1)
        _other -> writer
      end

    {writer, table(lengths, size)}
  end

  # A complex prefix code of section 3.5: the code lengths, coded with
  # the code length code and with runs (the method of the reference
  # encoder).
  defp complex_code(writer, lengths, size) do
    by_symbol = Map.new(lengths)
    last = lengths |> Enum.map(&elem(&1, 0)) |> Enum.max()
    sequence = rle(for(symbol <- 0..last, do: Map.get(by_symbol, symbol, 0)))

    {code_lengths, code_table} =
      case Enum.frequencies_by(sequence, &elem(&1, 0)) |> Enum.to_list() do
        [{symbol, _count}] -> {%{symbol => 1}, table([{symbol, 0}], 18)}
        counts -> counts |> lengths(5) |> then(&{Map.new(&1), table(&1, 18)})
      end

    writer
    |> code_length_lengths(code_lengths)
    |> code_length_symbols(sequence, code_table)
    |> then(&{&1, table(lengths, size)})
  end

  # HSKIP and the code lengths of the code length code, in the sequence of
  # section 3.5. The decoder reads up to the last length that is not zero,
  # or all the lengths for a code with one symbol.
  defp code_length_lengths(writer, code_lengths) do
    order = Enum.map(@code_length_order, &Map.get(code_lengths, &1, 0))

    skip =
      case order do
        [0, 0, 0 | _rest] -> 3
        [0, 0 | _rest] -> 2
        _other -> 0
      end

    written = Enum.drop(order, skip)

    written =
      if map_size(code_lengths) == 1,
        do: written,
        else: written |> Enum.reverse() |> Enum.drop_while(&(&1 == 0)) |> Enum.reverse()

    Enum.reduce(written, bits(writer, skip, 2), fn length, writer ->
      {code, count} = elem(@code_length_code, length)
      bits(writer, code, count)
    end)
  end

  defp code_length_symbols(writer, sequence, code_table) do
    Enum.reduce(sequence, writer, fn {code, extra}, writer ->
      writer = symbol(writer, code_table, code)

      case code do
        16 -> bits(writer, extra, 2)
        17 -> bits(writer, extra, 3)
        _length -> writer
      end
    end)
  end

  # The code length symbols for the code lengths: `{symbol, extra}`. A run
  # of zeros uses the symbol 17, and a run of the previous length uses 16.
  defp rle(lengths) do
    lengths
    |> Enum.chunk_by(& &1)
    |> Enum.map_reduce(8, fn [value | _rest] = run, previous ->
      if value == 0,
        do: {zeros(length(run)), previous},
        else: {repeats(previous, value, length(run)), value}
    end)
    |> elem(0)
    |> Enum.concat()
  end

  defp zeros(count) when count < 3, do: List.duplicate({0, 0}, count)
  defp zeros(count), do: for(digit <- digits(count - 3, 3, []), do: {17, digit})

  defp repeats(previous, value, count) when previous != value,
    do: [{value, 0} | repeats(value, value, count - 1)]

  defp repeats(_previous, value, count) when count < 3, do: List.duplicate({value, 0}, count)

  defp repeats(_previous, _value, count),
    do: for(digit <- digits(count - 3, 2, []), do: {16, digit})

  # The extra bits of a chain of repeat codes: the decoder multiplies the
  # count of the code before by 4 (or 8) for each code that follows.
  defp digits(value, bits, acc) do
    acc = [value &&& (1 <<< bits) - 1 | acc]

    case value >>> bits do
      0 -> acc
      next -> digits(next - 1, bits, acc)
    end
  end

  # The canonical codes of section 3.2, with the first bit of each code in
  # the least significant position.
  defp table(lengths, size) do
    codes =
      lengths
      |> Enum.sort_by(fn {symbol, length} -> {length, symbol} end)
      |> Enum.map_reduce({0, 0}, fn {symbol, length}, {code, previous} ->
        code = code <<< (length - previous)
        {{symbol, {reverse(code, length, 0), length}}, {code + 1, length}}
      end)
      |> elem(0)
      |> Map.new()

    List.to_tuple(for symbol <- 0..(size - 1), do: Map.get(codes, symbol, {0, 0}))
  end

  defp reverse(_code, 0, acc), do: acc
  defp reverse(code, length, acc), do: reverse(code >>> 1, length - 1, acc <<< 1 ||| (code &&& 1))

  @doc false
  # For a test of the lengths of a prefix code.
  def __lengths__(counts, limit), do: lengths(counts, limit)

  # The lengths of a prefix code with at most `limit` bits, for the counts
  # of two or more symbols. The method of the reference encoder: when the
  # tree is too deep, the smallest counts become larger, and the tree is
  # made again.
  defp lengths(counts, limit, minimum \\ 1) do
    leaves =
      counts
      |> Enum.map(fn {symbol, count} -> {max(count, minimum), {:leaf, symbol}} end)
      |> Enum.sort()

    depths = depths(huffman(leaves, :queue.new(), length(leaves)), 0, [])

    if Enum.any?(depths, fn {_symbol, depth} -> depth > limit end),
      do: lengths(counts, limit, minimum * 2),
      else: depths
  end

  # The two-queue method: the leaves in the sequence of their counts, and
  # the new nodes in the sequence in which they come.
  # The last node is the root: the leaves are two or more.
  defp huffman([], nodes, 1), do: nodes |> :queue.head() |> elem(1)

  defp huffman(leaves, nodes, count) do
    {{first, a}, leaves, nodes} = smallest(leaves, nodes)
    {{second, b}, leaves, nodes} = smallest(leaves, nodes)
    huffman(leaves, :queue.in({first + second, {:node, a, b}}, nodes), count - 1)
  end

  defp smallest([{count, _tree} = leaf | leaves] = all, nodes) do
    case :queue.peek(nodes) do
      {:value, {node_count, _tree} = node} when node_count < count ->
        {node, all, :queue.drop(nodes)}

      _other ->
        {leaf, leaves, nodes}
    end
  end

  defp smallest([], nodes), do: {:queue.head(nodes), [], :queue.drop(nodes)}

  defp depths({:leaf, symbol}, depth, acc), do: [{symbol, depth} | acc]

  defp depths({:node, a, b}, depth, acc),
    do: depths(a, depth + 1, depths(b, depth + 1, acc))
end
