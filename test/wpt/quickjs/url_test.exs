defmodule Web.WPT.QuickJS.URLTest do
  # Runs the files of web-platform-tests for the URL Standard: `URL` and `URLSearchParams`, with no change, in
  # QuickJS against the library. See `Web.Test.QuickJS.Bridge`, and
  # `Web.Test.QuickJS.WPT` for the lists of expected results.
  use ExUnit.Case, async: true

  alias Web.Test.QuickJS.WPT

  @files [
    "url/IdnaTestV2-removed.any.js",
    "url/IdnaTestV2.any.js",
    "url/historical.any.js",
    "url/url-constructor.any.js",
    "url/url-origin.any.js",
    "url/url-searchparams.any.js",
    "url/url-setters-lone-surrogates.any.js",
    "url/url-setters-stripping.any.js",
    "url/url-setters.any.js",
    "url/url-statics-canparse.any.js",
    "url/url-statics-parse.any.js",
    "url/url-tojson.any.js",
    "url/urlencoded-parser.any.js",
    "url/urlsearchparams-append.any.js",
    "url/urlsearchparams-constructor.any.js",
    "url/urlsearchparams-delete.any.js",
    "url/urlsearchparams-foreach.any.js",
    "url/urlsearchparams-get.any.js",
    "url/urlsearchparams-getall.any.js",
    "url/urlsearchparams-has.any.js",
    "url/urlsearchparams-set.any.js",
    "url/urlsearchparams-size.any.js",
    "url/urlsearchparams-sort.any.js",
    "url/urlsearchparams-stringifier.any.js"
  ]

  for path <- @files do
    test path do
      WPT.check!(unquote(path))
    end
  end
end
