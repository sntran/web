defmodule Web.WPT.QuickJS.DOMTest do
  # Runs the files of web-platform-tests for the DOM Standard:
  # `AbortController`, `AbortSignal`, `Event`, and `EventTarget`, with no
  # change, in QuickJS against the library. See `Web.Test.QuickJS.Bridge`, and
  # `Web.Test.QuickJS.WPT` for the lists of expected results.
  use ExUnit.Case, async: true

  # A file of WPT can have thousands of tests, and WPT gives some files a
  # long time limit (`META: timeout=long`).
  @moduletag timeout: 300_000

  alias Web.Test.QuickJS.WPT

  @files [
    "dom/abort/AbortSignal.any.js",
    "dom/abort/abort-signal-any.any.js",
    "dom/abort/event.any.js",
    "dom/abort/timeout.any.js",
    "dom/events/AddEventListenerOptions-once.any.js",
    "dom/events/AddEventListenerOptions-passive.any.js",
    "dom/events/AddEventListenerOptions-signal.any.js",
    "dom/events/Event-constructors.any.js",
    "dom/events/Event-isTrusted.any.js",
    "dom/events/EventTarget-add-remove-listener.any.js",
    "dom/events/EventTarget-addEventListener.any.js",
    "dom/events/EventTarget-constructible.any.js",
    "dom/events/EventTarget-removeEventListener.any.js"
  ]

  for path <- @files do
    test path do
      WPT.check!(unquote(path))
    end
  end
end
