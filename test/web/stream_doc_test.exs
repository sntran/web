defmodule Web.StreamDocTest do
  # The examples in the documents of the stream modules.
  use ExUnit.Case, async: true

  doctest Web.ReadableStream
  doctest Web.ReadableStreamDefaultReader
  doctest Web.ReadableStreamDefaultController
  doctest Web.ReadableStreamAsyncIterator
  doctest Web.ReadableByteStreamController
  doctest Web.ReadableStreamBYOBReader
  doctest Web.ReadableStreamBYOBRequest
  doctest Web.WritableStream
  doctest Web.WritableStreamDefaultController
  doctest Web.TransformStream
  doctest Web.TransformStreamDefaultController
  doctest Web.TextEncoderStream
  doctest Web.TextEncoder
  doctest Web.TextDecoder
  doctest Web.CompressionStream
  doctest Web.DecompressionStream
end
