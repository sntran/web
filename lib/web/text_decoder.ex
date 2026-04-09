defmodule Web.TextDecoder do
  @moduledoc """
  WHATWG-style UTF-8 text decoder with streaming support.

  Supports `fatal` and `ignoreBOM` options and preserves trailing partial
  UTF-8 bytes across streamed `decode/3` calls.
  """

  import Bitwise

  alias Web.TypeError
  alias Web.Uint8Array

  @bom <<0xEF, 0xBB, 0xBF>>
  @replacement_char <<0xEF, 0xBF, 0xBD>>
  @utf8_labels MapSet.new(["utf-8", "utf8", "unicode-1-1-utf-8"])

  defstruct [:encoding, :state_pid, :fatal, :ignore_bom]

  @type t :: %__MODULE__{
          encoding: String.t(),
          state_pid: pid(),
          fatal: boolean(),
          ignore_bom: boolean()
        }

  @type options :: %{optional(:fatal) => boolean(), optional(:ignoreBOM) => boolean()}
  @type decode_options :: %{optional(:stream) => boolean()}

  @spec new(String.t(), options()) :: t()
  def new(label \\ "utf-8", options \\ %{}) do
    encoding = normalize_label(label)
    fatal = Map.get(options, :fatal, false)
    ignore_bom = Map.get(options, :ignoreBOM, false)

    unless MapSet.member?(@utf8_labels, encoding) do
      raise TypeError, "TextDecoder only supports UTF-8"
    end

    {:ok, state_pid} = Agent.start_link(fn -> %{carry: "", bom_seen: false} end)
    %__MODULE__{encoding: "utf-8", state_pid: state_pid, fatal: fatal, ignore_bom: ignore_bom}
  end

  @spec decode(t(), binary() | Uint8Array.t(), decode_options()) :: String.t()
  def decode(%__MODULE__{} = decoder, input, options \\ %{}) do
    stream = Map.get(options, :stream, false)
    chunk = normalize_input(input)

    case Agent.get_and_update(decoder.state_pid, fn %{carry: carry, bom_seen: bom_seen} = state ->
           data = IO.iodata_to_binary([carry, chunk])
           {complete, trailing} = if stream, do: split_incomplete_utf8(data), else: {data, ""}

           case decode_complete_bytes(complete, decoder.fatal) do
             {:ok, decoded} ->
               {decoded, next_bom_seen} =
                 maybe_strip_bom(
                   decoded,
                   bom_seen,
                   decoder.ignore_bom,
                   byte_size(complete),
                   stream
                 )

               next_state =
                 if stream do
                   %{state | carry: :binary.copy(trailing), bom_seen: next_bom_seen}
                 else
                   %{state | carry: "", bom_seen: next_bom_seen}
                 end

               {{:ok, IO.iodata_to_binary(finish_decode(decoded))}, next_state}

             {:error, error} ->
               {{:error, error}, state}
           end
         end) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_label(_label) do
    raise TypeError, "TextDecoder label must be a string"
  end

  defp normalize_input(input) when is_binary(input), do: input
  defp normalize_input(%Uint8Array{} = input), do: Uint8Array.to_binary(input)

  defp normalize_input(_input) do
    raise TypeError, "TextDecoder.decode input must be a binary or Uint8Array"
  end

  defp decode_complete_bytes(binary, true) do
    if String.valid?(binary) do
      {:ok, binary}
    else
      {:error, TypeError.exception("The encoded data was not valid UTF-8")}
    end
  end

  defp decode_complete_bytes(binary, false) do
    {:ok, String.replace_invalid(binary, @replacement_char)}
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
