defmodule Web.Encoding do
  @moduledoc false
  # The encodings of the Encoding Standard: the labels, and the indexes of
  # the single-byte encodings. `Web.TextDecoder` uses this module.
  #
  # The data comes from two files of the Encoding Standard, which this
  # module reads when it compiles: `encoding/labels.txt` and
  # `encoding/single_byte_indexes.txt`. `Web.Encoding.MultiByte` has the
  # decoders of the multi-byte encodings, and `Web.Encoding.Indexes` has
  # their indexes.

  @labels_file Path.join(__DIR__, "encoding/labels.txt")
  @indexes_file Path.join(__DIR__, "encoding/single_byte_indexes.txt")
  @external_resource @labels_file
  @external_resource @indexes_file

  data_lines = fn file ->
    file
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.map(&String.split(&1, " "))
  end

  @labels (for [name | labels] <- data_lines.(@labels_file), label <- labels, into: %{} do
             {label, name}
           end)

  # For each single-byte encoding, a tuple with 256 entries: the UTF-8 form
  # of the code point of each byte, or `nil` for a byte with no code point.
  @single_byte (for [name | entries] <- data_lines.(@indexes_file), into: %{} do
                  128 = length(entries)

                  upper =
                    Enum.map(entries, fn
                      "-" -> nil
                      hex -> <<String.to_integer(hex, 16)::utf8>>
                    end)

                  {name, List.to_tuple(Enum.map(0..127, &<<&1>>) ++ upper)}
                end)

  @single_byte_names Map.keys(@single_byte)
  @multi_byte_names ~w[gbk gb18030 big5 euc-jp iso-2022-jp shift_jis euc-kr]
  @utf16 ["utf-16le", "utf-16be"]
  @supported ["utf-8", "x-user-defined"] ++ @utf16 ++ @single_byte_names ++ @multi_byte_names

  @doc """
  Gets an encoding from a label, as "get an encoding" of the Encoding
  Standard. Returns the name of the encoding in lowercase, or `:error` for
  a label that is not known.
  """
  @spec get(String.t()) :: {:ok, String.t()} | :error
  def get(label) when is_binary(label) do
    Map.fetch(@labels, label |> strip_ascii_whitespace() |> ascii_downcase())
  end

  @doc """
  Returns the names of the encodings that this library can decode: each
  encoding of the Encoding Standard other than replacement.
  """
  @spec supported() :: [String.t()]
  def supported, do: @supported

  @doc """
  Returns the kind of the decoder of an encoding.
  """
  @spec kind(String.t()) ::
          :utf8 | :utf16le | :utf16be | :user_defined | :single_byte | :multi_byte
  def kind("utf-8"), do: :utf8
  def kind("utf-16le"), do: :utf16le
  def kind("utf-16be"), do: :utf16be
  def kind("x-user-defined"), do: :user_defined
  def kind(name) when name in @single_byte_names, do: :single_byte
  def kind(name) when name in @multi_byte_names, do: :multi_byte

  @doc """
  Returns the table of a single-byte encoding: a tuple with 256 entries.
  The entry of a byte is the UTF-8 form of its code point, or `nil`.
  """
  @spec single_byte_table(String.t()) :: tuple()
  def single_byte_table(name), do: Map.fetch!(@single_byte, name)

  # ASCII whitespace of the Infra Standard: tab, line feed, form feed,
  # carriage return, and space.
  @whitespace [?\t, ?\n, ?\f, ?\r, ?\s]

  defp strip_ascii_whitespace(<<char, rest::binary>>) when char in @whitespace do
    strip_ascii_whitespace(rest)
  end

  defp strip_ascii_whitespace(label), do: strip_trailing(label, byte_size(label))

  defp strip_trailing(label, size) when size > 0 do
    if :binary.at(label, size - 1) in @whitespace,
      do: strip_trailing(label, size - 1),
      else: binary_part(label, 0, size)
  end

  defp strip_trailing(_label, 0), do: ""

  defp ascii_downcase(label) do
    for <<char <- label>>, into: "", do: <<if(char in ?A..?Z, do: char + 32, else: char)>>
  end
end
