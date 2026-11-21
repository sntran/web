defmodule Web.BlobTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Blob

  doctest Web.File

  test "new/2 computes size and normalizes type" do
    blob = Blob.new(["hello", " ", "world"], type: "Text/Plain")

    assert blob.size == 11
    assert blob.type == "text/plain"
  end

  test "new/2 supports nested blobs and non-binary type values" do
    inner = Blob.new(["bc"])
    outer = Blob.new(["a", inner, "d"], type: :APPLICATION_JSON)

    assert outer.size == 4
    assert outer.type == "application_json"
    assert Blob.to_binary(outer) == "abcd"
  end

  test "new/2 treats nil type as empty string" do
    blob = Blob.new(["hello"], type: nil)
    assert blob.type == ""
  end

  test "slice/4 supports default finish and content type" do
    blob = Blob.new(["hello"])

    sliced = Blob.slice(blob, 1)

    assert sliced.size == 4
    assert sliced.type == ""
    assert Blob.to_binary(sliced) == "ello"
  end

  test "slice/4 supports negative indices and clamps to bounds" do
    blob = Blob.new(["hello"])

    sliced = Blob.slice(blob, -4, 10, "text/plain")

    assert sliced.size == 4
    assert sliced.type == "text/plain"
    assert Blob.to_binary(sliced) == "ello"
  end

  test "slice/4 returns empty blob when end is before start" do
    blob = Blob.new(["hello"])

    sliced = Blob.slice(blob, 4, 2, "text/plain")

    assert sliced.size == 0
    assert Blob.to_binary(sliced) == ""
  end

  test "slice/4 extracts full part unchanged when boundaries align" do
    blob = Blob.new(["alpha", "beta", "gamma"])

    sliced = Blob.slice(blob, 5, 9, "text/plain")

    assert sliced.size == 4
    assert Blob.to_binary(sliced) == "beta"
  end

  test "slice/4 extracts partial binary from multi-part blob" do
    blob = Blob.new(["hello", "world", "test"])

    sliced = Blob.slice(blob, 3, 12, "text/plain")

    assert sliced.size == 9
    assert Blob.to_binary(sliced) == "loworldte"
  end

  test "slice/4 on nested blob extracts full nested blob unchanged" do
    inner = Blob.new(["nested"])
    outer = Blob.new(["pre", inner, "post"])

    sliced = Blob.slice(outer, 3, 9, "text/plain")

    assert sliced.size == 6
    assert Blob.to_binary(sliced) == "nested"
  end

  test "slice/4 on nested blob partial extract recurses" do
    inner = Blob.new(["nested"])
    outer = Blob.new(["pre", inner, "post"])

    sliced = Blob.slice(outer, 4, 8, "text/plain")

    assert sliced.size == 4
    assert Blob.to_binary(sliced) == "este"
  end

  test "slice/4 skips parts outside range" do
    blob = Blob.new(["a", "b", "c", "d", "e"])

    sliced = Blob.slice(blob, 2, 4, "text/plain")

    assert sliced.size == 2
    assert Blob.to_binary(sliced) == "cd"
  end

  test "slice/4 returns exact part as-is when boundaries match part boundary" do
    blob = Blob.new(["part1", "part2", "part3"])

    sliced = Blob.slice(blob, 0, 5, "text/plain")

    assert sliced.size == 5
    assert Blob.to_binary(sliced) == "part1"
  end

  test "slice/4 returns nested blob as-is when fully contained" do
    inner = Blob.new(["inner"])
    outer = Blob.new(["pre_", inner, "_post"])

    sliced = Blob.slice(outer, 4, 9, "text/plain")

    assert sliced.size == 5
    assert Blob.to_binary(sliced) == "inner"
  end

  test "slice/4 with exact single-part blob extract" do
    blob = Blob.new(["fullpart"])

    sliced = Blob.slice(blob, 0, 8)

    assert sliced.size == 8
    assert sliced.parts == ["fullpart"]
    assert Blob.to_binary(sliced) == "fullpart"
  end

  test "slice/4 with nested blob exact extract" do
    inner = Blob.new(["content"])
    outer = Blob.new([inner])

    sliced = Blob.slice(outer, 0, 7)

    assert sliced.size == 7
    assert Blob.to_binary(sliced) == "content"
  end

  test "slice/4 returns zero-size blob when range starts at end" do
    blob = Blob.new(["a", "b", "c"])

    sliced = Blob.slice(blob, 3, 3)

    assert sliced.size == 0
    assert sliced.parts == []
  end

  test "slice/4 with mixed types in parts list exercises full reduction" do
    inner = Blob.new(["mid"])
    blob = Blob.new(["start", inner, "end"])

    sliced = Blob.slice(blob, 2, 11)

    assert sliced.size == 9
    assert Blob.to_binary(sliced) == "artmidend"
  end

  test "slice/4 exercising each case branch in slice_part" do
    # Create a multi-part blob where a part falls at exact boundary
    blob = Blob.new(["ab", "cd", "ef"])

    # Slice from middle of first part through middle of third part
    # This ensures multiple parts are involved
    sliced = Blob.slice(blob, 1, 5)

    assert sliced.size == 4
    assert Blob.to_binary(sliced) == "bcde"
  end

  test "stream/1 returns a readable stream over blob contents" do
    blob = Blob.new(["hel", "lo"])

    assert "hello" == blob |> Blob.stream() |> Web.TestBytes.join()
  end

  test "text/json/array_buffer/bytes can be called multiple times" do
    blob = Blob.new([~s({"id":1})], type: "application/json")

    assert {:ok, ~s({"id":1})} = Blob.text(blob)
    assert {:ok, %{"id" => 1}} = Blob.json(blob)
    assert {:ok, %Web.ArrayBuffer{byte_length: 8}} = Blob.array_buffer(blob)

    assert {:ok, %Web.Uint8Array{} = bytes} = Blob.bytes(blob)
    assert Web.Uint8Array.to_binary(bytes) == ~s({"id":1})

    assert {:ok, ~s({"id":1})} = Blob.text(blob)
  end

  describe "the rules of the File API" do
    property "the type is ASCII lowercase, or empty with a character outside U+0020 to U+007E" do
      check all(type <- string(:utf8, max_length: 12)) do
        printable? = String.to_charlist(type) |> Enum.all?(&(&1 in 0x20..0x7E))
        expected = if printable?, do: String.downcase(type, :ascii), else: ""

        assert Blob.new([], type: type).type == expected
        assert Blob.slice(Blob.new(["a"]), 0, 1, type).type == expected
        assert Web.File.new([], "a", type: type).type == expected
      end
    end

    test "the type has no lowercase of Unicode" do
      assert Blob.new([], type: "İmage/gif").type == ""
      assert Blob.new([], type: "TEXT/Plain;Charset=UTF-8").type == "text/plain;charset=utf-8"
    end

    property "slice/4 gives the bytes of the steps slice blob" do
      check all(
              parts <- list_of(binary(max_length: 6), max_length: 4),
              start <- one_of([constant(nil), integer(-30..30)]),
              finish <- one_of([constant(nil), integer(-30..30)])
            ) do
        bytes = IO.iodata_to_binary(parts)
        size = byte_size(bytes)
        relative = fn index -> if index < 0, do: max(size + index, 0), else: min(index, size) end
        from = relative.(start || 0)
        to = if finish == nil, do: size, else: relative.(finish)
        expected = binary_part(bytes, from, max(to - from, 0))

        blob = Blob.new(Enum.map(parts, &Blob.new([&1])))
        assert Blob.to_binary(Blob.slice(blob, start, finish)) == expected
      end
    end

    test "slice/1 gives all the bytes, with no type" do
      sliced = Blob.slice(Blob.new(["abc"], type: "text/plain"))

      assert {sliced.size, sliced.type, Blob.to_binary(sliced)} == {3, "", "abc"}
    end

    test "a file is a blob: its bytes, its slices, and its streams" do
      file = Web.File.new(["héllo"], "a.txt", type: "text/plain")
      blob = Blob.new([file, "!"])

      assert Blob.to_binary(blob) == "héllo!"
      assert {:ok, "héllo"} = Blob.text(file)
      assert Blob.to_binary(Blob.slice(file, 1)) == "éllo"
      assert file |> Blob.stream() |> Web.TestBytes.join() == "héllo"
      assert file |> Blob.text_stream() |> Enum.join() == "héllo"
    end

    test "a file from a stream gives the bytes of the stream" do
      stream = Web.ReadableStream.from(["ab", "c"])
      file = %{Web.File.new([], "s.bin") | stream: stream, size: nil}

      assert {:ok, "abc"} = Blob.text(file)
    end

    test "stream/1 is a byte stream: a reader of the mode byob reads it" do
      bytes = :binary.copy("x", 70_000)
      reader = Blob.new([bytes]) |> Blob.stream() |> Web.ReadableStream.get_reader(mode: "byob")

      read = fn read ->
        view = Web.Uint8Array.new(Web.ArrayBuffer.new(50_000))

        case Web.await(Web.ReadableStreamBYOBReader.read(reader, view)) do
          %{done: true} -> []
          %{value: value} -> [Web.Uint8Array.to_binary(value) | read.(read)]
        end
      end

      chunks = read.(read)
      assert IO.iodata_to_binary(chunks) == bytes
      assert length(chunks) > 1

      # A chunk has the bytes of one part. A part of a nested blob is a part.
      nested = Blob.new(["", Blob.new(["ab", Blob.new(["c"])]), "d"])

      assert nested |> Blob.stream() |> Enum.map(&Web.Uint8Array.to_binary/1) ==
               ["ab", "c", "d"]
    end

    test "text_stream/1 decodes UTF-8 and ignores the charset of the type" do
      blob =
        Blob.new([<<0xEF, 0xBB, 0xBF>>, "a", <<0xC3>>, <<0xA9, 0xFF>>],
          type: "text/plain;charset=latin1"
        )

      assert blob |> Blob.text_stream() |> Enum.join() == "aé\uFFFD"
      assert Blob.new([]) |> Blob.text_stream() |> Enum.to_list() == []
    end
  end

  describe "File" do
    property "new/3 has the bits, the name, and the options of FilePropertyBag" do
      check all(
              parts <- list_of(binary(max_length: 6), max_length: 4),
              name <- string(:printable, max_length: 12),
              last_modified <- integer()
            ) do
        file = Web.File.new(parts, name, type: "Text/Plain", last_modified: last_modified)

        assert file.name == name
        assert file.type == "text/plain"
        assert file.last_modified == last_modified
        assert file.size == IO.iodata_length(parts)
        assert Blob.to_binary(file) == IO.iodata_to_binary(parts)
      end
    end

    test "new/3 has the time of the last change: the option, or the time now" do
      before = System.os_time(:millisecond)
      file = Web.File.new(["a"], "a.txt")

      assert file.last_modified >= before
      assert file.last_modified <= System.os_time(:millisecond)
      assert Web.File.new([], "a.txt", last_modified: -5).last_modified == -5
      assert {file.name, file.type} == {"a.txt", ""}
    end

    property "new/3 takes the name of the file as a string, not in the options" do
      # The old form `new(parts, filename: name)` has a keyword list there.
      not_a_string =
        one_of([
          keyword_of(string(:printable)),
          constant(nil),
          atom(:alphanumeric),
          integer(),
          list_of(integer(0..255))
        ])

      check all(name <- not_a_string) do
        assert_raise FunctionClauseError, fn -> Web.File.new(["a"], name) end
      end

      refute Map.has_key?(Web.File.new(["a"], "a.txt"), :filename)
    end

    test "FormData makes a new File for a blob, and for a file with a new name" do
      blob = Blob.new(["a"], type: "text/plain")
      file = Web.File.new(["b"], "b.txt", last_modified: 123)

      form =
        Web.FormData.new()
        |> Web.FormData.append("blob", blob)
        |> Web.FormData.append("named", blob, "named.txt")
        |> Web.FormData.append("file", file)
        |> Web.FormData.append("renamed", file, "c.txt")

      assert %Web.File{name: "blob", type: "text/plain", size: 1} =
               Web.FormData.get(form, "blob")

      assert %Web.File{name: "named.txt"} = Web.FormData.get(form, "named")
      assert Web.FormData.get(form, "file") == file

      renamed = Web.FormData.get(form, "renamed")
      assert %Web.File{name: "c.txt", last_modified: 123} = renamed
      assert Blob.to_binary(renamed) == "b"
      refute renamed.id == file.id
    end
  end
end
