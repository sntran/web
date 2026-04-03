defmodule Web.BlobTest do
  use ExUnit.Case, async: true

  alias Web.Blob

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
end
