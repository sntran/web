defmodule Web.FormDataEncoderTest do
  # The `multipart/form-data` encoding of a `FormData` body, as the Fetch
  # Standard and the HTML Standard specify.
  use ExUnit.Case, async: true
  use ExUnitProperties
  use Web

  alias Web.FormData.Encoder

  doctest Web.FormData

  defp form(entries, boundary \\ "test-boundary") do
    Enum.reduce(entries, %{FormData.new() | boundary: boundary}, fn
      {name, value}, form -> FormData.append(form, name, value)
      {name, value, filename}, form -> FormData.append(form, name, value, filename)
    end)
  end

  defp encode(form), do: form |> Encoder.encode() |> Enum.join()

  # Reads the entries of a form. A file becomes `{:file, name, type, bytes}`.
  defp entries(form) do
    Enum.map(form, fn
      [name, %Web.File{} = file] ->
        {name, {:file, file.name, file.type, Web.TestBytes.join(Web.File.stream(file))}}

      [name, value] ->
        {name, value}
    end)
  end

  defp round_trip(form), do: entries(await(Response.form_data(Response.new(form))))

  describe "the encoding" do
    test "gives the parts of the HTML Standard, for a string and for a file" do
      file = Web.File.new(["file ", "bytes"], "notes.txt", type: "text/plain")
      form = form([{"field", "value"}, {"upload", file}])

      assert encode(form) ==
               "--test-boundary\r\n" <>
                 "Content-Disposition: form-data; name=\"field\"\r\n" <>
                 "\r\n" <>
                 "value\r\n" <>
                 "--test-boundary\r\n" <>
                 ~s(Content-Disposition: form-data; name="upload"; filename="notes.txt"\r\n) <>
                 "Content-Type: text/plain\r\n" <>
                 "\r\n" <>
                 "file bytes\r\n" <>
                 "--test-boundary--\r\n"
    end

    test "gives the name of the file of each entry as the parameter filename" do
      file = Web.File.new(["x"], "old.txt", type: "text/plain")
      encoded = encode(form([{"same", file}, {"new", file, "new.txt"}]))

      assert encoded =~ ~s(name="same"; filename="old.txt"\r\n)
      assert encoded =~ ~s(name="new"; filename="new.txt"\r\n)
    end

    test "gives only the last boundary for a form with no entries" do
      assert encode(form([])) == "--test-boundary--\r\n"
    end

    test "gives the type application/octet-stream to a file with no type" do
      encoded = encode(form([{"upload", Web.Blob.new(["bytes"])}]))

      assert encoded =~ "name=\"upload\"; filename=\"blob\"\r\n"
      assert encoded =~ "Content-Type: application/octet-stream\r\n\r\nbytes\r\n"
    end

    test "changes each line end of a name and of a string to CR LF" do
      encoded = encode(form([{"a\nb\rc\r\nd", "1\n2\r3\r\n4"}]))

      assert encoded =~ "name=\"a%0D%0Ab%0D%0Ac%0D%0Ad\"\r\n"
      assert encoded =~ "\r\n\r\n1\r\n2\r\n3\r\n4\r\n--test-boundary--"
    end

    test "escapes a quotation mark and a line end in a name and in a file name" do
      file = Web.File.new(["x"], "a\"b\nc\rd.txt")
      encoded = encode(form([{"q\"uote", file}]))

      # A line end of a file name is not changed to CR LF. It is only escaped.
      assert encoded =~ "name=\"q%22uote\"; filename=\"a%22b%0Ac%0Dd.txt\"\r\n"
    end

    test "does not change the bytes of a file" do
      bytes = <<0, 255, ?\r, ?\n, ?-, ?-, 13, 10, 10>>
      file = Web.File.new([bytes], "data.bin")

      assert encode(form([{"upload", file}])) =~ "\r\n\r\n" <> bytes <> "\r\n--test-boundary--"
    end

    test "reads the stream of a file chunk by chunk" do
      stream = ReadableStream.from(["ab", Uint8Array.from("cd"), ArrayBuffer.new("ef")])
      file = %{Web.File.new([], "stream.txt") | stream: stream, size: nil}
      chunks = Enum.to_list(Encoder.encode(form([{"upload", file}])))

      assert Enum.slice(chunks, 1, 3) == ["ab", "cd", "ef"]
      assert Enum.all?(chunks, &is_binary/1)
    end
  end

  describe "a body that is a form" do
    test "has the content type with the boundary, and Uint8Array chunks" do
      form = form([{"field", "value"}])

      for carrier <- [
            Response.new(form),
            Request.new("https://example.com/", method: "POST", body: form)
          ] do
        assert Headers.get(carrier.headers, "content-type") ==
                 "multipart/form-data; boundary=test-boundary"

        chunks = Enum.to_list(carrier.body)
        assert Enum.all?(chunks, &match?(%Uint8Array{}, &1))
        assert Web.TestBytes.join(chunks) == encode(form)
      end
    end

    test "keeps a content type that the caller gives" do
      response = Response.new(form([]), headers: %{"content-type" => "text/plain"})
      assert Headers.get(response.headers, "content-type") == "text/plain"
    end

    test "needs no option duplex, and has a source when its data is in memory" do
      form = form([{"field", "value"}, {"upload", Web.Blob.new(["bytes"])}])
      request = Request.new("https://example.com/", method: "POST", body: form)
      assert request.body_source == form

      # A file with a stream can be read only one time.
      stream_file = %{Web.File.new([], "s") | stream: ReadableStream.from(["x"])}

      request =
        Request.new("https://example.com/", method: "POST", body: form([{"f", stream_file}]))

      assert request.body_source == nil

      # A form that was parsed from a stream reads its entries one time.
      parsed = await(Response.form_data(Response.new(form)))
      request = Request.new("https://example.com/", method: "POST", body: parsed)
      assert request.body_source == nil
      assert Web.TestBytes.join(request.body) =~ ~s(name="field")
    end

    test "gives the same entries when it is parsed" do
      file = Web.File.new([<<0, 1, 2>>, "text"], "a \"b\".bin", type: "application/x-test")

      form =
        form([
          {"plain", "value"},
          {"empty", ""},
          {"multi\nline", "one\ntwo"},
          {"quote\"name", "value"},
          {"unicode é 日本", "värde 😀"},
          {"upload", file},
          {"plain", "second value"}
        ])

      assert round_trip(form) == [
               {"plain", "value"},
               {"empty", ""},
               {"multi\r\nline", "one\r\ntwo"},
               {"quote\"name", "value"},
               {"unicode é 日本", "värde 😀"},
               {"upload", {:file, "a \"b\".bin", "application/x-test", <<0, 1, 2, "text">>}},
               {"plain", "second value"}
             ]
    end

    test "keeps each backslash of a name and of a file name" do
      file = Web.File.new(["x"], "C:\\dir\\file.txt")
      unc = Web.File.new(["y"], "\\\\server\\share\\")
      form = form([{"dir\\name", "value"}, {"upload", file}, {"end\\", "w"}, {"unc\\", unc}])

      assert round_trip(form) == [
               {"dir\\name", "value"},
               {"upload", {:file, "C:\\dir\\file.txt", "application/octet-stream", "x"}},
               {"end\\", "w"},
               {"unc\\", {:file, "\\\\server\\share\\", "application/octet-stream", "y"}}
             ]
    end

    test "cannot tell the text of an escape in a name from the escape, as in the Standard" do
      # The HTML Standard does not escape a percent sign. Thus these two
      # names have the same encoding, and the parser gives the second one.
      assert encode(form([{"a%22b", "v"}])) == encode(form([{"a\"b", "v"}]))
      assert round_trip(form([{"a%22b", "v"}])) == [{"a\"b", "v"}]

      # The text of a string value has no escapes.
      assert round_trip(form([{"name", "100%22"}])) == [{"name", "100%22"}]
    end

    test "encodes a form that was parsed from a stream, with its file streams" do
      first = form([{"field", "value"}, {"upload", Web.Blob.new([String.duplicate("x", 5_000)])}])
      parsed = await(Response.form_data(Response.new(first)))

      # The parsed form reads its files from the first body. It is encoded
      # again with a new boundary, and gives the same entries.
      assert parsed.coordinator
      second = Response.new(parsed)

      assert entries(await(Response.form_data(second))) == [
               {"field", "value"},
               {"upload",
                {:file, "blob", "application/octet-stream", String.duplicate("x", 5_000)}}
             ]
    end

    property "gives the same entries when it is parsed, for each form" do
      # The characters that the encoding and the parser handle specially
      # occur frequently.
      special = member_of(["\\", "\"", "\r", "\n", "%", ";", "=", " "])
      char = one_of([special, string(:printable, length: 1)])

      # The text of an escape in a name cannot be told from the escape: see
      # the test for that. Thus the property does not use such names.
      name =
        list_of(char, min_length: 1, max_length: 8)
        |> map(&Enum.join/1)
        |> filter(&(not String.contains?(&1, ["%0A", "%0D", "%22"])))

      text = map(list_of(char, max_length: 12), &Enum.join/1)

      file =
        gen all(
              bytes <- binary(max_length: 64),
              filename <- name,
              type <- member_of(["", "text/plain", "application/x-test"])
            ) do
          {:file, filename, type, bytes}
        end

      check all(entries <- list_of({name, one_of([text, file])}, max_length: 6), max_runs: 60) do
        form =
          Enum.reduce(entries, FormData.new(), fn
            {name, {:file, filename, type, bytes}}, form ->
              FormData.append(form, name, Web.File.new([bytes], filename, type: type))

            {name, value}, form ->
              FormData.append(form, name, value)
          end)

        expected =
          Enum.map(entries, fn
            {name, {:file, filename, type, bytes}} ->
              type = if type == "", do: "application/octet-stream", else: type
              {newlines(name), {:file, filename, type, bytes}}

            {name, value} ->
              {newlines(name), newlines(value)}
          end)

        assert round_trip(form) == expected
      end
    end
  end

  # The line ends of a name and of a string become CR LF.
  defp newlines(text), do: String.replace(text, ~r/\r\n|\r|\n/, "\r\n")
end
