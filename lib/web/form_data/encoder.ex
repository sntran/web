defmodule Web.FormData.Encoder do
  @moduledoc false
  # The `multipart/form-data` encoding algorithm of the HTML Standard, which
  # the Fetch Standard uses for a body that is a `FormData`.
  #
  # The result is a lazy enumerable of binaries. The bytes of a file are read
  # from its stream chunk by chunk, thus a form with large files does not
  # fill the memory.

  alias Web.File
  alias Web.FormData
  alias Web.Internal.Bytes

  @doc """
  Returns the encoded form as an enumerable of binaries.
  """
  @spec encode(FormData.t()) :: Enumerable.t()
  def encode(%FormData{boundary: boundary} = form) do
    parts = Stream.flat_map(form, fn [name, value] -> part(boundary, name, value) end)
    Stream.concat(parts, ["--" <> boundary <> "--\r\n"])
  end

  # A part with a file: the headers, the bytes of the file, and the end of
  # the part.
  defp part(boundary, name, %File{} = file) do
    headers =
      IO.iodata_to_binary([
        ["--", boundary, "\r\n"],
        ["Content-Disposition: form-data; name=\"", escape(normalize_newlines(name)), "\""],
        ["; filename=\"", escape(file.filename || "blob"), "\"\r\n"],
        ["Content-Type: ", content_type(file), "\r\n\r\n"]
      ])

    bytes = file |> File.stream() |> Stream.map(&Bytes.to_binary!(&1, "The file of a form"))
    Stream.concat([[headers], bytes, ["\r\n"]])
  end

  # A part with a string.
  defp part(boundary, name, value) when is_binary(value) do
    [
      IO.iodata_to_binary([
        ["--", boundary, "\r\n"],
        ["Content-Disposition: form-data; name=\"", escape(normalize_newlines(name)), "\"\r\n"],
        ["\r\n", normalize_newlines(value), "\r\n"]
      ])
    ]
  end

  defp content_type(%File{type: type}) when type in [nil, ""], do: "application/octet-stream"
  defp content_type(%File{type: type}), do: type

  # Each line end becomes CR LF: a CR with no LF after it, and a LF with no
  # CR before it.
  defp normalize_newlines(text), do: String.replace(text, ~r/\r\n|\r|\n/, "\r\n")

  # A field name and a file name are in quotation marks. These three bytes
  # cannot be there with no change.
  defp escape(text) do
    text
    |> String.replace("\n", "%0A")
    |> String.replace("\r", "%0D")
    |> String.replace("\"", "%22")
  end

  @doc """
  Reverses `escape/1`. The parser of a form uses this function for a field
  name and a file name, thus a form that is encoded and then parsed has the
  same names.
  """
  @spec unescape(String.t()) :: String.t()
  def unescape(text) do
    text
    |> String.replace("%0A", "\n")
    |> String.replace("%0D", "\r")
    |> String.replace("%22", "\"")
  end
end
