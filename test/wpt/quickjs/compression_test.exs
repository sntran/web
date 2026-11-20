defmodule Web.WPT.QuickJS.CompressionTest do
  # Runs the files of web-platform-tests for the Compression Standard:
  # `CompressionStream` and `DecompressionStream`, with no change, in QuickJS
  # against the library. See `Web.Test.QuickJS.Bridge`, and
  # `Web.Test.QuickJS.WPT` for the lists of expected results.
  use ExUnit.Case, async: true

  # A file of WPT can have thousands of tests, and WPT gives some files a
  # long time limit (`META: timeout=long`).
  @moduletag timeout: 300_000

  alias Web.Test.QuickJS.WPT

  @files [
    "compression/compression-bad-chunks.any.js",
    "compression/compression-constructor-error.any.js",
    "compression/compression-including-empty-chunk.any.js",
    "compression/compression-large-flush-output.any.js",
    "compression/compression-multiple-chunks.any.js",
    "compression/compression-output-length.any.js",
    "compression/compression-stream.any.js",
    "compression/compression-with-detach.any.js",
    "compression/decompression-bad-chunks.any.js",
    "compression/decompression-buffersource.any.js",
    "compression/decompression-constructor-error.any.js",
    "compression/decompression-correct-input.any.js",
    "compression/decompression-corrupt-input.any.js",
    "compression/decompression-empty-input.any.js",
    "compression/decompression-extra-input.any.js",
    "compression/decompression-split-chunk.any.js",
    "compression/decompression-uint8array-output.any.js",
    "compression/decompression-with-detach.any.js"
  ]

  for path <- @files do
    test path do
      WPT.check!(unquote(path))
    end
  end
end
