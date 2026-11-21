defmodule Web.Test.QuickJS.WPT do
  @moduledoc false

  # The expected results of the files of web-platform-tests that QuickJS
  # runs against the library: see `Web.Test.QuickJS.Bridge`.
  #
  # The file `test/wpt/quickjs/expectations/<path of the test>.json` lists
  # each test that does not pass, with the group of its cause. A test that is
  # not in the list must pass. A test in the list that passes is also an
  # error: remove it from the list, as the library now follows the Standard.
  # The exception is a test with a group of `@unstable`: its result can
  # change from run to run, thus it can pass or fail, and it stays in the
  # list.
  #
  # With the environment variable `WPT_UPDATE=1`, a run writes the lists
  # again from its results.

  alias Web.Test.QuickJS.Bridge

  @root Path.expand("../../wpt/quickjs/expectations", __DIR__)
  @newer_standard "standard: the current Standard changed this test"
  @microtask "runner: the library does the steps of a later microtask before the call returns"
  @creation_order "runner: the promises settle in the sequence of their creation"
  @new_error "runner: an error of the library is a new object each time"

  # The groups of the tests whose result can change from run to run, for a
  # cause that the runner cannot remove. Such a test can pass or fail.
  @real_time "runner: a timer of the library runs in real time between two statements of JavaScript"
  @unstable [@real_time]

  @doc "Runs the WPT file at `path`, and compares the results with the list."
  def check!(path) do
    run = Bridge.run!(path)

    if System.get_env("WPT_UPDATE") in ["1", "true"] do
      write!(path, run)
    else
      compare!(path, run)
    end
  end

  defp compare!(path, run) do
    expected = read(path)

    problems =
      harness_problem(expected, run) ++
        for name <- run.order,
            {status, message} = run.results[name],
            problem = problem(name, status, message, expected["failures"]),
            do: problem

    if problems != [] do
      raise ExUnit.AssertionError,
        message:
          "#{length(problems)} results of #{path} differ from #{relative(file(path))}:\n" <>
            Enum.join(Enum.take(problems, 20), "\n") <> "\n" <> log(run)
    end

    :ok
  end

  defp harness_problem(expected, run) do
    if run.status == Map.get(expected, "harness", "OK"),
      do: [],
      else: ["  the harness: #{run.status} #{run.message}"]
  end

  defp problem(name, "PASS", _message, failures) do
    if Map.has_key?(failures, name) and failures[name] not in @unstable,
      do: "  passes now, remove it from the list: #{name}",
      else: nil
  end

  defp problem(name, status, message, failures) do
    if Map.has_key?(failures, name),
      do: nil,
      else: "  #{status}: #{name}: #{message}"
  end

  defp log(%{log: ""}), do: ""
  defp log(%{log: log}), do: "The output of QuickJS:\n" <> String.slice(log, 0, 2_000)

  defp read(path) do
    case File.read(file(path)) do
      {:ok, text} -> JSON.decode!(text)
      {:error, :enoent} -> %{"harness" => "OK", "failures" => %{}}
    end
  end

  # The list has one line for each test, in the sequence of the names: a
  # change of the library shows as a small change of the file.
  defp write!(path, run) do
    # A test with an unstable result is in the list also when it passes.
    failures =
      for name <- run.order,
          {status, message} = run.results[name],
          cause = cause(path, name, message),
          status != "PASS" or cause in @unstable do
        {name, cause}
      end

    target = file(path)

    if failures == [] and run.status == "OK" do
      _ = File.rm(target)
    else
      lines =
        failures
        |> Enum.uniq_by(&elem(&1, 0))
        |> Enum.sort()
        |> Enum.map_join(",\n", fn {name, cause} ->
          "    #{JSON.encode!(name)}: #{JSON.encode!(cause)}"
        end)

      File.mkdir_p!(Path.dirname(target))

      File.write!(target, """
      {
        "harness": #{JSON.encode!(run.status)},
        "failures": {
      #{lines}
        }
      }
      """)
    end

    :ok
  end

  defp file(path), do: Path.join(@root, path <> ".json")
  defp relative(path), do: Path.relative_to(path, File.cwd!())

  @doc """
  The group of the cause of a failure, from the path of the test, its name,
  and its message. The groups that start with `runner:` are things that the
  runner does not have yet. The groups that start with `library:` are
  differences of the library from the Standard. The group `standard:` is
  for a test of the pinned WPT commit that the current Standard changed.
  The group `scope:` is for a test of an API that the library will not
  have.
  """
  def cause(path, name, message) do
    message = message || ""
    Enum.find_value(causes(), "library: a different result", &match(&1, path, name, message))
  end

  @no_view_type "scope: the library has only Uint8Array views"
  @no_guard "scope: a server runtime has no guard for forbidden headers"
  @no_microtask "runner: the library reacts before the microtasks of JavaScript"
  @empty_form "standard: RFC 7578 and each browser give the close delimiter for an empty form"

  # The rules, in their sequence: the first rule that gives a group wins.
  defp causes do
    [
      # The views of the library are `Web.Uint8Array` values. A BYOB read
      # into a view with elements of more than one byte, or into a
      # `DataView`, needs a view type of that kind.
      {:test, "streams/readable-byte-streams/general.any.js", ~r/Uint16Array|Uint32Array/,
       @no_view_type},
      {:test, "streams/readable-byte-streams/read-min.any.js", ~r/Uint16Array|DataView/,
       @no_view_type}
    ] ++ microtask_causes() ++ file_api_dom_causes() ++ base_causes()
  end

  # The rules of the File API, of `FormData`, and of the DOM Standard.
  defp file_api_dom_causes do
    [
      # The timers of the library run in real time, also while JavaScript
      # runs: a short timeout can end before the next statement of the test,
      # for example before the statement that sets `onabort`. In a browser,
      # a timer fires only after the statements of the current task.
      {:test, "dom/abort/timeout.any.js", ~r/./, @real_time},
      {:test, "dom/abort/abort-signal-any.any.js", ~r/AbortSignal\.timeout\(\)/, @real_time},
      # The global object of the runner is not an `EventTarget`.
      {:test, "dom/events/EventTarget-removeEventListener.any.js",
       "removing a null event listener should succeed",
       "runner: the global object is not an EventTarget"},
      # A library has no document, thus no origin: the origin of a blob URL
      # is opaque, its serialization is "null". The test expects the origin
      # of the page of WPT.
      {:test, "FileAPI/url/url-format.any.js", ~r/origin|parses correctly/,
       "scope: a library has no document, thus a blob URL has an opaque origin"},
      # The URL parser of the Standard resolves the blob URL entry of a
      # `blob:` URL, thus a `Request` keeps the blob also after a revoke.
      # `Web.URL` and `Web.Request` do not keep it: the dispatcher reads the
      # store when the fetch starts.
      {:test, "FileAPI/url/url-with-fetch.any.js", ~r/^Revoke blob URL after creating Request/,
       "library: a Request does not keep the blob of its blob URL"}
    ]
  end

  # The Streams Standard reacts to the end of `start` and of `pull`, and to
  # a chunk of a tee, in a microtask. The library reacts at once, and the
  # bridge answers when the library is at rest. Thus in these tests the
  # library pulls before the next statement of JavaScript, or a cancel of
  # JavaScript comes after a pull that the Standard does later.
  defp microtask_causes do
    for {path, names} <- [
          {"streams/readable-byte-streams/general.any.js",
           [
             "Automatic pull() after start() and read()",
             "Automatic pull() after start() and read(view)",
             "autoAllocateChunkSize",
             "Respond to pull() by enqueue() asynchronously",
             "Respond to multiple pull() by separate enqueue()",
             "getReader(), read(view), then cancel()",
             "read() twice, then enqueue() twice",
             "Multiple read(view), close() and respond()",
             "Multiple read(view), big enqueue()",
             "Multiple read(view) and multiple enqueue()"
           ]},
          {"streams/readable-byte-streams/read-min.any.js",
           [
             "getReader(), read({ min }), then cancel()",
             "cancel() with partially filled pending read({ min }) request"
           ]},
          {"streams/readable-byte-streams/tee.any.js",
           ["respond() and close() while both branches are pulling"]}
        ],
        name <- names do
      prefix =
        if String.ends_with?(path, "tee.any.js"),
          do: "ReadableStream teeing with byte source: ",
          else: "ReadableStream with byte source: "

      {:test, path, prefix <> name, @no_microtask}
    end ++
      [
        {:test, "streams/readable-byte-streams/respond-after-enqueue.any.js",
         "byobRequest.respond() after enqueue() with double read should not crash",
         @no_microtask},
        {:test, "streams/readable-streams/async-iterator.any.js",
         ~r/^next\(\) that succeeds; return\(\)|^return\(\); next\(\) with delayed cancel\(\) \[no awaiting\]/,
         @no_microtask},
        # A getter `then` on `Object.prototype` runs in a reaction of the
        # runner, during the answer of a request.
        {:text, ["came during the request"], "runner: a request in a getter of Object.prototype"}
      ]
  end

  defp base_causes do
    [
      # The Encoding Standard now starts a new decoder after a fatal error
      # ("Set this's do not flush to false"). These tests expect the state
      # of the decoder after the error.
      {:test, "encoding/textdecoder-mistakes.any.js",
       "EUC-JP JIS0212 state after a fatal streaming error", @newer_standard},
      {:test, "encoding/textdecoder-mistakes.any.js", "fatal stream: iso-2022-jp",
       @newer_standard},
      # The library does at once the steps that JavaScript does in a later
      # microtask, for example the start of a stream or the end of a write.
      # The bridge answers a call when the library is at rest: thus a test
      # sees the end of these steps before JavaScript does them.
      {:test, "streams/readable-streams/general.any.js",
       ~r/^ReadableStream: should (call pull when trying to read from a started, empty stream|only call pull once on a non-empty stream read from before start fulfills)$/,
       @microtask},
      {:test, "streams/readable-streams/tee.any.js",
       "ReadableStream teeing: errors in the source should propagate to both branches",
       @microtask},
      {:test, "streams/readable-streams/reentrant-strategies.any.js",
       "tee() inside size() should work", @microtask},
      {:test, "streams/writable-streams/floating-point-total-queue-size.any.js", ~r//,
       @microtask},
      # The bridge sends the settled promises in the sequence in which
      # JavaScript made them, not in the sequence in which they settled.
      {:test, "encoding/streams/backpressure.any.js", ~r//, @creation_order},
      # The size function of a strategy object is a usual JavaScript function
      # of the layer: it has a prototype, and its length is 1.
      {:test, "streams/queuing-strategies.any.js",
       ~r/size should (not have a prototype property|not be a constructor|have the right length)$/,
       "runner: the size function of a strategy is a usual function"},
      # An error that the library makes is a new JavaScript object each time
      # that it goes to JavaScript.
      {:test, "streams/readable-streams/bad-strategies.any.js",
       ~r/^Readable stream: invalid strategy\.size return value/, @new_error},
      {:test, "streams/writable-streams/bad-strategies.any.js",
       "Writable stream: invalid strategy.size return value", @new_error},
      {:text, ["apply() should not be called"], "runner: the layer calls a callback with apply"},
      # The library cannot read a property of a JavaScript object, such as
      # `byteLength`. A binary of Elixir is bytes: a string has a byte length.
      {:test, "streams/writable-streams/byte-length-queuing-strategy.any.js", ~r//,
       "runner: the library cannot read a property of a JavaScript object"},
      {:test, "streams/queuing-strategies.any.js",
       "ByteLengthQueuingStrategy: size behaves as expected with strange arguments",
       "library: a binary has a byte length, and an object is not a map"},
      # `TextEncoderStream` converts a chunk to a string with `String.Chars`
      # of Elixir, not with the conversion of JavaScript.
      {:test, "encoding/streams/encode-bad-chunks.any.js", ~r//,
       "scope: the rules of JavaScript to convert a value to a string"},
      # The Fetch Standard forbids some headers for the code of a web page,
      # such as `Cookie` and `Set-Cookie`, and allows only some headers for
      # a request in the mode "no-cors". A server runtime has no page and no
      # CORS: Node.js and Deno send each header too. The guard "immutable"
      # of a response is in the library.
      {:path, "fetch/api/headers/headers-no-cors.any.js", @no_guard},
      {:test, "fetch/api/headers/headers-forbidden-override.any.js", ~r/is forbidden to use/,
       @no_guard},
      {:test, "fetch/api/headers/header-setcookie.any.js",
       "Set-Cookie is a forbidden response header", @no_guard},
      {:test, "fetch/api/request/request-headers.any.js",
       ~r/^(Adding invalid (no-cors )?request header|Check that (no-cors )?request constructor is filtering)/,
       @no_guard},
      # The rules of the files of `Request`, `Response`, and the body.
      #
      # A binary of Elixir is bytes. A JavaScript string that a stream gives
      # comes to the library as a binary, and a body takes a binary as a
      # chunk of bytes: Elixir code makes streams of binaries. The Fetch
      # Standard requires a `Uint8Array`.
      {:test, "fetch/api/response/response-stream-bad-chunk.any.js",
       ~r/^ReadableStream with non-Uint8Array chunk/,
       "library: a binary chunk of a body is bytes"},
      # Each browser encodes a form with no entries as the close delimiter
      # of RFC 7578, and fails these tests (wpt.fyi). The library does the
      # same: `formData()` of that body gives a form, as in
      # `fetch/api/body/formdata.any.js`.
      {:test, "fetch/api/response/response-consume-empty.any.js",
       "Consume empty FormData response body as text", @empty_form},
      {:test, "fetch/api/request/request-consume-empty.any.js",
       "Consume empty FormData request body as text", @empty_form},
      # The JSON `null` is `nil` in the library, and the bridge gives `nil`
      # to JavaScript as `undefined`.
      {:test, "fetch/api/request/request-consume.any.js", "Consume JSON from text: '\"null\"'",
       "runner: the JSON null is nil, which is undefined in JavaScript"},
      # WPT has no file `hello.txt`: the server of WPT gives a response with
      # the status 404, and the `fetch` of the runner rejects.
      {:text, ["hello.txt gave the status 404"], "runner: no server of WPT"},
      # The `fetch` of the runner makes its response with the `Response`
      # constructor. A response of `Web.fetch/2` has immutable headers.
      {:test, "fetch/api/response/response-headers-guard.any.js",
       "Ensure response headers are immutable",
       "runner: the fetch of the runner makes a response with the constructor"},
      # The library gives each branch of the clone its own chunk. A buffer of
      # JavaScript that comes back from the library is a new object: thus
      # the first branch cannot give the same object.
      {:test, "fetch/api/response/response-clone.any.js",
       "Check response clone use structureClone for teed ReadableStreams (Uint8Arraychunk)",
       "runner: a buffer of JavaScript comes back as a new object"},
      {:test, "fetch/api/response/response-clone.any.js",
       ~r/^Check response clone use structureClone for teed ReadableStreams/, @no_view_type},
      # The BEAM has no shared memory: a chunk from a `SharedArrayBuffer` is
      # a usual buffer in the library.
      {:test, "compression/compression-bad-chunks.any.js", ~r/shared|SharedArrayBuffer/,
       "scope: the BEAM has no shared memory"},
      # `Response.json()` serializes a JavaScript value. The library gets a
      # reference to a JavaScript object, and a lone surrogate becomes
      # U+FFFD before it comes to the library.
      {:test, "fetch/api/response/response-static-json.any.js",
       ~r/encodes JSON objects correctly|propagates JSON serializer errors|with input/,
       "runner: a JavaScript value for JSON"},
      # The rules of the TransformStream, the WritableStream, and the pipe.
      # In JavaScript, the start of a stream, the end of a write or a close,
      # and the reaction to a cancel come in a microtask after the call. The
      # bridge answers a call when the library is at rest, thus these steps
      # are complete before the next statement of the test. For example, a
      # writable stream is "errored" where JavaScript has it "erroring" (its
      # start is not complete), and a write that JavaScript queues starts.
      {:test, "streams/transform-streams/cancel.any.js",
       "readable.cancel() and a parallel writable.close() should reject if a transformer.cancel() calls controller.error()",
       @microtask},
      {:test, "streams/transform-streams/errors.any.js",
       ~r/^(abort should set the close reason for the writable when it happens before cancel during start|controller\.error\(\) should (do nothing the second time it is called|close writable immediately after readable\.cancel\(\)))/,
       @microtask},
      {:test, "streams/transform-streams/general.any.js",
       "terminate() should abort writable immediately after readable.cancel()", @microtask},
      {:test, "streams/transform-streams/reentrant-strategies.any.js",
       ~r/^writer\.(write|close|abort)\(\) inside size\(\) should work$/, @microtask},
      {:test, "streams/transform-streams/terminate.any.js",
       ~r/^controller\.error\(\) after controller\.terminate\(\) with(out)? queued chunk/,
       @microtask},
      {:test, "streams/writable-streams/aborting.any.js",
       ~r/^(Aborting a WritableStream (before it starts|prevents further writes after any|puts it in an errored state|causes any outstanding write)|Closing but then immediately aborting|promises returned from other writer methods should be rejected when writer abort\(\) happens during sink start|WritableStream if sink's abort throws, the promise returned by multiple writer\.abort\(\)s is the same|when calling abort\(\) twice on the same stream)/,
       @microtask},
      {:test, "streams/writable-streams/close.any.js",
       ~r/^(when close is called on a WritableStream in writable state, ready should return a fulfilled promise|releaseLock\(\) should not change the result of sync close\(\)|close\(\) on an erroring stream should reject)$/,
       @microtask},
      {:test, "streams/writable-streams/general.any.js",
       "ready promise should fire before closed on releaseLock", @microtask},
      {:test, "streams/writable-streams/reentrant-strategy.any.js",
       "writer.write() promises should resolve in the standard order", @microtask},
      {:test, "streams/writable-streams/start.any.js",
       "when start() rejects, writer promises should reject in standard order", @microtask},
      {:test, "streams/piping/general-addition.any.js",
       "enqueue() must not synchronously call write algorithm", @microtask},
      {:test, "streams/piping/multiple-propagation.any.js",
       ~r/^Piping from an errored readable stream to (an erroring|a closing) writable stream$/,
       @microtask},
      # The promises of a write, an abort, and `closed` settle in the same
      # step of the library. The bridge sends them in the sequence of their
      # creation.
      {:test, "streams/writable-streams/aborting.any.js",
       ~r/^(writer\.abort\(\)|controller\.error\(\)), .*while there is an in-flight (write|close), and then finish|^writer\.abort\(\) while there is an in-flight write, and then finish the write with rejection$/,
       @creation_order},
      # The conversion of WebIDL to an async sequence is not in the layer
      # yet: `ReadableStream.from()` needs it.
      {:text, ["async_sequence is not in the layer"], "runner: no async sequence"},
      # A string of Elixir is UTF-8: a lone surrogate of a JavaScript string
      # becomes U+FFFD before it comes to the library. These tests split a
      # character between two chunks.
      {:test, "encoding/streams/encode-utf8.any.js", ~r/surrogate|split/,
       "runner: no lone surrogate in a string"},
      # The runner times out a test only when the library is at rest, and
      # JavaScript has nothing to do: a promise of the library does not
      # settle.
      {:text, ["Test timed out"], "library: a promise does not settle"},
      {:text, ["Invalid high water mark"], "library: the checks of a high water mark"},
      # The library will not have `XMLHttpRequest` and `FileReader`: `fetch`
      # and the promises of `Blob` replace them.
      {:text, ["'XMLHttpRequest' is not defined"], "scope: the library has no XMLHttpRequest"},
      {:text, ["'FileReader' is not defined"], "scope: the library has no FileReader"},
      {:text, ["no server of WPT"], "runner: no server of WPT"},
      {:name, ~r/'(\w+)' is not defined/, "runner: no "},
      {:text, ["structuredClone"], "runner: no structuredClone"},
      {:name, ~r/The library has no ([\w.?]+\/\d)/, "library: no "},
      {:text, ["ArgumentError", "TypeError"], "library: ArgumentError, not TypeError"}
    ]
  end

  defp match({:test, test_path, %Regex{} = regex, group}, path, name, _message),
    do: if(path == test_path and Regex.match?(regex, name), do: group)

  defp match({:test, test_path, test_name, group}, path, name, _message),
    do: if(path == test_path and name == test_name, do: group)

  defp match({:path, prefix, group}, path, _name, _message),
    do: if(String.starts_with?(path, prefix), do: group)

  defp match({:text, texts, group}, _path, _name, message),
    do: if(Enum.all?(texts, &String.contains?(message, &1)), do: group)

  defp match({:name, regex, group}, _path, _name, message) do
    case capture(regex, message) do
      nil -> nil
      name -> group <> name
    end
  end

  defp capture(regex, message) do
    case Regex.run(regex, message) do
      [_match, name] -> name
      nil -> nil
    end
  end
end
