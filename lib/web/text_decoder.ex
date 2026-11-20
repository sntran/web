defmodule Web.TextDecoder.State do
  @moduledoc false

  # Holds the bytes that a decoder keeps between two calls with
  # `stream: true`. The process stops when its owner stops.

  use GenServer

  @spec start(pid(), map()) :: {:ok, pid()}
  def start(owner, state), do: GenServer.start(__MODULE__, {owner, state})

  @spec update(pid(), (map() -> {term(), map()})) :: term()
  def update(pid, fun), do: GenServer.call(pid, {:update, fun}, :infinity)

  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init({owner, state}) do
    Process.monitor(owner)
    {:ok, state}
  end

  @impl true
  def handle_call({:update, fun}, _from, state) do
    {reply, new_state} = fun.(state)
    {:reply, reply, new_state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}
end

defmodule Web.TextDecoder do
  @moduledoc """
  A decoder from bytes to text, as `TextDecoder` of the Encoding Standard.

  A decoder has the options `fatal` and `ignoreBOM`. With `stream: true`,
  `decode/3` keeps the bytes of a character that is not complete for the
  subsequent call.

  ## Encodings

  `new/2` accepts each label of the Encoding Standard for these encodings:

    * UTF-8;
    * UTF-16LE and UTF-16BE;
    * the 28 single-byte encodings: IBM866, ISO-8859-2 to ISO-8859-8,
      ISO-8859-8-I, ISO-8859-10, ISO-8859-13 to ISO-8859-16, KOI8-R, KOI8-U,
      macintosh, windows-874, windows-1250 to windows-1258, and
      x-mac-cyrillic;
    * the multi-byte encodings of Chinese, Japanese, and Korean: GBK,
      gb18030, Big5, EUC-JP, ISO-2022-JP, Shift_JIS, and EUC-KR;
    * x-user-defined.

  As in the Standard, the labels `latin1`, `ascii`, and `iso-8859-1` are
  labels of windows-1252, and GBK and gb18030 have the same decoder. The
  labels of the encoding replacement, for example `iso-2022-kr`, give
  `Web.RangeError`.

  ## Examples

      iex> decoder = Web.TextDecoder.new("latin1")
      iex> {decoder.encoding, Web.TextDecoder.decode(decoder, <<0x63, 0x61, 0x66, 0xE9, 0x80>>)}
      {"windows-1252", "café€"}

      iex> decoder = Web.TextDecoder.new("utf-16le")
      iex> Web.TextDecoder.decode(decoder, <<0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00>>)
      "hi"

  A decoder keeps its state in a small process. The process stops when the
  process that made the decoder stops.
  """

  alias Web.Encoding
  alias Web.Encoding.MultiByte

  alias Web.TextDecoder.State

  import Bitwise

  alias Web.TypeError
  alias Web.Uint8Array

  @bom <<0xEF, 0xBB, 0xBF>>
  @replacement_char <<0xEF, 0xBF, 0xBD>>
  @bom_kinds [:utf8, :utf16le, :utf16be]
  defstruct [:encoding, :state_pid, :fatal, :ignore_bom]

  @type t :: %__MODULE__{
          encoding: String.t(),
          state_pid: pid(),
          fatal: boolean(),
          ignore_bom: boolean()
        }

  @type options ::
          %{
            optional(:fatal) => boolean(),
            optional(:ignore_bom) => boolean(),
            optional(:ignoreBOM) => boolean()
          }
          | keyword()
  @type decode_options :: %{optional(:stream) => boolean()}

  @doc """
  Makes a decoder for the encoding of the label.

  The options are `:fatal` and `:ignore_bom` (also `:ignoreBOM`). The field
  `:encoding` of the result is the name of the encoding in lowercase.

  Raises `Web.RangeError` for a label that is not known, and for the
  encoding `replacement`.
  """
  @spec new(String.t(), options()) :: t()
  def new(label \\ "utf-8", options \\ %{}) do
    encoding = encoding!(label)
    options = Map.new(options)
    fatal = Map.get(options, :fatal, false) == true
    ignore_bom = Map.get(options, :ignore_bom, Map.get(options, :ignoreBOM, false)) == true

    {:ok, state_pid} = State.start(Web.Promise.owner(), initial_state())
    %__MODULE__{encoding: encoding, state_pid: state_pid, fatal: fatal, ignore_bom: ignore_bom}
  end

  defp encoding!(label) when is_binary(label) do
    case Encoding.get(label) do
      # The Encoding Standard gives `RangeError` for a label that is not
      # known, and for the encoding `replacement`.
      result when result in [:error, {:ok, "replacement"}] ->
        raise Web.RangeError, "The encoding label #{inspect(label)} is not valid"

      {:ok, encoding} ->
        encoding
    end
  end

  defp encoding!(_label) do
    raise TypeError, "TextDecoder label must be a string"
  end

  @doc """
  Decodes the bytes of `input`, as the method `decode()` of the Encoding
  Standard.

  The input is a binary, a `Web.Uint8Array`, or a `Web.ArrayBuffer`. With
  no input, or with `nil`, the decoder decodes no bytes. With the option
  `stream: true`, the decoder keeps the bytes of a character that is not
  complete, and its state, for the subsequent call. A call with no `stream`
  option is the end of the data: the decoder decodes the bytes that it
  kept, and starts again. Thus `decode/1` ends a stream.

  Each byte sequence that is not valid gives U+FFFD. With the option
  `fatal`, it raises `Web.TypeError`, and the decoder starts again.

  ## Examples

      iex> decoder = Web.TextDecoder.new("shift_jis")
      iex> part = Web.TextDecoder.decode(decoder, <<0x93, 0xFA, 0x96>>, %{stream: true})
      iex> {part, Web.TextDecoder.decode(decoder, <<0x7B>>)}
      {"日", "本"}

      iex> decoder = Web.TextDecoder.new()
      iex> Web.TextDecoder.decode(decoder, <<0xE2, 0x82>>, %{stream: true})
      ""
      iex> Web.TextDecoder.decode(decoder)
      "\uFFFD"
  """
  @spec decode(t(), binary() | Uint8Array.t() | Web.ArrayBuffer.t() | nil, decode_options()) ::
          String.t()
  def decode(%__MODULE__{} = decoder, input \\ nil, options \\ %{}) do
    stream = Map.get(options, :stream, false)
    chunk = normalize_input(input)

    case update_state(decoder, &decode_chunk(&1, chunk, decoder, stream)) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp update_state(decoder, fun) do
    State.update(decoder.state_pid, fun)
  catch
    :exit, _reason ->
      {:error, TypeError.exception("The TextDecoder is not available. Its owner stopped.")}
  end

  @doc false
  # Stops the state process of a decoder that has no more use.
  @spec dispose(t()) :: :ok
  def dispose(%__MODULE__{state_pid: state_pid}), do: State.stop(state_pid)

  @doc false
  # The state of a decoder as data.
  @spec initial_state() :: map()
  def initial_state, do: %{carry: "", bom_seen: false, decoder: nil}

  @doc false
  # The algorithm "UTF-8 decode" of the Encoding Standard for all the bytes
  # of a body: the byte order mark goes away, and each invalid sequence
  # becomes U+FFFD. Valid UTF-8 is the text with no copy. `Web.Body` uses
  # this function, thus a body read starts no state process.
  @spec decode_utf8(binary()) :: String.t()
  def decode_utf8(<<@bom, rest::binary>>), do: replace_invalid(rest)
  def decode_utf8(bytes) when is_binary(bytes), do: replace_invalid(bytes)

  # A multi-byte decoder keeps its state in the field `decoder`, and no
  # bytes: see `Web.Encoding.MultiByte`.
  defp decode_chunk(state, chunk, decoder, stream) do
    case Encoding.kind(decoder.encoding) do
      :multi_byte -> decode_multi_byte(state, chunk, decoder, stream)
      kind -> decode_other(kind, state, chunk, decoder, stream)
    end
  end

  defp decode_multi_byte(state, chunk, decoder, stream) do
    case MultiByte.decode(decoder.encoding, state.decoder, chunk, not stream, decoder.fatal) do
      {:ok, decoded, next} -> {{:ok, IO.iodata_to_binary(decoded)}, %{state | decoder: next}}
      :error -> {{:error, invalid_data(decoder.encoding)}, %{state | decoder: nil}}
    end
  end

  defp decode_other(kind, %{carry: carry, bom_seen: bom_seen} = state, chunk, decoder, stream) do
    data = IO.iodata_to_binary([carry, chunk])

    case decode_bytes(kind, data, decoder, stream) do
      {:ok, decoded, complete, trailing} ->
        build_decode_result(state, decoded, bom_seen, trailing, decoder, complete, stream)

      {:error, error} ->
        # As in the Encoding Standard, a decoder that had an error starts
        # again with no bytes.
        {{:error, error}, %{state | carry: "", bom_seen: false}}
    end
  end

  # Decodes the bytes of one call. Returns the text, the bytes that were
  # decoded, and the bytes that stay for the subsequent call.
  defp decode_bytes(:utf8, data, decoder, stream) do
    {complete, trailing} = split_stream_data(data, stream)

    with {:ok, decoded} <- decode_complete_bytes(complete, decoder.fatal) do
      {:ok, decoded, complete, trailing}
    end
  end

  defp decode_bytes(kind, data, decoder, stream) when kind in [:utf16le, :utf16be] do
    endian = if kind == :utf16le, do: :little, else: :big

    with {:ok, decoded, trailing} <- decode_utf16(data, endian, decoder.fatal, []),
         {:ok, decoded, trailing} <- flush_utf16(decoded, trailing, decoder.fatal, stream) do
      complete = binary_part(data, 0, byte_size(data) - byte_size(trailing))
      {:ok, IO.iodata_to_binary(decoded), complete, trailing}
    end
  end

  defp decode_bytes(:user_defined, data, _decoder, _stream) do
    # Each byte above 0x7F is a code point of the Private Use Area.
    decoded = for <<byte <- data>>, into: "", do: <<user_defined(byte)::utf8>>
    {:ok, decoded, data, ""}
  end

  defp decode_bytes(:single_byte, data, decoder, _stream) do
    table = Encoding.single_byte_table(decoder.encoding)

    with {:ok, decoded} <- decode_single_byte(data, table, decoder, []) do
      {:ok, decoded, data, ""}
    end
  end

  defp user_defined(byte) when byte < 0x80, do: byte
  defp user_defined(byte), do: 0xF780 + byte - 0x80

  defp decode_single_byte(<<>>, _table, _decoder, acc) do
    {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp decode_single_byte(<<byte, rest::binary>>, table, decoder, acc) do
    case elem(table, byte) do
      nil when decoder.fatal -> {:error, invalid_data(decoder.encoding)}
      nil -> decode_single_byte(rest, table, decoder, [@replacement_char | acc])
      text -> decode_single_byte(rest, table, decoder, [text | acc])
    end
  end

  # The shared UTF-16 decoder of the Encoding Standard. `trailing` gets a
  # byte with no pair, and a lead surrogate with no trail surrogate.
  defp decode_utf16(data, endian, fatal, acc) do
    case utf16_unit(data, endian) do
      :none ->
        {:ok, acc, data}

      {lead, rest} when lead in 0xD800..0xDBFF ->
        case utf16_unit(rest, endian) do
          :none ->
            {:ok, acc, data}

          {trail, rest} when trail in 0xDC00..0xDFFF ->
            code_point = 0x10000 + ((lead - 0xD800) <<< 10) + (trail - 0xDC00)
            decode_utf16(rest, endian, fatal, [acc, <<code_point::utf8>>])

          # The lead surrogate is an error. The unit after it is decoded
          # again as a new unit.
          {_unit, _rest} ->
            utf16_error(rest, endian, fatal, acc)
        end

      {trail, rest} when trail in 0xDC00..0xDFFF ->
        utf16_error(rest, endian, fatal, acc)

      {unit, rest} ->
        decode_utf16(rest, endian, fatal, [acc, <<unit::utf8>>])
    end
  end

  defp utf16_unit(<<unit::little-16, rest::binary>>, :little), do: {unit, rest}
  defp utf16_unit(<<unit::big-16, rest::binary>>, :big), do: {unit, rest}
  defp utf16_unit(_data, _endian), do: :none

  defp utf16_error(_rest, endian, true, _acc), do: {:error, invalid_data(utf16_name(endian))}

  defp utf16_error(rest, endian, false, acc) do
    decode_utf16(rest, endian, false, [acc, @replacement_char])
  end

  defp utf16_name(:little), do: "utf-16le"
  defp utf16_name(:big), do: "utf-16be"

  # At the end of the data, the bytes that are not complete are one error.
  defp flush_utf16(decoded, trailing, _fatal, true), do: {:ok, decoded, trailing}
  defp flush_utf16(decoded, "", _fatal, false), do: {:ok, decoded, ""}
  defp flush_utf16(_decoded, _trailing, true, false), do: {:error, invalid_data("utf-16")}

  defp flush_utf16(decoded, _trailing, false, false) do
    {:ok, [decoded, @replacement_char], ""}
  end

  defp invalid_data(encoding) do
    TypeError.exception("The encoded data was not valid #{encoding}")
  end

  defp split_stream_data(data, true), do: split_incomplete_utf8(data)
  defp split_stream_data(data, false), do: {data, ""}

  defp build_decode_result(state, decoded, bom_seen, trailing, decoder, complete, stream) do
    # Only the decoders of UTF-8 and UTF-16 remove a byte order mark.
    ignore_bom = decoder.ignore_bom or Encoding.kind(decoder.encoding) not in @bom_kinds

    {decoded, next_bom_seen} =
      maybe_strip_bom(decoded, bom_seen, ignore_bom, byte_size(complete), stream)

    next_state = next_decoder_state(state, trailing, next_bom_seen, stream)
    {{:ok, IO.iodata_to_binary(finish_decode(decoded))}, next_state}
  end

  defp next_decoder_state(state, trailing, bom_seen, true) do
    %{state | carry: :binary.copy(trailing), bom_seen: bom_seen}
  end

  # A call with no `stream` option is the end of the data. As in the
  # Encoding Standard, the decoder starts again: the subsequent call removes
  # a byte order mark again.
  defp next_decoder_state(state, _trailing, _bom_seen, false) do
    %{state | carry: "", bom_seen: false}
  end

  defp normalize_input(nil), do: ""
  defp normalize_input(input) when is_binary(input), do: input
  defp normalize_input(%Uint8Array{} = input), do: Uint8Array.to_binary(input)
  defp normalize_input(%Web.ArrayBuffer{} = input), do: Web.ArrayBuffer.data(input)

  defp normalize_input(_input) do
    raise TypeError, "TextDecoder.decode input must be a binary or Uint8Array"
  end

  defp decode_complete_bytes(binary, true) do
    if String.valid?(binary) do
      {:ok, binary}
    else
      {:error, invalid_data("utf-8")}
    end
  end

  defp decode_complete_bytes(binary, false), do: {:ok, replace_invalid(binary)}

  # The check of valid UTF-8 is fast for ASCII text. Only text that is not
  # valid needs the scan that replaces each invalid sequence.
  defp replace_invalid(binary) do
    if String.valid?(binary, :fast_ascii) do
      binary
    else
      String.replace_invalid(binary, @replacement_char)
    end
  end

  defp finish_decode(decoded), do: [decoded]

  defp maybe_strip_bom(decoded, true, _ignore_bom, _complete_size, _stream), do: {decoded, true}

  defp maybe_strip_bom(decoded, false, true, complete_size, _stream) do
    {decoded, complete_size > 0}
  end

  defp maybe_strip_bom(decoded, false, false, complete_size, stream) do
    cond do
      String.starts_with?(decoded, @bom) ->
        {String.replace_prefix(decoded, @bom, ""), true}

      complete_size > 0 ->
        {decoded, true}

      not stream ->
        {decoded, true}

      true ->
        {decoded, false}
    end
  end

  defp split_incomplete_utf8(""), do: {"", ""}

  defp split_incomplete_utf8(binary) do
    suffix_len = incomplete_suffix_length(binary)

    if suffix_len == 0 do
      {binary, ""}
    else
      split_at = byte_size(binary) - suffix_len
      prefix = :binary.part(binary, 0, split_at)
      suffix = binary |> :binary.part(split_at, suffix_len) |> :binary.copy()
      {prefix, suffix}
    end
  end

  defp incomplete_suffix_length(binary) do
    size = byte_size(binary)

    cond do
      size >= 3 and partial_suffix_len_3?(binary) ->
        3

      size >= 2 and partial_suffix_len_2?(binary) ->
        2

      size >= 1 and partial_suffix_len_1?(binary) ->
        1

      true ->
        0
    end
  end

  defp partial_suffix_len_1?(binary) do
    <<last>> = :binary.part(binary, byte_size(binary) - 1, 1)

    case expected_utf8_length(last) do
      expected when expected in [2, 3, 4] -> true
      _ -> false
    end
  end

  defp partial_suffix_len_2?(binary) do
    <<lead, continuation>> = :binary.part(binary, byte_size(binary) - 2, 2)

    case expected_utf8_length(lead) do
      expected when expected in [3, 4] ->
        continuation_byte?(continuation) and valid_utf8_second_byte?(lead, continuation)

      _ ->
        false
    end
  end

  defp partial_suffix_len_3?(binary) do
    <<lead, second, third>> = :binary.part(binary, byte_size(binary) - 3, 3)

    expected_utf8_length(lead) == 4 and
      continuation_byte?(second) and
      continuation_byte?(third) and
      valid_utf8_second_byte?(lead, second)
  end

  defp continuation_byte?(byte), do: (byte &&& 0xC0) == 0x80

  defp valid_utf8_second_byte?(0xE0, second), do: second in 0xA0..0xBF
  defp valid_utf8_second_byte?(lead, second) when lead in 0xE1..0xEC, do: second in 0x80..0xBF
  defp valid_utf8_second_byte?(0xED, second), do: second in 0x80..0x9F
  defp valid_utf8_second_byte?(lead, second) when lead in 0xEE..0xEF, do: second in 0x80..0xBF
  defp valid_utf8_second_byte?(0xF0, second), do: second in 0x90..0xBF
  defp valid_utf8_second_byte?(lead, second) when lead in 0xF1..0xF3, do: second in 0x80..0xBF
  defp valid_utf8_second_byte?(0xF4, second), do: second in 0x80..0x8F

  defp expected_utf8_length(byte) when byte in 0xC2..0xDF, do: 2
  defp expected_utf8_length(byte) when byte in 0xE0..0xEF, do: 3
  defp expected_utf8_length(byte) when byte in 0xF0..0xF4, do: 4
  defp expected_utf8_length(_byte), do: nil
end
