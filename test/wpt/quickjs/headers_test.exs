defmodule Web.WPT.QuickJS.HeadersTest do
  # Runs the files of web-platform-tests for the Fetch Standard: `Headers`, with no change, in
  # QuickJS against the library. See `Web.Test.QuickJS.Bridge`, and
  # `Web.Test.QuickJS.WPT` for the lists of expected results.
  use ExUnit.Case, async: true

  alias Web.Test.QuickJS.WPT

  @files [
    "fetch/api/headers/header-setcookie.any.js",
    "fetch/api/headers/header-values-last-event-id.any.js",
    "fetch/api/headers/header-values-normalize.any.js",
    "fetch/api/headers/header-values.any.js",
    "fetch/api/headers/headers-basic.any.js",
    "fetch/api/headers/headers-casing.any.js",
    "fetch/api/headers/headers-combine.any.js",
    "fetch/api/headers/headers-errors.any.js",
    "fetch/api/headers/headers-forbidden-override.any.js",
    "fetch/api/headers/headers-no-cors.any.js",
    "fetch/api/headers/headers-normalize.any.js",
    "fetch/api/headers/headers-record.any.js",
    "fetch/api/headers/headers-structure.any.js"
  ]

  for path <- @files do
    test path do
      WPT.check!(unquote(path))
    end
  end
end
