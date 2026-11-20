defmodule Web.WPT.QuickJS.StreamsTest do
  # Runs the files of web-platform-tests for the Streams Standard, with no
  # change, in QuickJS against the library: `ReadableStream`,
  # `WritableStream`, `TransformStream`, their readers, writers, and
  # controllers, and the queuing strategies. See `Web.Test.QuickJS.Bridge`,
  # and `Web.Test.QuickJS.WPT` for the lists of expected results.
  #
  # Not in the list: the tests of garbage collection, of transfer between
  # windows, the tentative tests, and `idlharness.any.js`.
  use ExUnit.Case, async: true

  # A file of WPT can have thousands of tests, and WPT gives some files a
  # long time limit (`META: timeout=long`).
  @moduletag timeout: 300_000

  alias Web.Test.QuickJS.WPT

  @files [
    "streams/piping/abort.any.js",
    "streams/piping/close-propagation-backward.any.js",
    "streams/piping/close-propagation-forward.any.js",
    "streams/piping/error-propagation-backward.any.js",
    "streams/piping/error-propagation-forward.any.js",
    "streams/piping/flow-control.any.js",
    "streams/piping/general-addition.any.js",
    "streams/piping/general.any.js",
    "streams/piping/multiple-propagation.any.js",
    "streams/piping/pipe-through.any.js",
    "streams/piping/then-interception.any.js",
    "streams/piping/throwing-options.any.js",
    "streams/piping/transform-streams.any.js",
    "streams/queuing-strategies.any.js",
    "streams/readable-byte-streams/bad-buffers-and-views.any.js",
    "streams/readable-byte-streams/construct-byob-request.any.js",
    "streams/readable-byte-streams/enqueue-with-detached-buffer.any.js",
    "streams/readable-byte-streams/general.any.js",
    "streams/readable-byte-streams/patched-global.any.js",
    "streams/readable-byte-streams/read-min.any.js",
    "streams/readable-byte-streams/respond-after-enqueue.any.js",
    "streams/readable-byte-streams/tee.any.js",
    "streams/readable-byte-streams/templated.any.js",
    "streams/readable-streams/async-iterator.any.js",
    "streams/readable-streams/bad-strategies.any.js",
    "streams/readable-streams/bad-underlying-sources.any.js",
    "streams/readable-streams/cancel.any.js",
    "streams/readable-streams/constructor.any.js",
    "streams/readable-streams/count-queuing-strategy-integration.any.js",
    "streams/readable-streams/default-reader.any.js",
    "streams/readable-streams/floating-point-total-queue-size.any.js",
    "streams/readable-streams/from.any.js",
    "streams/readable-streams/general.any.js",
    "streams/readable-streams/patched-global.any.js",
    "streams/readable-streams/reentrant-strategies.any.js",
    "streams/readable-streams/tee.any.js",
    "streams/readable-streams/templated.any.js",
    "streams/transform-streams/backpressure.any.js",
    "streams/transform-streams/cancel.any.js",
    "streams/transform-streams/errors.any.js",
    "streams/transform-streams/flush.any.js",
    "streams/transform-streams/general.any.js",
    "streams/transform-streams/lipfuzz.any.js",
    "streams/transform-streams/patched-global.any.js",
    "streams/transform-streams/properties.any.js",
    "streams/transform-streams/reentrant-strategies.any.js",
    "streams/transform-streams/strategies.any.js",
    "streams/transform-streams/terminate.any.js",
    "streams/writable-streams/aborting.any.js",
    "streams/writable-streams/bad-strategies.any.js",
    "streams/writable-streams/bad-underlying-sinks.any.js",
    "streams/writable-streams/byte-length-queuing-strategy.any.js",
    "streams/writable-streams/close.any.js",
    "streams/writable-streams/constructor.any.js",
    "streams/writable-streams/count-queuing-strategy.any.js",
    "streams/writable-streams/error.any.js",
    "streams/writable-streams/floating-point-total-queue-size.any.js",
    "streams/writable-streams/general.any.js",
    "streams/writable-streams/properties.any.js",
    "streams/writable-streams/reentrant-strategy.any.js",
    "streams/writable-streams/start.any.js",
    "streams/writable-streams/write.any.js"
  ]

  for path <- @files do
    test path do
      WPT.check!(unquote(path))
    end
  end
end
