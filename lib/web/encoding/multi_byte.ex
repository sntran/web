defmodule Web.Encoding.MultiByte do
  @moduledoc false
  # The decoders of the multi-byte encodings of the Encoding Standard:
  # gb18030 (also the decoder of GBK), Big5, EUC-JP, ISO-2022-JP, Shift_JIS,
  # and EUC-KR. `Web.TextDecoder` uses this module.
  #
  # Each decoder is the handler of the Standard: a function of the state of
  # the decoder and one byte, or `:end_of_queue`. The function gives one of
  # these results:
  #
  #   * `{:continue, state}`;
  #   * `{:text, text, state}`, with the UTF-8 form of one or two code
  #     points;
  #   * `{:error, restore, state}`, with the bytes that the handler restores
  #     to the start of the queue;
  #   * `:finished`, only for `:end_of_queue`.
  #
  # `decode/5` runs the handler on each byte, as the decode method of
  # `TextDecoder` does. The state holds only small integers and atoms, thus a
  # decoder that streams keeps no reference to a chunk.

  alias Web.Encoding.Indexes

  @replacement_char <<0xEF, 0xBF, 0xBD>>

  # The handler, and the state in which an ASCII byte other than 0x0E, 0x0F,
  # and 0x1B gives its own code point and does not change the state.
  @decoders %{
    "gbk" => {:gb18030, {0, 0, 0}},
    "gb18030" => {:gb18030, {0, 0, 0}},
    "big5" => {:big5, 0},
    "euc-jp" => {:euc_jp, {false, 0}},
    "iso-2022-jp" => {:iso_2022_jp, {:ascii, :ascii, 0, false}},
    "shift_jis" => {:shift_jis, 0},
    "euc-kr" => {:euc_kr, 0}
  }

  @doc """
  Decodes `bytes` with the decoder of `encoding` in the state `state`, or
  in the state of a new decoder for `nil`.

  With `flush`, the decoder gets `:end_of_queue` after the bytes, and the
  result has the state `nil`. Without `flush`, the result has the state for
  the subsequent bytes. With `fatal`, the first error gives `:error`. Else
  each error gives U+FFFD.
  """
  @spec decode(String.t(), term(), binary(), boolean(), boolean()) ::
          {:ok, iodata(), term()} | :error
  def decode(encoding, state, bytes, flush, fatal) do
    {handler, ascii} = Map.fetch!(@decoders, encoding)

    run(
      %{handler: handler, ascii: ascii, flush: flush, fatal: fatal},
      state || ascii,
      [],
      bytes,
      []
    )
  end

  # The restored bytes come before the other bytes of the queue.
  defp run(decoder, state, [byte | restored], bytes, acc),
    do: step(decoder, handle(decoder.handler, state, byte), restored, bytes, acc)

  # A run of ASCII bytes needs no handler: each byte is its own code point.
  defp run(%{ascii: state} = decoder, state, [], <<byte, _rest::binary>> = bytes, acc)
       when byte < 0x80 and byte not in [0x0E, 0x0F, 0x1B] do
    size = ascii_size(bytes, 0)
    <<text::binary-size(^size), rest::binary>> = bytes
    run(decoder, state, [], rest, [acc | text])
  end

  defp run(decoder, state, [], <<byte, rest::binary>>, acc),
    do: step(decoder, handle(decoder.handler, state, byte), [], rest, acc)

  # The end of the bytes of a call with `stream: true`: the state stays for
  # the subsequent call.
  defp run(%{flush: false}, state, [], <<>>, acc), do: {:ok, acc, state}

  defp run(decoder, state, [], <<>>, acc) do
    case handle(decoder.handler, state, :end_of_queue) do
      :finished -> {:ok, acc, nil}
      result -> step(decoder, result, [], <<>>, acc)
    end
  end

  defp step(decoder, {:continue, state}, restored, bytes, acc),
    do: run(decoder, state, restored, bytes, acc)

  defp step(decoder, {:text, text, state}, restored, bytes, acc),
    do: run(decoder, state, restored, bytes, [acc | text])

  defp step(%{fatal: true}, {:error, _restore, _state}, _restored, _bytes, _acc), do: :error

  defp step(decoder, {:error, restore, state}, restored, bytes, acc),
    do: run(decoder, state, restore ++ restored, bytes, [acc | @replacement_char])

  defp ascii_size(<<byte, rest::binary>>, size)
       when byte < 0x80 and byte not in [0x0E, 0x0F, 0x1B],
       do: ascii_size(rest, size + 1)

  defp ascii_size(_bytes, size), do: size

  defp handle(:gb18030, state, byte), do: gb18030(state, byte)
  defp handle(:big5, state, byte), do: big5(state, byte)
  defp handle(:euc_jp, state, byte), do: euc_jp(state, byte)
  defp handle(:iso_2022_jp, state, byte), do: iso_2022_jp(state, byte)
  defp handle(:shift_jis, state, byte), do: shift_jis(state, byte)
  defp handle(:euc_kr, state, byte), do: euc_kr(state, byte)

  defp char(code_point), do: <<code_point::utf8>>

  # After an error, an ASCII byte goes back to the queue.
  defp restore_ascii(byte) when byte < 0x80, do: [byte]
  defp restore_ascii(_byte), do: []

  # ---------------------------------------------------------------------------
  # gb18030: the state is {gb18030 first, gb18030 second, gb18030 third}.
  # ---------------------------------------------------------------------------

  defp gb18030({0, 0, 0}, :end_of_queue), do: :finished
  defp gb18030(_state, :end_of_queue), do: {:error, [], {0, 0, 0}}

  defp gb18030({first, second, third}, byte) when third != 0 do
    if byte in 0x30..0x39 do
      pointer =
        (first - 0x81) * (10 * 126 * 10) + (second - 0x30) * (10 * 126) + (third - 0x81) * 10 +
          byte - 0x30

      gb18030_result(Indexes.gb18030_ranges(pointer), [])
    else
      {:error, [second, third, byte], {0, 0, 0}}
    end
  end

  defp gb18030({first, second, 0}, byte) when second != 0 do
    if byte in 0x81..0xFE,
      do: {:continue, {first, second, byte}},
      else: {:error, [second, byte], {0, 0, 0}}
  end

  defp gb18030({first, 0, 0}, byte) when first != 0 do
    cond do
      byte in 0x30..0x39 ->
        {:continue, {first, byte, 0}}

      byte in 0x40..0x7E or byte in 0x80..0xFE ->
        offset = if byte < 0x7F, do: 0x40, else: 0x41
        pointer = (first - 0x81) * 190 + byte - offset
        gb18030_result(Indexes.gb18030(pointer), restore_ascii(byte))

      true ->
        gb18030_result(nil, restore_ascii(byte))
    end
  end

  defp gb18030(state, byte) when byte < 0x80, do: {:text, <<byte>>, state}
  defp gb18030(state, 0x80), do: {:text, "\u20AC", state}
  defp gb18030(_state, byte) when byte in 0x81..0xFE, do: {:continue, {byte, 0, 0}}
  defp gb18030(state, _byte), do: {:error, [], state}

  defp gb18030_result(nil, restore), do: {:error, restore, {0, 0, 0}}
  defp gb18030_result(code_point, _restore), do: {:text, char(code_point), {0, 0, 0}}

  # ---------------------------------------------------------------------------
  # Big5: the state is Big5 leading.
  # ---------------------------------------------------------------------------

  defp big5(0, :end_of_queue), do: :finished
  defp big5(_leading, :end_of_queue), do: {:error, [], 0}
  defp big5(0, byte) when byte < 0x80, do: {:text, <<byte>>, 0}
  defp big5(0, byte) when byte in 0x81..0xFE, do: {:continue, byte}
  defp big5(0, _byte), do: {:error, [], 0}

  defp big5(leading, byte) when byte in 0x40..0x7E or byte in 0xA1..0xFE do
    offset = if byte < 0x7F, do: 0x40, else: 0x62

    case (leading - 0x81) * 157 + byte - offset do
      # The index has one code point for a pointer. These four pointers give
      # two code points.
      1133 -> {:text, "\u00CA\u0304", 0}
      1135 -> {:text, "\u00CA\u030C", 0}
      1164 -> {:text, "\u00EA\u0304", 0}
      1166 -> {:text, "\u00EA\u030C", 0}
      pointer -> lead_result(Indexes.big5(pointer), byte, 0)
    end
  end

  defp big5(_leading, byte), do: lead_result(nil, byte, 0)

  # The result of a leading byte and the byte after it: the code point, or
  # an error that restores an ASCII byte.
  defp lead_result(nil, byte, state), do: {:error, restore_ascii(byte), state}
  defp lead_result(code_point, _byte, state), do: {:text, char(code_point), state}

  # ---------------------------------------------------------------------------
  # EUC-JP: the state is {EUC-JP jis0212, EUC-JP leading}.
  # ---------------------------------------------------------------------------

  defp euc_jp({_jis0212, 0}, :end_of_queue), do: :finished
  defp euc_jp({jis0212, _leading}, :end_of_queue), do: {:error, [], {jis0212, 0}}

  defp euc_jp({jis0212, 0x8E}, byte) when byte in 0xA1..0xDF,
    do: {:text, char(0xFF61 - 0xA1 + byte), {jis0212, 0}}

  defp euc_jp({_jis0212, 0x8F}, byte) when byte in 0xA1..0xFE, do: {:continue, {true, byte}}

  defp euc_jp({jis0212, leading}, byte) when leading != 0 do
    code_point =
      if leading in 0xA1..0xFE and byte in 0xA1..0xFE do
        pointer = (leading - 0xA1) * 94 + byte - 0xA1
        if jis0212, do: Indexes.jis0212(pointer), else: Indexes.jis0208(pointer)
      end

    lead_result(code_point, byte, {false, 0})
  end

  defp euc_jp(state, byte) when byte < 0x80, do: {:text, <<byte>>, state}

  defp euc_jp({jis0212, 0}, byte) when byte in [0x8E, 0x8F] or byte in 0xA1..0xFE,
    do: {:continue, {jis0212, byte}}

  defp euc_jp(state, _byte), do: {:error, [], state}

  # ---------------------------------------------------------------------------
  # ISO-2022-JP: the state is {ISO-2022-JP decoder state, ISO-2022-JP decoder
  # output state, ISO-2022-JP leading, ISO-2022-JP output}.
  # ---------------------------------------------------------------------------

  defp iso_2022_jp({mode, output_mode, leading, output}, 0x1B)
       when mode in [:ascii, :roman, :katakana, :leading_byte],
       do: {:continue, {:escape_start, output_mode, leading, output}}

  defp iso_2022_jp({mode, _output_mode, _leading, _output}, :end_of_queue)
       when mode in [:ascii, :roman, :katakana, :leading_byte],
       do: :finished

  defp iso_2022_jp({:ascii, output_mode, leading, _output}, byte)
       when byte < 0x80 and byte not in [0x0E, 0x0F],
       do: {:text, <<byte>>, {:ascii, output_mode, leading, false}}

  defp iso_2022_jp({:roman, output_mode, leading, _output}, byte)
       when byte < 0x80 and byte not in [0x0E, 0x0F] do
    text =
      case byte do
        0x5C -> "\u00A5"
        0x7E -> "\u203E"
        byte -> <<byte>>
      end

    {:text, text, {:roman, output_mode, leading, false}}
  end

  defp iso_2022_jp({:katakana, output_mode, leading, _output}, byte) when byte in 0x21..0x5F,
    do: {:text, char(0xFF61 - 0x21 + byte), {:katakana, output_mode, leading, false}}

  defp iso_2022_jp({:leading_byte, output_mode, _leading, _output}, byte)
       when byte in 0x21..0x7E,
       do: {:continue, {:trailing_byte, output_mode, byte, false}}

  defp iso_2022_jp({mode, output_mode, leading, _output}, _byte)
       when mode in [:ascii, :roman, :katakana, :leading_byte],
       do: {:error, [], {mode, output_mode, leading, false}}

  defp iso_2022_jp({:trailing_byte, output_mode, leading, output}, 0x1B),
    do: {:error, [], {:escape_start, output_mode, leading, output}}

  defp iso_2022_jp({:trailing_byte, output_mode, leading, output}, byte)
       when byte in 0x21..0x7E do
    state = {:leading_byte, output_mode, leading, output}

    case Indexes.jis0208((leading - 0x21) * 94 + byte - 0x21) do
      nil -> {:error, [], state}
      code_point -> {:text, char(code_point), state}
    end
  end

  defp iso_2022_jp({:trailing_byte, output_mode, leading, output}, _byte),
    do: {:error, [], {:leading_byte, output_mode, leading, output}}

  defp iso_2022_jp({:escape_start, output_mode, _leading, output}, byte)
       when byte in [0x24, 0x28],
       do: {:continue, {:escape, output_mode, byte, output}}

  defp iso_2022_jp({:escape_start, output_mode, leading, _output}, byte) do
    restore = if byte == :end_of_queue, do: [], else: [byte]
    {:error, restore, {output_mode, output_mode, leading, false}}
  end

  defp iso_2022_jp({:escape, output_mode, leading, output}, byte) do
    case escape_state(leading, byte) do
      nil ->
        restore = if byte == :end_of_queue, do: [leading], else: [leading, byte]
        {:error, restore, {output_mode, output_mode, 0, false}}

      mode when output ->
        {:error, [], {mode, mode, 0, true}}

      mode ->
        {:continue, {mode, mode, 0, true}}
    end
  end

  defp escape_state(0x28, 0x42), do: :ascii
  defp escape_state(0x28, 0x4A), do: :roman
  defp escape_state(0x28, 0x49), do: :katakana
  defp escape_state(0x24, byte) when byte in [0x40, 0x42], do: :leading_byte
  defp escape_state(_leading, _byte), do: nil

  # ---------------------------------------------------------------------------
  # Shift_JIS: the state is Shift_JIS leading.
  # ---------------------------------------------------------------------------

  defp shift_jis(0, :end_of_queue), do: :finished
  defp shift_jis(_leading, :end_of_queue), do: {:error, [], 0}
  defp shift_jis(0, byte) when byte <= 0x80, do: {:text, char(byte), 0}
  defp shift_jis(0, byte) when byte in 0xA1..0xDF, do: {:text, char(0xFF61 - 0xA1 + byte), 0}

  defp shift_jis(0, byte) when byte in 0x81..0x9F or byte in 0xE0..0xFC,
    do: {:continue, byte}

  defp shift_jis(0, _byte), do: {:error, [], 0}

  defp shift_jis(leading, byte) when byte in 0x40..0x7E or byte in 0x80..0xFC do
    offset = if byte < 0x7F, do: 0x40, else: 0x41
    leading_offset = if leading < 0xA0, do: 0x81, else: 0xC1

    case (leading - leading_offset) * 188 + byte - offset do
      # The Private Use Area of Windows (EUDC).
      pointer when pointer in 8836..10_715 -> {:text, char(0xE000 - 8836 + pointer), 0}
      pointer -> lead_result(Indexes.jis0208(pointer), byte, 0)
    end
  end

  defp shift_jis(_leading, byte), do: lead_result(nil, byte, 0)

  # ---------------------------------------------------------------------------
  # EUC-KR: the state is EUC-KR leading.
  # ---------------------------------------------------------------------------

  defp euc_kr(0, :end_of_queue), do: :finished
  defp euc_kr(_leading, :end_of_queue), do: {:error, [], 0}
  defp euc_kr(0, byte) when byte < 0x80, do: {:text, <<byte>>, 0}
  defp euc_kr(0, byte) when byte in 0x81..0xFE, do: {:continue, byte}
  defp euc_kr(0, _byte), do: {:error, [], 0}

  defp euc_kr(leading, byte) when byte in 0x41..0xFE,
    do: lead_result(Indexes.euc_kr((leading - 0x81) * 190 + byte - 0x41), byte, 0)

  defp euc_kr(_leading, byte), do: lead_result(nil, byte, 0)
end
