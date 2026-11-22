defmodule Web.WPT.QuickJS.FetchTest do
  # Runs the files of web-platform-tests for the Fetch Standard: `Request`,
  # `Response`, and the body mixin, with no change, in QuickJS against the
  # library. See `Web.Test.QuickJS.Bridge`, and `Web.Test.QuickJS.WPT` for the
  # lists of expected results.
  #
  # A stream or a promise of the library stops when the linger time of the
  # application goes by after its end, because the BEAM does not collect a
  # process. A page of JavaScript keeps each object that it refers to. Some
  # files of this suite make their streams when the script loads, and use
  # them in a later test: on a busy machine, more than the default linger
  # time of 5 s goes by. Thus this module sets the linger time to the time
  # limit of a run. The setting applies to the application, thus the module
  # cannot run at the same time as other tests.
  use ExUnit.Case, async: false

  # A file of WPT can have thousands of tests, and WPT gives some files a
  # long time limit (`META: timeout=long`).
  @moduletag timeout: 300_000

  setup_all do
    previous = Application.fetch_env(:web, :linger)
    Application.put_env(:web, :linger, 300_000)

    on_exit(fn ->
      case previous do
        {:ok, linger} -> Application.put_env(:web, :linger, linger)
        :error -> Application.delete_env(:web, :linger)
      end
    end)
  end

  alias Web.Test.QuickJS.WPT

  @files [
    "fetch/api/request/forbidden-method.any.js",
    "fetch/api/request/request-bad-port.any.js",
    "fetch/api/request/request-cache-default-conditional.any.js",
    "fetch/api/request/request-cache-default.any.js",
    "fetch/api/request/request-cache-force-cache.any.js",
    "fetch/api/request/request-cache-no-cache.any.js",
    "fetch/api/request/request-cache-no-store.any.js",
    "fetch/api/request/request-cache-only-if-cached.any.js",
    "fetch/api/request/request-cache-reload.any.js",
    "fetch/api/request/request-clone-readable-stream-body.any.js",
    "fetch/api/request/request-constructor-init-body-override.any.js",
    "fetch/api/request/request-consume-empty.any.js",
    "fetch/api/request/request-consume.any.js",
    "fetch/api/request/request-disturbed.any.js",
    "fetch/api/request/request-error.any.js",
    "fetch/api/request/request-headers.any.js",
    "fetch/api/request/request-init-002.any.js",
    "fetch/api/request/request-init-contenttype.any.js",
    "fetch/api/request/request-init-priority.any.js",
    "fetch/api/request/request-init-stream.any.js",
    "fetch/api/request/request-keepalive.any.js",
    "fetch/api/request/request-structure.any.js",
    "fetch/api/response/json.any.js",
    "fetch/api/response/response-blob-realm.any.js",
    "fetch/api/response/response-cancel-stream.any.js",
    "fetch/api/response/response-clone.any.js",
    "fetch/api/response/response-consume-empty.any.js",
    "fetch/api/response/response-consume-stream.any.js",
    "fetch/api/response/response-error-from-stream.any.js",
    "fetch/api/response/response-error.any.js",
    "fetch/api/response/response-from-stream.any.js",
    "fetch/api/response/response-headers-guard.any.js",
    "fetch/api/response/response-init-001.any.js",
    "fetch/api/response/response-init-002.any.js",
    "fetch/api/response/response-init-contenttype.any.js",
    "fetch/api/response/response-static-error.any.js",
    "fetch/api/response/response-static-json.any.js",
    "fetch/api/response/response-static-redirect.any.js",
    "fetch/api/response/response-stream-bad-chunk.any.js",
    "fetch/api/response/response-stream-disturbed-1.any.js",
    "fetch/api/response/response-stream-disturbed-2.any.js",
    "fetch/api/response/response-stream-disturbed-3.any.js",
    "fetch/api/response/response-stream-disturbed-4.any.js",
    "fetch/api/response/response-stream-disturbed-5.any.js",
    "fetch/api/response/response-stream-disturbed-6.any.js",
    "fetch/api/response/response-stream-disturbed-by-pipe.any.js",
    "fetch/api/response/response-stream-with-broken-then.any.js",
    "fetch/api/body/formdata.any.js",
    "fetch/api/body/mime-type.any.js",
    "fetch/api/body/textstream.any.js",
    "fetch/data-urls/base64.any.js",
    "fetch/data-urls/processing.any.js"
  ]

  for path <- @files do
    test path do
      WPT.check!(unquote(path))
    end
  end
end
