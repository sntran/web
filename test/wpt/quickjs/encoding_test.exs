defmodule Web.WPT.QuickJS.EncodingTest do
  # Runs the files of web-platform-tests for the Encoding Standard: `TextEncoder` and `TextDecoder`, with no change, in
  # QuickJS against the library. See `Web.Test.QuickJS.Bridge`, and
  # `Web.Test.QuickJS.WPT` for the lists of expected results.
  use ExUnit.Case, async: true

  # A file of WPT can have thousands of tests, and WPT gives some files a
  # long time limit (`META: timeout=long`).
  @moduletag timeout: 300_000

  alias Web.Test.QuickJS.WPT

  @files [
    "encoding/api-basics.any.js",
    "encoding/api-invalid-label.any.js",
    "encoding/api-replacement-encodings.any.js",
    "encoding/api-surrogates-utf8.any.js",
    "encoding/encodeInto-tail-unmodified.any.js",
    "encoding/encodeInto.any.js",
    "encoding/iso-2022-jp-decoder.any.js",
    "encoding/legacy-mb-schinese/gb18030/gb18030-decoder.any.js",
    "encoding/legacy-mb-schinese/gbk/gbk-decoder.any.js",
    "encoding/replacement-encodings.any.js",
    "encoding/single-byte-decoder.any.js",
    "encoding/streams/backpressure.any.js",
    "encoding/streams/decode-attributes.any.js",
    "encoding/streams/decode-bad-chunks.any.js",
    "encoding/streams/decode-ignore-bom.any.js",
    "encoding/streams/decode-incomplete-input.any.js",
    "encoding/streams/decode-non-utf8.any.js",
    "encoding/streams/decode-split-character.any.js",
    "encoding/streams/decode-utf8.any.js",
    "encoding/streams/encode-bad-chunks.any.js",
    "encoding/streams/encode-utf8.any.js",
    "encoding/streams/readable-writable-properties.any.js",
    "encoding/textdecoder-arguments.any.js",
    "encoding/textdecoder-byte-order-marks.any.js",
    "encoding/textdecoder-copy.any.js",
    "encoding/textdecoder-eof.any.js",
    "encoding/textdecoder-fatal-single-byte.any.js",
    "encoding/textdecoder-fatal-streaming.any.js",
    "encoding/textdecoder-fatal.any.js",
    "encoding/textdecoder-ignorebom.any.js",
    "encoding/textdecoder-labels.any.js",
    "encoding/textdecoder-mistakes.any.js",
    "encoding/textdecoder-streaming.any.js",
    "encoding/textdecoder-utf16-surrogates.any.js",
    "encoding/textencoder-constructor-non-utf.any.js",
    "encoding/textencoder-utf16-surrogates.any.js",
    "encoding/unsupported-encodings.any.js"
  ]

  for path <- @files do
    test path do
      WPT.check!(unquote(path))
    end
  end
end
