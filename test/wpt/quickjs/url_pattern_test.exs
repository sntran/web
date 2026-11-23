defmodule Web.WPT.QuickJS.URLPatternTest do
  # Runs the files of web-platform-tests for the URL Pattern Standard:
  # `URLPattern`, with no change, in QuickJS against the library. See
  # `Web.Test.QuickJS.Bridge`, and `Web.Test.QuickJS.WPT` for the lists of
  # expected results.
  #
  # Not in the list: `urlpattern.https.any.js`, the same tests in a page of
  # HTTPS.
  use ExUnit.Case, async: true

  # A file of WPT can have thousands of tests, and WPT gives some files a
  # long time limit (`META: timeout=long`).
  @moduletag timeout: 300_000

  alias Web.Test.QuickJS.WPT

  @files [
    "urlpattern/urlpattern-constructor.any.js",
    "urlpattern/urlpattern-hasregexpgroups.any.js",
    "urlpattern/urlpattern.any.js"
  ]

  for path <- @files do
    test path do
      WPT.check!(unquote(path))
    end
  end
end
