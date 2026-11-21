defmodule Web.Test.QuickJS.Bridge do
  @moduledoc false

  # Runs one file of web-platform-tests in QuickJS against the library.
  #
  # QuickJS runs `testharness.js` and the test file with no change. The
  # classes of the interfaces come from the WebIDL files of WPT: see
  # `test/support/wpt/quickjs/webidl_layer.js`. Each method of a class sends
  # a call to this process, in lines of JSON on the standard input and
  # output of QuickJS. The lines have only ASCII characters.
  #
  # ## The processes
  #
  # This process, the bridge, has the port of QuickJS and the handles. It
  # does no call of the library itself:
  #
  #   * An executor process does each call. JavaScript has one thread: a
  #     call waits until its executor gives the result. The library can call
  #     a JavaScript function during a call, for example the function
  #     `start` of a source. The function can call the library again. The
  #     bridge then gives that call to the next executor that is free. The
  #     executors live until the end of the run: the promises and the locks
  #     of the library belong to the process that made them.
  #   * A JavaScript function is an Elixir function. It sends `:invoke` to
  #     the bridge, and waits for the line `return`. A promise that the
  #     JavaScript function returns is a `Web.Promise` of the bridge, which
  #     the line `jsSettled` settles.
  #   * A promise of the library goes to JavaScript as a promise. A watcher
  #     process waits for it, and the bridge sends the line `settle`.
  #
  # All these processes, and the processes that the library starts from
  # them, have the same group leader. Thus the bridge can find them: see
  # `release/0`. At the end of the run, it stops them.
  #
  # ## Timers
  #
  # A test of WPT uses a timer to wait until the work of the platform is
  # complete. The work of the library is in other processes. Thus the timer
  # of the runner asks the bridge first (the line `quiesce`). The bridge
  # answers when the processes of the run are at rest, as it does for each
  # call: see "The answers".
  #
  # ## Values
  #
  # The library has immutable structs. A JavaScript object of an interface
  # is a handle: this process keeps the struct of each handle. An operation
  # that returns `undefined` in WebIDL, such as `append` of `Headers`, puts
  # the new struct of the library in the handle. The struct of a stream, a
  # reader, or a controller refers to a process: the same struct gets the
  # same handle, thus the same JavaScript object.
  #
  # Each other JavaScript object goes to the library as a reference, a
  # `Ref`. It comes back as the same object. `undefined` is `nil`, and
  # `null` is the atom `:null`: a stream can have the two as chunks.
  #
  # ## Names
  #
  # The name of a member goes to a function of the library with these rules:
  #
  #   * the constructor is `new`;
  #   * `getSetCookie` is `get_set_cookie`, and a boolean can end with `?`;
  #   * the setter of an attribute is `name/2` or `set_name/2`;
  #   * the getter of an attribute is `name/1`, or a field of the struct;
  #   * the pairs of an iterable come from `entries/1` or `to_list/1`;
  #   * an optional argument that the test does not give is not given to the
  #     library, or is `nil` when the library has no function without it.
  #
  # Some members of the library have a different form, for example a
  # keyword list for a dictionary of options. `adapt/5` has these members.
  # A member with no function of the library fails with a message that
  # names the missing function.

  alias Web.Platform.Test, as: WPT
  alias Web.Test.QuickJS

  @runner Path.expand("../wpt/quickjs/runner.js", __DIR__)
  @layer Path.expand("../wpt/quickjs/webidl_layer.js", __DIR__)
  @timeout 60_000

  defmodule Ref do
    @moduledoc false
    # A JavaScript object that the library keeps, such as a chunk or an
    # error.
    defstruct [:id]
  end

  @interfaces %{
    "AbortController" => Web.AbortController,
    "AbortSignal" => Web.AbortSignal,
    "Blob" => Web.Blob,
    "ByteLengthQueuingStrategy" => Web.ByteLengthQueuingStrategy,
    "CompressionStream" => Web.CompressionStream,
    "CountQueuingStrategy" => Web.CountQueuingStrategy,
    "CustomEvent" => Web.CustomEvent,
    "DecompressionStream" => Web.DecompressionStream,
    "Event" => Web.Event,
    "EventTarget" => Web.EventTarget,
    "File" => Web.File,
    "FormData" => Web.FormData,
    "Headers" => Web.Headers,
    "ReadableByteStreamController" => Web.ReadableByteStreamController,
    "ReadableStream" => Web.ReadableStream,
    "ReadableStreamBYOBReader" => Web.ReadableStreamBYOBReader,
    "ReadableStreamBYOBRequest" => Web.ReadableStreamBYOBRequest,
    "ReadableStreamDefaultController" => Web.ReadableStreamDefaultController,
    "ReadableStreamDefaultReader" => Web.ReadableStreamDefaultReader,
    "Request" => Web.Request,
    "Response" => Web.Response,
    "TextDecoder" => Web.TextDecoder,
    "TextDecoderStream" => Web.TextDecoderStream,
    "TextEncoder" => Web.TextEncoder,
    "TextEncoderStream" => Web.TextEncoderStream,
    "TransformStream" => Web.TransformStream,
    "TransformStreamDefaultController" => Web.TransformStreamDefaultController,
    "URL" => Web.URL,
    "URLPattern" => Web.URLPattern,
    "URLSearchParams" => Web.URLSearchParams,
    "WritableStream" => Web.WritableStream,
    "WritableStreamDefaultController" => Web.WritableStreamDefaultController,
    "WritableStreamDefaultWriter" => Web.WritableStreamDefaultWriter
  }

  # The objects of the library that have no interface in the WebIDL files,
  # and are not globals: the default asynchronous iterator of WebIDL. Its
  # name is the class string of its prototype.
  @iterators %{"ReadableStream AsyncIterator" => Web.ReadableStreamAsyncIterator}

  # `testharness.js` makes an `AbortController` for each test when the
  # global has one: two calls of the library for each test. Thus only the
  # tests that use these interfaces get them.
  @scoped %{
    "AbortController" => ["streams/", "dom/", "fetch/api/request", "fetch/api/response"],
    "AbortSignal" => ["streams/", "dom/", "fetch/api/request", "fetch/api/response"]
  }

  @classes Map.new(Map.merge(@interfaces, @iterators), fn {name, module} -> {module, name} end)

  # The structs that are values: two equal structs are two objects.
  # A blob and a file have an identity of their own (`id`), thus the same
  # struct is the same object: `FormData.get/2` gives the same file.
  @values [
    Web.ByteLengthQueuingStrategy,
    Web.CountQueuingStrategy,
    Web.CustomEvent,
    Web.Event,
    Web.FormData,
    Web.Headers,
    Web.Request,
    Web.Response,
    Web.TextDecoder,
    Web.TextEncoder,
    Web.URL,
    Web.URLPattern,
    Web.URLSearchParams
  ]

  @idls [
    "interfaces/FileAPI.idl",
    "interfaces/compression.idl",
    "interfaces/dom.idl",
    "interfaces/encoding.idl",
    "interfaces/fetch.idl",
    # The enumeration `ReferrerPolicy` of the member `referrerPolicy` of
    # `RequestInit`.
    "interfaces/referrer-policy.idl",
    "interfaces/streams.idl",
    "interfaces/url.idl",
    "interfaces/urlpattern.idl",
    "interfaces/xhr.idl"
  ]

  # Definitions of other Standards that the files above use.
  @local_idls [Path.expand("../wpt/quickjs/event_handler.idl", __DIR__)]

  # The operations that write into a buffer argument. The library has
  # immutable buffers: the function gives `{result, new_buffer}`, and the
  # layer copies the bytes of the new buffer into the argument at the index.
  @out_buffers %{{"TextEncoder", "encodeInto"} => 1}

  @state {__MODULE__, :state}
  @page {__MODULE__, :page}

  @doc """
  Runs the WPT file at `path`, such as `"url/url-searchparams.any.js"`.
  Returns `%{status: status, message: message, results: results, log: log}`:
  the status of the harness, and a map from the name of each test to
  `{status, message}`.
  """
  def run!(path) do
    # A process of its own for each run: no message of a run, such as the
    # answer of a stopped process, comes to the next run.
    {pid, monitor} = spawn_monitor(fn -> exit({:result, run(path)}) end)

    receive do
      {:DOWN, ^monitor, :process, ^pid, {:result, result}} -> result
      {:DOWN, ^monitor, :process, ^pid, reason} -> exit(reason)
    end
  end

  defp run(path) do
    source = File.read!(WPT.tree_file!(path))

    start = %{
      harness: WPT.tree_file!("resources/testharness.js"),
      idlParser: WPT.tree_file!("resources/webidl2/lib/webidl2.js"),
      layer: @layer,
      idls: Enum.map(@idls, &WPT.tree_file!/1) ++ @local_idls,
      exposed: exposed(path),
      scripts: Enum.map(meta_scripts(source, Path.dirname(path)), &WPT.tree_file!/1),
      test: WPT.tree_file!(path),
      dir: Path.dirname(path),
      page: page(path),
      libraryResponse: String.starts_with?(path, "fetch/api/")
    }

    port =
      Port.open({:spawn_executable, QuickJS.path!()}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:line, 65_536},
        # A rejection with no handler is an event in a browser. QuickJS
        # stops by default.
        args: ["--no-unhandled-rejection", @runner]
      ])

    group = spawn_group_leader(Process.group_leader())

    # The port is linked to this process. QuickJS can stop before a write
    # of the bridge: the port then stops with `:epipe`.
    Process.flag(:trap_exit, true)

    Process.put(@state, %{
      page: page(path),
      port: port,
      group: group,
      handles: %{},
      interned: %{},
      next_handle: 1,
      functions: %{},
      function_ids: %{},
      children: %{},
      links: %{},
      errors: %{},
      promises: %{},
      next_promise: 1,
      js_promises: %{},
      invokes: %{},
      next_invoke: 1,
      executors: %{},
      calls: %{},
      pending: [],
      snapshot: nil,
      deferred: MapSet.new(),
      settles: %{}
    })

    init_buffers()

    send_line(start)

    try do
      loop(%{
        port: port,
        line: "",
        results: %{},
        order: [],
        log: [],
        done: nil,
        error: nil,
        at: now()
      })
    after
      stop_group(group)
      Process.delete(@state)
      close(port)
    end
  end

  defp exposed(path) do
    for {name, _module} <- @interfaces,
        prefixes = Map.get(@scoped, name, [""]),
        Enum.any?(prefixes, &String.starts_with?(path, &1)),
        do: name
  end

  # The URL of the page that WPT makes for the file. It is the base URL of a
  # relative URL, as the API base URL of a document is.
  defp page(path),
    do: "http://web-platform.test:8000/" <> String.replace_suffix(path, ".js", ".html")

  defp done(%{error: nil}, status, message), do: {status, message}
  defp done(%{error: error}, _status, _message), do: {"ERROR", error}

  # QuickJS can stop at the same time as the close: the port is closed
  # already.
  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  # `// META: script=...` names a helper script: a path from the root of
  # WPT, or a path from the directory of the test.
  defp meta_scripts(source, dir) do
    for [_line, script] <- Regex.scan(~r{^// META: script=(\S+)}m, source) do
      if String.starts_with?(script, "/") do
        String.trim_leading(script, "/")
      else
        dir |> Path.join(script) |> Path.expand("/") |> String.trim_leading("/")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The loop
  # ---------------------------------------------------------------------------

  defp loop(run) do
    receive do
      message ->
        # A message: the processes of the run are not at rest. See
        # `release/0`.
        put(:snapshot, nil)
        handle_message(message, run)
    after
      wait_time(run) ->
        if now() - run.at >= @timeout do
          finish(%{run | done: {"TIMEOUT", "No message in #{@timeout} ms."}})
        else
          release()
          loop(run)
        end
    end
  end

  defp handle_message({port, {:data, {:noeol, chunk}}}, %{port: port} = run),
    do: loop(%{run | line: run.line <> chunk, at: now()})

  defp handle_message({port, {:data, {:eol, chunk}}}, %{port: port} = run) do
    line = run.line <> chunk

    case handle_line(line, %{run | line: "", at: now()}) do
      {:done, run} -> finish(run)
      run -> loop(run)
    end
  end

  defp handle_message({port, {:exit_status, status}}, %{port: port} = run),
    do: finish(%{run | done: run.done || {"CRASH", "QuickJS stopped with the status #{status}."}})

  defp handle_message({:EXIT, port, reason}, %{port: port} = run),
    do: finish(%{run | done: run.done || {"CRASH", "QuickJS stopped: #{inspect(reason)}."}})

  defp handle_message(message, run) do
    case message do
      {:done, executor, ref, outcome} -> call_done(executor, ref, outcome)
      {:invoke, pid, ref, function, args} -> send_invoke(pid, ref, function, args)
      {:settled, id, outcome} -> put(:settles, Map.put(get(:settles), id, outcome))
      _other -> :ok
    end

    loop(run)
  end

  defp now, do: System.monotonic_time(:millisecond)

  # The bridge looks at the processes each millisecond while an answer
  # waits for them.
  defp wait_time(run) do
    if Enum.any?(get(:pending), &(&1.reply != nil)) or get(:settles) != %{},
      do: 1,
      else: max(0, @timeout - (now() - run.at))
  end

  defp finish(run) do
    {status, message} = run.done

    %{
      status: status,
      message: message,
      results: run.results,
      order: Enum.reverse(run.order),
      log: run.log |> Enum.reverse() |> Enum.join("\n")
    }
  end

  defp handle_line("{" <> _rest = line, run), do: handle_json(JSON.decode!(line), run)

  # A line that is not JSON is an output of QuickJS, for example an error
  # of a script.
  defp handle_line(line, run), do: %{run | log: [line | run.log]}

  defp handle_json(%{"t" => "call", "id" => id} = message, run) do
    start_call(id, message)
    run
  end

  defp handle_json(%{"t" => "resource", "id" => id, "p" => path}, run) do
    reply(id, resource(path))
    run
  end

  defp handle_json(%{"t" => "quiesce", "id" => id}, run) do
    wait(id, [], :quiesce)
    release()
    run
  end

  defp handle_json(%{"t" => "return"} = message, run) do
    js_return(message)
    run
  end

  defp handle_json(%{"t" => "deferred", "ref" => ref}, run) do
    put(:deferred, MapSet.put(get(:deferred), ref))
    run
  end

  defp handle_json(%{"t" => "jsSettled", "id" => id} = message, run) do
    js_settled(message)
    wait(id, Map.get(message, "w", []), {:answer, {:ok, true}})
    release()
    run
  end

  defp handle_json(%{"t" => "result", "name" => name, "status" => status} = message, run) do
    %{
      run
      | results: Map.put(run.results, name, {status, message["message"]}),
        order: [name | run.order]
    }
  end

  defp handle_json(%{"t" => "error", "message" => message}, run), do: %{run | error: message}

  defp handle_json(%{"t" => "done", "status" => status, "message" => message}, run),
    do: {:done, %{run | done: done(run, status, message)}}

  # A data file of a test. A path that is not a file, for example a
  # directory, gives a `TypeError` to the `fetch` of the test.
  defp resource(path) do
    case File.read(WPT.tree_file!(path)) do
      {:ok, text} -> {:ok, encode(text)}
      {:error, reason} -> {:error, type_error("No file #{path}: #{reason}")}
    end
  rescue
    error -> {:error, type_error(Exception.message(error))}
  catch
    :exit, reason -> {:error, type_error(inspect(reason))}
  end

  defp type_error(message), do: %{"$err" => %{"name" => "TypeError", "message" => message}}

  defp reply(id, answer, extra \\ %{})

  defp reply(id, {:ok, value}, extra),
    do: send_line(Map.merge(%{"id" => id, "ok" => value}, extra))

  defp reply(id, {:ok, value, out}, extra),
    do: send_line(Map.merge(%{"id" => id, "ok" => value, "out" => out}, extra))

  defp reply(id, {:error, error}, extra),
    do: send_line(Map.merge(%{"id" => id, "error" => error}, extra))

  # The runner reads bytes as Latin-1: each other character is an escape
  # of JSON.
  defp send_line(message) do
    json =
      message
      |> JSON.encode!()
      |> then(&Regex.replace(~r/[^\x00-\x7f]/u, &1, fn character -> escape(character) end))

    Port.command(get(:port), [json, "\n"])
  rescue
    # QuickJS stopped: the loop gets the status.
    ArgumentError -> :ok
  end

  defp escape(<<code_point::utf8>>) when code_point < 0x10000, do: unit(code_point)

  defp escape(<<code_point::utf8>>) do
    value = code_point - 0x10000
    unit(0xD800 + Bitwise.bsr(value, 10)) <> unit(0xDC00 + Bitwise.band(value, 0x3FF))
  end

  defp unit(value) do
    "\\u" <> String.pad_leading(Integer.to_string(value, 16), 4, "0")
  end

  # ---------------------------------------------------------------------------
  # The processes of the run
  # ---------------------------------------------------------------------------

  # The group leader of the processes of the run. It gives each request of
  # input or output to the group leader of the test.
  defp spawn_group_leader(leader) do
    spawn(fn -> group_leader_loop(leader) end)
  end

  defp group_leader_loop(leader) do
    receive do
      :stop ->
        :ok

      message ->
        send(leader, message)
        group_leader_loop(leader)
    end
  end

  defp spawn_in_group(fun) do
    pid =
      spawn(fn ->
        receive do
          :go -> fun.()
        end
      end)

    Process.group_leader(pid, get(:group))
    send(pid, :go)
    pid
  end

  defp members(group) do
    for pid <- Process.list(), Process.info(pid, :group_leader) == {:group_leader, group}, do: pid
  end

  @at_rest [:group_leader, :status, :message_queue_len, :reductions]

  # The reductions of each process of the run, or `nil` when a process runs
  # or has a message.
  defp snapshot(group) do
    Enum.reduce_while(Process.list(), %{}, fn pid, snapshot ->
      case Process.info(pid, @at_rest) do
        [group_leader: ^group, status: :waiting, message_queue_len: 0, reductions: reductions] ->
          {:cont, Map.put(snapshot, pid, reductions)}

        [{:group_leader, ^group} | _busy] ->
          {:halt, nil}

        _other ->
          {:cont, snapshot}
      end
    end)
  end

  defp stop_group(group) do
    for pid <- members(group), do: Process.exit(pid, :kill)
    send(group, :stop)
  end

  # ---------------------------------------------------------------------------
  # The answers
  #
  # JavaScript does the steps of a Standard at once: for example, `read()`
  # calls the function `pull` of the source before it returns. The library
  # does them in other processes. Thus the answer to a request waits until
  # the work that the request started is complete: each process of the run
  # waits with an empty queue, and JavaScript returned from each function
  # that the library called. The functions in which JavaScript makes the
  # request (`within`) are not complete before the answer. A function that
  # JavaScript runs in a microtask (the line `deferred`) does not hold an
  # answer: see `deferred` in the layer.
  #
  # The requests of JavaScript are a stack: the answers go from the newest.
  # ---------------------------------------------------------------------------

  defp wait(id, within, reply, extra \\ %{}) do
    entry = Map.merge(%{id: id, within: within, reply: reply, lines: false}, extra)
    put(:pending, [entry | get(:pending)])
  end

  # The processes are at rest when two looks at them, with no message to
  # the bridge between them, see the same processes, each one waiting with
  # an empty queue, and with the same number of reductions: no process ran
  # between the two looks. One look is not sufficient: it sees the
  # processes one after the other, and a message can be on its way from a
  # process that it saw to a process that it saw before.
  defp release do
    pending = get(:pending)

    check? =
      Enum.any?(pending, &(&1.reply != nil and not Map.get(&1, :value?, false))) or
        get(:settles) != %{}

    at_rest? =
      if check? do
        snapshot = snapshot(get(:group))
        previous = get(:snapshot)
        put(:snapshot, snapshot)
        snapshot != nil and snapshot == previous
      else
        false
      end

    if at_rest?, do: send_settles()

    # A call that JavaScript runs in a microtask does not hold an answer.
    invokes = Enum.reject(Map.keys(get(:invokes)), &MapSet.member?(get(:deferred), &1))

    kept =
      for entry <- pending, entry = advance(entry, at_rest?, invokes), entry != :sent, do: entry

    put(:pending, kept)
  end

  defp advance(%{reply: nil} = entry, _at_rest?, _invokes), do: entry

  # A call of a struct that is a value starts no work in other processes.
  defp advance(%{value?: true} = entry, _at_rest?, _invokes), do: deliver(entry)

  defp advance(entry, at_rest?, invokes) do
    if at_rest? and invokes -- entry.within == [], do: deliver(entry), else: entry
  end

  # The answer to a timer is `false` when the bridge sent lines in that
  # time: the runner then lets their reactions run first, and asks again.
  defp deliver(%{reply: :quiesce} = entry) do
    reply(entry.id, {:ok, not entry.lines})
    :sent
  end

  defp deliver(%{reply: {:answer, answer}} = entry) do
    reply(entry.id, answer)
    :sent
  end

  defp deliver(%{reply: {:outcome, outcome, kind, message, module}} = entry) do
    answer = outcome(outcome, kind, message, module)
    reply(entry.id, answer, detached_buffers(Map.get(entry, :buffer_keys, [])))
    :sent
  end

  defp note_line do
    put(:pending, Enum.map(get(:pending), &%{&1 | lines: true}))
  end

  # ---------------------------------------------------------------------------
  # A call of the library
  # ---------------------------------------------------------------------------

  defp start_call(id, %{"i" => interface, "k" => kind} = message) do
    module = Map.get(@interfaces, interface) || Map.fetch!(@iterators, interface)
    sync_buffers(message["bs"])
    args = message |> Map.get("a", []) |> Enum.map(&decode/1) |> refresh_buffers()
    self = with %{"$h" => handle} <- message["self"], do: refresh_buffers(fetch_handle(handle))
    buffer_keys = take_call_buffers()
    count = Map.get(message, "n", length(args))
    member = message["m"]

    executor = free_executor()
    ref = make_ref()

    send(
      executor,
      {:run, ref, fn -> invoke(interface, kind, module, member, self, args, count) end}
    )

    put(:executors, Map.put(get(:executors), executor, :busy))
    put(:calls, Map.put(get(:calls), ref, {kind, message, module}))

    wait(id, Map.get(message, "w", []), nil, %{
      ref: ref,
      value?: module in @values,
      buffer_keys: buffer_keys
    })
  rescue
    error -> reply(id, {:error, encode_error(error)})
  end

  defp free_executor do
    case Enum.find(get(:executors), fn {_pid, state} -> state == :free end) do
      {pid, :free} ->
        pid

      nil ->
        bridge = self()
        page = get(:page)

        spawn_in_group(fn ->
          # The adapters run in the executor: see `absolute/1`.
          Process.put(@page, page)
          executor_loop(bridge)
        end)
    end
  end

  defp executor_loop(bridge) do
    receive do
      {:run, ref, fun} ->
        outcome =
          try do
            fun.()
          rescue
            error ->
              if System.get_env("WEB_BRIDGE_DEBUG"),
                do: IO.puts(Exception.format(:error, error, __STACKTRACE__))

              {:raised, error}
          catch
            :throw, value -> {:thrown, value}
            kind, reason -> {:raised, %RuntimeError{message: "#{kind}: #{inspect(reason)}"}}
          end

        send(bridge, {:done, self(), ref, outcome})
        executor_loop(bridge)
    end
  end

  defp call_done(executor, ref, outcome) do
    put(:executors, Map.put(get(:executors), executor, :free))
    {{kind, message, module}, calls} = Map.pop(get(:calls), ref)
    put(:calls, calls)

    put(
      :pending,
      Enum.map(get(:pending), fn
        %{ref: ^ref} = entry -> %{entry | reply: {:outcome, outcome, kind, message, module}}
        entry -> entry
      end)
    )

    release()
  end

  defp outcome({:ok, value}, kind, message, module) do
    case {Map.get(@out_buffers, {message["i"], message["m"]}), value, message["p"]} do
      {index, {value, %Web.Uint8Array{} = buffer}, _promise} when is_integer(index) ->
        bytes = :binary.bin_to_list(Web.Uint8Array.to_binary(buffer))
        {:ok, encode(value), [%{"i" => index, "b" => bytes}]}

      # A function of the library can give the outcome of a promise as
      # `{:ok, value}` or `{:error, reason}`, with no process.
      {nil, {:ok, value}, true} ->
        {:ok, %{"$pv" => %{"ok" => encode(value)}}}

      {nil, {:error, reason}, true} ->
        {:ok, %{"$pv" => %{"error" => encode(reason)}}}

      _other ->
        {:ok, result(kind, message, module, value)}
    end
  end

  defp outcome({:missing, name}, _kind, _message, _module),
    do: {:error, type_error("The library has no #{name}.")}

  defp outcome({:raised, error}, _kind, _message, _module), do: {:error, encode_error(error)}
  defp outcome({:thrown, value}, _kind, _message, _module), do: {:error, encode(value)}

  defp invoke(interface, kind, module, member, self, args, count) do
    case adapt(interface, kind, member, self, args) do
      :default -> invoke(kind, module, member, self, args, count)
      result -> result
    end
  end

  defp invoke("constructor", module, _member, _self, args, count),
    do: apply_first(module, candidates("new", [], args, count))

  defp invoke("operation", module, member, self, args, count) do
    name = snake(member)
    apply_first(module, candidates(name, [self], args, count) ++ [{name <> "?", [self | args]}])
  end

  defp invoke("static", module, member, _self, args, count),
    do: apply_first(module, candidates(snake(member), [], args, count))

  defp invoke("getter", module, member, self, [], _count) do
    name = snake(member)

    case apply_first(module, [{name, [self]}, {name <> "?", [self]}]) do
      {:missing, _} = missing -> field(self, [name, name <> "?"], missing)
      found -> found
    end
  end

  defp invoke("setter", module, member, self, [value], _count) do
    name = snake(member)
    apply_first(module, [{name, [self, value]}, {"set_" <> name, [self, value]}])
  end

  defp invoke("iterate", module, _member, self, [], _count),
    do: apply_first(module, [{"entries", [self]}, {"to_list", [self]}])

  defp invoke("stringify", module, _member, self, [], _count) do
    case apply_first(module, [{"to_string", [self]}, {"href", [self]}]) do
      {:missing, _} = missing ->
        if String.Chars.impl_for(self), do: {:ok, to_string(self)}, else: missing

      found ->
        found
    end
  end

  # The arguments as the test gives them, then with `nil` for each optional
  # argument that it does not give.
  defp candidates(name, first, args, count) do
    for size <- length(args)..max(count, length(args))//1 do
      {name, first ++ args ++ List.duplicate(nil, size - length(args))}
    end
  end

  # The first function that the module exports, with the arity of its
  # arguments.
  defp apply_first(module, candidates) do
    Code.ensure_loaded(module)

    Enum.find_value(candidates, fn {name, args} ->
      atom = String.to_atom(name)
      if function_exported?(module, atom, length(args)), do: {:ok, apply(module, atom, args)}
    end) || {:missing, describe(module, Enum.take(candidates, 1))}
  end

  defp field(%{} = struct, names, missing) do
    Enum.find_value(names, missing, fn name ->
      key = String.to_atom(name)
      if Map.has_key?(struct, key), do: {:ok, Map.fetch!(struct, key)}
    end)
  end

  defp describe(module, candidates) do
    Enum.map_join(candidates, " or ", fn {name, args} ->
      "#{inspect(module)}.#{name}/#{length(args)}"
    end)
  end

  # ---------------------------------------------------------------------------
  # The members with a different form in the library
  # ---------------------------------------------------------------------------

  # The constructors of the streams take the dictionaries of WebIDL. The
  # library takes a map of functions and a keyword list of options. A
  # strategy gives its high water mark and its size function.
  defp adapt("ReadableStream", "constructor", _member, _self, [source | strategy]) do
    {:ok, Web.ReadableStream.new(source, strategy_options(strategy))}
  end

  defp adapt("WritableStream", "constructor", _member, _self, [sink | strategy]) do
    # The function `close` of WebIDL has no argument. The library gives it
    # the controller.
    sink =
      case sink do
        %{close: close} when is_function(close, 0) -> %{sink | close: fn _ctrl -> close.() end}
        _other -> sink
      end

    {:ok, Web.WritableStream.new(sink, strategy_options(strategy))}
  end

  defp adapt("TransformStream", "constructor", _member, _self, [transformer | strategies]) do
    {writable, readable} =
      case strategies do
        [writable, readable] -> {writable, readable}
        [writable] -> {writable, nil}
        [] -> {nil, nil}
      end

    options = [
      writable_strategy: strategy_options([writable]),
      readable_strategy: strategy_options([readable])
    ]

    {:ok, Web.TransformStream.new(transformer, options)}
  end

  defp adapt("ReadableStreamDefaultReader", "constructor", _member, _self, [stream]),
    do: {:ok, Web.ReadableStream.get_reader(stream)}

  defp adapt("ReadableStreamBYOBReader", "constructor", _member, _self, [stream]),
    do: {:ok, Web.ReadableStream.get_reader(stream, mode: "byob")}

  defp adapt("WritableStreamDefaultWriter", "constructor", _member, _self, [stream]),
    do: {:ok, Web.WritableStream.get_writer(stream)}

  defp adapt("ByteLengthQueuingStrategy", "constructor", _member, _self, [%{high_water_mark: hwm}]),
       do: {:ok, Web.ByteLengthQueuingStrategy.new(hwm)}

  defp adapt("CountQueuingStrategy", "constructor", _member, _self, [%{high_water_mark: hwm}]),
    do: {:ok, Web.CountQueuingStrategy.new(hwm)}

  # The dictionaries of options are keyword lists in the library.
  defp adapt("ReadableStream", "operation", "getReader", self, [options]),
    do: {:ok, Web.ReadableStream.get_reader(self, Map.to_list(options))}

  defp adapt("ReadableStream", "operation", "pipeTo", self, [destination, options]),
    do: {:ok, Web.ReadableStream.pipe_to(self, destination, Map.to_list(options))}

  defp adapt("ReadableStream", "operation", "pipeThrough", self, [pair, options]),
    do: {:ok, Web.ReadableStream.pipe_through(self, pair, Map.to_list(options))}

  defp adapt("ReadableStreamBYOBReader", "operation", "read", self, [view, %{min: min}]),
    do: {:ok, Web.ReadableStreamBYOBReader.read(self, view, min: min)}

  defp adapt("ReadableStream", "operation", "values", self, [options]),
    do: {:ok, Web.ReadableStream.values(self, Map.to_list(options))}

  # The init dictionaries of the fetch interfaces are keyword lists in the
  # library.
  defp adapt("Request", "constructor", _member, _self, [input | init]),
    do: {:ok, Web.Request.new(absolute(input), options(init))}

  defp adapt("Response", "constructor", _member, _self, [body | init]),
    do: {:ok, Web.Response.new(body, options(init))}

  defp adapt("Response", "constructor", _member, _self, []), do: {:ok, Web.Response.new(nil, [])}

  defp adapt("Response", "static", "redirect", _self, [url | status]),
    do: {:ok, apply(Web.Response, :redirect, [absolute(url) | status])}

  defp adapt("Response", "static", "json", _self, [data | init]),
    do: {:ok, Web.Response.json(data, options(init))}

  # The URL of a request is a `Web.URL` in the library, and a string in
  # WebIDL.
  defp adapt("Request", "getter", "url", %Web.Request{url: url}, []), do: {:ok, Web.URL.href(url)}

  # `clone/1` gives the two structs: the original struct changes, as its
  # body is now a branch of a tee.
  defp adapt("Request", "operation", "clone", self, []),
    do: {:ok, {:clone, Web.Request.clone(self)}}

  defp adapt("Response", "operation", "clone", self, []),
    do: {:ok, {:clone, Web.Response.clone(self)}}

  defp adapt("Blob", "constructor", _member, _self, [parts | rest]),
    do: {:ok, Web.Blob.new(parts || [], options(rest))}

  defp adapt("Blob", "constructor", _member, _self, []), do: {:ok, Web.Blob.new([])}

  # The name of a file is `:filename` in the library: `:name` is the name of
  # a field of a form.
  defp adapt("File", "constructor", _member, _self, [bits, name | rest]),
    do: {:ok, Web.File.new(bits, [filename: name] ++ options(rest))}

  defp adapt("File", "getter", "name", %Web.File{filename: name}, []), do: {:ok, name}

  defp adapt("Event", "constructor", _member, _self, [type | init]),
    do: {:ok, Web.Event.new(type, options(init))}

  defp adapt("CustomEvent", "constructor", _member, _self, [type | init]),
    do: {:ok, Web.CustomEvent.new(type, options(init))}

  # A boolean in place of the options is the option `capture`.
  defp adapt("EventTarget", "operation", "addEventListener", self, [type, callback | rest]) do
    {:ok, Web.EventTarget.add_event_listener(self, type, callback, listener_options(rest))}
  end

  defp adapt("EventTarget", "operation", "removeEventListener", self, [type, callback | _rest]),
    do: {:ok, Web.EventTarget.remove_event_listener(self, type, callback)}

  # The base URL of a pattern is an option of the library. In a map of the
  # parts of a pattern, the library reads the key `:baseURL`.
  defp adapt("URLPattern", "constructor", _member, _self, [input, base, options])
       when is_binary(base) do
    {:ok, Web.URLPattern.new(pattern_input(input), Map.put(options, :base_url, base))}
  end

  defp adapt("URLPattern", "constructor", _member, _self, [input | options]),
    do: {:ok, apply(Web.URLPattern, :new, [pattern_input(input) | options])}

  defp adapt("URLPattern", "operation", operation, self, [input | base])
       when operation in ["test", "exec"] do
    {:ok,
     apply(Web.URLPattern, String.to_existing_atom(operation), [self, pattern_input(input) | base])}
  end

  defp adapt(_interface, _kind, _member, _self, _args), do: :default

  # A relative URL of a test is relative to the page. The library has no
  # page: it takes an absolute URL. A URL that is not valid goes to the
  # library with no change, and the library refuses it.
  defp absolute(input) when is_binary(input) do
    case Web.URL.parse(input, Process.get(@page)) do
      %Web.URL{} = url -> Web.URL.href(url)
      nil -> input
    end
  end

  defp absolute(input), do: input

  defp pattern_input(%{base_url: base} = input),
    do: input |> Map.delete(:base_url) |> Map.put(:baseURL, base)

  defp pattern_input(input), do: input

  defp options([%{} = init | _rest]), do: Map.to_list(init)
  defp options(_init), do: []

  defp listener_options([capture | _rest]) when is_boolean(capture), do: %{capture: capture}
  defp listener_options([%{} = options | _rest]), do: options
  defp listener_options(_options), do: %{}

  defp strategy_options([%{} = strategy | _rest]),
    do: strategy |> Map.take([:high_water_mark, :size]) |> Map.to_list()

  defp strategy_options(_strategy), do: []

  # An operation or a setter that changes the object puts the new struct
  # in its handle.
  defp result("setter", message, module, value), do: update(message, module, value)

  defp result("operation", %{"mut" => true} = message, module, value),
    do: update(message, module, value)

  # A pair is a tuple or a list of two items.
  defp result("iterate", _message, _module, pairs) do
    Enum.map(pairs, fn
      {key, value} -> [encode(key), encode(value)]
      [key, value] -> [encode(key), encode(value)]
    end)
  end

  defp result("operation", %{"self" => %{"$h" => handle}}, _module, {:clone, {original, clone}}) do
    put_struct(handle, original)
    encode(clone)
  end

  # A struct that is a value, from a field of its parent, such as the
  # `headers` of a request: see `put_struct/2`.
  defp result("getter", %{"self" => %{"$h" => parent}, "m" => member}, _module, %child{} = value)
       when child in @values do
    field = String.to_atom(snake(member))
    parent_struct = fetch_handle(parent)

    if is_map(parent_struct) and Map.get(parent_struct, field) == value do
      %{
        "$h" => linked_handle(parent, field, value),
        "$c" => Map.fetch!(@classes, child),
        "$i" => 1
      }
    else
      encode(value)
    end
  end

  defp result(_kind, _message, _module, value), do: encode(value)

  defp linked_handle(parent, field, value) do
    case Map.fetch(get(:children), {parent, field}) do
      {:ok, handle} ->
        put(:handles, Map.put(get(:handles), handle, value))
        handle

      :error ->
        handle = get(:next_handle)
        put(:next_handle, handle + 1)
        put(:handles, Map.put(get(:handles), handle, value))
        put(:children, Map.put(get(:children), {parent, field}, handle))
        put(:links, Map.put(get(:links), handle, {parent, field}))
        handle
    end
  end

  # In JavaScript, an attribute such as `request.headers` or
  # `url.searchParams` is the same object each time, and a change of it
  # changes its parent. The structs of the library are values: the bridge
  # puts the new struct of the child in the field of the parent, and the new
  # field of a parent in its child.
  defp put_struct(handle, value) do
    put(:handles, Map.put(get(:handles), handle, value))

    with {:ok, {parent, field}} <- Map.fetch(get(:links), handle),
         %{} = parent_struct <- fetch_handle(parent),
         true <- Map.get(parent_struct, field) != value do
      put_struct(parent, Map.put(parent_struct, field, value))
    end

    for {{^handle, field}, child} <- get(:children), is_map(value) do
      put(:handles, Map.put(get(:handles), child, Map.get(value, field)))
    end

    :ok
  end

  defp update(%{"self" => %{"$h" => handle}}, module, %module{} = value) do
    put_struct(handle, value)
    %{"$u" => 1}
  end

  defp update(_message, _module, _value), do: %{"$u" => 1}

  defp snake(name), do: Macro.underscore(name)

  # ---------------------------------------------------------------------------
  # JavaScript functions
  # ---------------------------------------------------------------------------

  # The same JavaScript function is the same Elixir function: for example,
  # `remove_event_listener/3` finds the listener.
  defp js_function(id, arity) do
    case Map.fetch(get(:function_ids), id) do
      {:ok, fun} ->
        fun

      :error ->
        fun = new_js_function(self(), id, arity)
        put(:functions, Map.put(get(:functions), fun, id))
        put(:function_ids, Map.put(get(:function_ids), id, fun))
        fun
    end
  end

  defp new_js_function(bridge, id, 0), do: fn -> call_js(bridge, id, []) end
  defp new_js_function(bridge, id, 1), do: fn a -> call_js(bridge, id, [a]) end
  defp new_js_function(bridge, id, 2), do: fn a, b -> call_js(bridge, id, [a, b]) end
  defp new_js_function(bridge, id, _more), do: fn a, b, c -> call_js(bridge, id, [a, b, c]) end

  # The function returns the value of the JavaScript function, or throws
  # its exception. A promise of JavaScript is a `Web.Promise`.
  defp call_js(bridge, id, args) do
    ref = make_ref()
    send(bridge, {:invoke, self(), ref, id, args})

    receive do
      {^ref, {:ok, value}} -> value
      {^ref, {:throw, value}} -> throw(value)
    end
  end

  defp send_invoke(pid, ref, function, args) do
    id = get(:next_invoke)
    put(:next_invoke, id + 1)
    put(:invokes, Map.put(get(:invokes), id, {pid, ref}))
    note_line()
    line = %{"t" => "invoke", "ref" => id, "f" => function, "a" => Enum.map(args, &encode/1)}
    send_line(Map.merge(line, detached_buffers([])))
  end

  defp js_return(%{"ref" => id} = message) do
    {{pid, ref}, invokes} = Map.pop(get(:invokes), id)
    put(:invokes, invokes)
    put(:deferred, MapSet.delete(get(:deferred), id))
    sync_buffers(message["bs"])

    answer =
      cond do
        Map.has_key?(message, "ok") -> {:ok, decode(message["ok"])}
        Map.has_key?(message, "throw") -> {:throw, decode(message["throw"])}
        true -> {:ok, js_promise(message["jp"])}
      end

    drop_buffers(take_call_buffers())
    send(pid, {ref, answer})
  end

  # The bridge owns the promise: it lives until the end of the run. Its
  # process is a process of the run: see `release/0`.
  defp js_promise(id) do
    {promise, resolve, reject} = Web.Promise.with_resolvers()
    Process.group_leader(promise.pid, get(:group))
    put(:js_promises, Map.put(get(:js_promises), id, {resolve, reject}))
    promise
  end

  defp js_settled(%{"p" => id} = message) do
    {{resolve, reject}, promises} = Map.pop(get(:js_promises), id)
    put(:js_promises, promises)
    sync_buffers(message["bs"])

    {settle, value} =
      if Map.has_key?(message, "ok"),
        do: {resolve, decode(message["ok"])},
        else: {reject, decode(message["error"])}

    drop_buffers(take_call_buffers())
    settle.(value)
  end

  # ---------------------------------------------------------------------------
  # Promises of the library
  # ---------------------------------------------------------------------------

  # A promise that JavaScript has already is the same JavaScript object,
  # also after it settled.
  defp encode_promise(%Web.Promise{pid: pid} = promise) when is_pid(pid) do
    case Map.fetch(get(:promises), pid) do
      {:ok, id} -> %{"$pr" => id}
      :error -> encode_new_promise(promise)
    end
  end

  defp encode_promise(promise), do: encode_new_promise(promise)

  defp encode_new_promise(%Web.Promise{pid: pid} = promise) do
    case Web.Promise.peek(promise) do
      {:fulfilled, value} -> %{"$pv" => %{"ok" => encode(value)}}
      {:rejected, reason} -> %{"$pv" => %{"error" => encode(reason)}}
      :released -> %{"$pv" => %{"error" => type_error("The promise is not available.")}}
      :pending -> %{"$pr" => watch(pid, promise)}
    end
  end

  # One JavaScript promise for each process of a promise.
  defp watch(pid, promise) do
    case Map.fetch(get(:promises), pid) do
      {:ok, id} ->
        id

      :error ->
        id = get(:next_promise)
        put(:next_promise, id + 1)
        put(:promises, Map.put(get(:promises), pid, id))
        bridge = self()
        spawn_in_group(fn -> send(bridge, {:settled, id, Web.Promise.wait(promise)}) end)
        id
    end
  end

  # The watchers of the promises run at the same time: the sequence of their
  # messages changes from run to run. Thus the bridge sends the lines
  # `settle` when the processes are at rest, in the sequence of the promises
  # in JavaScript, before the answers.
  defp send_settles do
    settles = get(:settles)
    put(:settles, %{})
    for {id, outcome} <- Enum.sort(settles), do: send_settle(id, outcome)
  end

  defp send_settle(id, outcome) do
    note_line()

    line =
      case outcome do
        {:fulfilled, value} -> %{"t" => "settle", "p" => id, "ok" => encode(value)}
        {:rejected, reason} -> %{"t" => "settle", "p" => id, "error" => encode(reason)}
      end

    send_line(Map.merge(line, detached_buffers([])))
  end

  # ---------------------------------------------------------------------------
  # Buffers
  #
  # A buffer is a value in the library, and an object in JavaScript. The
  # layer gives each buffer a key (`k`), and sends all its bytes with the
  # offset and the length of the view (`$ab`). Thus the library gets a view
  # with the bounds of the view of JavaScript. Three rules keep the two
  # sides the same:
  #
  #   * A buffer that JavaScript gives in a call has a struct for the time
  #     of the call. When the library detaches it, for example with a read
  #     into a view, the answer names its key (`det`), and the layer
  #     detaches the JavaScript buffer.
  #   * A buffer that the library gives to JavaScript, and that a struct of
  #     a handle holds (for example the view of a `ReadableStreamBYOBRequest`),
  #     is "watched". It has a key of the bridge, and JavaScript keeps one
  #     object for it. Before each call, the layer sends the bytes that
  #     JavaScript wrote into it, and tells when JavaScript detached it
  #     (`bs`). The bridge puts these bytes into each struct that a call gets
  #     (`refresh_buffers/1`), and detaches the struct for a detach. The
  #     answers name a watched buffer that the library detached.
  #   * Each other buffer of the library is a new JavaScript buffer.
  #
  # The keys of the layer are above 0, and the keys of the bridge below 0.
  # ---------------------------------------------------------------------------

  defp init_buffers do
    put(:buffers, %{})
    put(:watched, %{})
    put(:held, MapSet.new())
    put(:views, %{})
    put(:next_buffer_key, -1)
    put(:call_buffers, [])
  end

  # The bytes that JavaScript wrote into the watched buffers, and the
  # watched buffers that JavaScript detached.
  defp sync_buffers(nil), do: :ok

  defp sync_buffers(changes) do
    for [key, change] <- changes, buffer = Map.get(get(:buffers), key) do
      case change do
        "detached" ->
          _detached = Web.ArrayBuffer.detach(buffer)
          forget_buffer(key)

        bytes ->
          put_buffer(key, %{buffer | data: :erlang.list_to_binary(bytes)})
      end
    end

    :ok
  end

  defp decode_buffer(%{"k" => key} = entry) do
    buffer =
      case {Map.fetch(get(:buffers), key), entry} do
        {{:ok, known}, %{"d" => 1}} ->
          Web.ArrayBuffer.detach(known)

        {{:ok, known}, %{"b" => bytes}} ->
          known = %{known | data: :erlang.list_to_binary(bytes)}
          put_buffer(key, known)
          known

        {:error, _entry} ->
          buffer = new_buffer(entry)
          put_buffer(key, buffer)
          put(:call_buffers, [key | get(:call_buffers)])
          buffer
      end

    offset = Map.get(entry, "o", 0)
    length = Map.get(entry, "l", Web.ArrayBuffer.byte_length(buffer))
    %Web.Uint8Array{id: make_ref(), buffer: buffer, byte_offset: offset, byte_length: length}
  end

  defp new_buffer(%{"d" => 1}), do: Web.ArrayBuffer.detach(Web.ArrayBuffer.new(0))
  defp new_buffer(%{"b" => bytes}), do: Web.ArrayBuffer.new(:erlang.list_to_binary(bytes))

  defp put_buffer(key, buffer), do: put(:buffers, Map.put(get(:buffers), key, buffer))

  defp forget_buffer(key) do
    {buffer, buffers} = Map.pop(get(:buffers), key)
    put(:buffers, buffers)
    if buffer, do: put(:watched, Map.delete(get(:watched), buffer.id))
  end

  # The keys of the buffers that the decode of a call or a return made.
  defp take_call_buffers do
    keys = get(:call_buffers)
    put(:call_buffers, [])
    keys
  end

  defp drop_buffers(keys), do: Enum.each(keys, &forget_buffer/1)

  # A struct that a call gets has the bytes that JavaScript wrote into each
  # watched buffer.
  defp refresh_buffers(value) do
    if get(:watched) == %{}, do: value, else: refresh(value, get(:watched), get(:buffers))
  end

  defp refresh(%Web.ArrayBuffer{id: id} = buffer, watched, buffers) do
    with {:ok, key} <- Map.fetch(watched, id),
         {:ok, latest} <- Map.fetch(buffers, key),
         do: latest,
         else: (_missing -> buffer)
  end

  defp refresh(%Ref{} = ref, _watched, _buffers), do: ref
  defp refresh(%{} = map, w, b), do: :maps.map(fn _key, value -> refresh(value, w, b) end, map)
  defp refresh(list, w, b) when is_list(list), do: Enum.map(list, &refresh(&1, w, b))

  defp refresh(tuple, w, b) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> refresh(w, b) |> List.to_tuple()

  defp refresh(value, _watched, _buffers), do: value

  # The keys of the buffers that the library detached, for the line `det`.
  # The keys of the call (`call_keys`) end with its answer.
  defp detached_buffers(call_keys) do
    detached = for {key, buffer} <- get(:buffers), Web.ArrayBuffer.detached?(buffer), do: key
    drop_buffers(Enum.uniq(detached ++ call_keys))
    if detached == [], do: %{}, else: %{"det" => detached}
  end

  # The buffers in a struct of a handle are watched when they go to
  # JavaScript.
  defp hold_buffers(value) do
    case buffer_ids(value) do
      [] -> :ok
      ids -> put(:held, MapSet.union(get(:held), MapSet.new(ids)))
    end
  end

  defp buffer_ids(%Web.ArrayBuffer{id: id}), do: [id]
  defp buffer_ids(%Ref{}), do: []
  defp buffer_ids(%{} = map), do: map |> Map.values() |> Enum.flat_map(&buffer_ids/1)
  defp buffer_ids(list) when is_list(list), do: Enum.flat_map(list, &buffer_ids/1)
  defp buffer_ids(tuple) when is_tuple(tuple), do: buffer_ids(Tuple.to_list(tuple))
  defp buffer_ids(_value), do: []

  defp encode_buffer(%Web.ArrayBuffer{} = buffer, view) do
    bytes =
      if Web.ArrayBuffer.detached?(buffer),
        do: %{"d" => 1},
        else: %{"b" => :binary.bin_to_list(buffer.data)}

    bounds =
      case view do
        nil -> %{"a" => 1}
        %Web.Uint8Array{} -> %{"o" => view.byte_offset, "l" => view.byte_length}
      end

    bytes |> Map.merge(bounds) |> Map.merge(watch_buffer(buffer, view))
  end

  defp watch_buffer(%Web.ArrayBuffer{id: id} = buffer, view) do
    if MapSet.member?(get(:held), id) and not Web.ArrayBuffer.detached?(buffer) do
      key =
        case Map.fetch(get(:watched), id) do
          {:ok, key} ->
            key

          :error ->
            key = next_buffer_key()
            put(:watched, Map.put(get(:watched), id, key))
            put_buffer(key, buffer)
            key
        end

      Map.merge(%{"k" => key}, view_key(view))
    else
      %{}
    end
  end

  # One JavaScript object for each watched view.
  defp view_key(nil), do: %{}

  defp view_key(%Web.Uint8Array{id: id}) do
    case Map.fetch(get(:views), id) do
      {:ok, key} ->
        %{"v" => key}

      :error ->
        key = next_buffer_key()
        put(:views, Map.put(get(:views), id, key))
        %{"v" => key}
    end
  end

  defp next_buffer_key do
    key = get(:next_buffer_key)
    put(:next_buffer_key, key - 1)
    key
  end

  # ---------------------------------------------------------------------------
  # The values
  # ---------------------------------------------------------------------------

  defp get(key), do: Map.fetch!(Process.get(@state), key)
  defp put(key, value), do: Process.put(@state, Map.put(Process.get(@state), key, value))

  defp fetch_handle(handle), do: Map.fetch!(get(:handles), handle)

  defp new_handle(%module{} = value) do
    interned = get(:interned)

    case Map.fetch(interned, value) do
      {:ok, handle} ->
        handle

      :error ->
        handle = get(:next_handle)
        put(:next_handle, handle + 1)
        put(:handles, Map.put(get(:handles), handle, value))
        if module not in @values, do: put(:interned, Map.put(interned, value, handle))
        hold_buffers(value)
        handle
    end
  end

  defp decode(%{"$h" => handle}), do: fetch_handle(handle)
  defp decode(%{"$ab" => entry}), do: decode_buffer(entry)
  defp decode(%{"$bs" => bytes}), do: :erlang.list_to_binary(bytes)
  defp decode(%{"$u" => _}), do: nil
  defp decode(%{"$null" => _}), do: :null
  defp decode(%{"$js" => id}), do: %Ref{id: id}
  defp decode(%{"$f" => id, "n" => arity}), do: js_function(id, arity)
  defp decode(%{"$n" => "-0"}), do: -0.0
  defp decode(%{"$n" => "NaN"}), do: :nan
  defp decode(%{"$n" => "Infinity"}), do: :infinity
  defp decode(%{"$n" => "-Infinity"}), do: :neg_infinity

  # A sequence of sequences: each inner list of two items is a pair. A list
  # of a different length stays a list, and the library refuses it.
  defp decode(%{"$p" => items}) do
    Enum.map(items, fn
      [first, second] -> {decode(first), decode(second)}
      other -> decode(other)
    end)
  end

  defp decode(%{"$r" => pairs}), do: Enum.map(pairs, fn [k, v] -> {decode(k), decode(v)} end)

  # A dictionary: the options of the library are maps with snake_case keys.
  defp decode(%{"$d" => members}),
    do: Map.new(members, fn {k, v} -> {String.to_atom(snake(k)), decode(v)} end)

  defp decode(%{"$o" => members}), do: Map.new(members, fn {k, v} -> {k, decode(v)} end)
  defp decode(list) when is_list(list), do: Enum.map(list, &decode/1)
  defp decode(value), do: value

  defp encode(nil), do: nil
  defp encode(:null), do: %{"$null" => 1}
  defp encode(value) when is_boolean(value) or is_number(value), do: value
  defp encode(:nan), do: %{"$n" => "NaN"}
  defp encode(:infinity), do: %{"$n" => "Infinity"}
  defp encode(:neg_infinity), do: %{"$n" => "-Infinity"}
  defp encode(value) when is_atom(value), do: Atom.to_string(value)

  defp encode(value) when is_binary(value) do
    if String.valid?(value), do: value, else: %{"$b" => :binary.bin_to_list(value)}
  end

  defp encode(list) when is_list(list), do: Enum.map(list, &encode/1)
  defp encode(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> encode()
  defp encode(%Ref{id: id}), do: %{"$js" => id}
  defp encode(%Web.Promise{} = promise), do: encode_promise(promise)

  defp encode(%Web.Uint8Array{} = view), do: %{"$ab" => encode_buffer(view.buffer, view)}
  defp encode(%Web.ArrayBuffer{} = buffer), do: %{"$ab" => encode_buffer(buffer, nil)}

  # A struct that refers to a process comes back with the same handle: the
  # layer keeps its object (`$i`).
  defp encode(%module{} = struct) when is_map_key(@classes, module) and module in @values,
    do: %{"$h" => new_handle(struct), "$c" => Map.fetch!(@classes, module)}

  defp encode(%module{} = struct) when is_map_key(@classes, module),
    do: %{"$h" => new_handle(struct), "$c" => Map.fetch!(@classes, module), "$i" => 1}

  # The same error of the library is the same JavaScript object, for example
  # the stored error of a stream in each promise that rejects with it.
  defp encode(error) when is_exception(error) do
    %{"$err" => fields} = encode_error(error)
    %{"$err" => Map.put(fields, "id", error_id(error))}
  end

  defp encode(%_{} = struct), do: struct |> Map.from_struct() |> encode()

  defp encode(%{} = map),
    do: %{"$o" => Map.new(map, fn {k, v} -> {text(to_string(k)), encode(v)} end)}

  defp encode(fun) when is_function(fun) do
    case Map.fetch(get(:functions), fun) do
      {:ok, id} -> %{"$f" => id}
      :error -> inspect(fun)
    end
  end

  defp encode(other), do: inspect(other)

  # An error of the library goes to JavaScript with the name of its kind.
  # An error that is not an error of a Standard, such as `ArgumentError`,
  # keeps its own name: the test then shows that the library raises a
  # different error than the Standard.
  defp encode_error(%Web.TypeError{message: message}),
    do: %{"$err" => %{"name" => "TypeError", "message" => text(message)}}

  defp encode_error(%Web.RangeError{message: message}),
    do: %{"$err" => %{"name" => "RangeError", "message" => text(message)}}

  defp encode_error(%Web.SyntaxError{message: message}),
    do: %{"$err" => %{"name" => "SyntaxError", "message" => text(message)}}

  defp encode_error(%Web.DOMException{} = error) do
    %{
      "$err" => %{
        "name" => "DOMException",
        "domName" => error.name,
        "message" => text(error.message)
      }
    }
  end

  defp encode_error(error) do
    %{
      "$err" => %{
        "name" => "Error",
        "message" => text("#{inspect(error.__struct__)}: #{Exception.message(error)}")
      }
    }
  end

  defp error_id(error) do
    case Map.fetch(get(:errors), error) do
      {:ok, id} ->
        id

      :error ->
        id = map_size(get(:errors)) + 1
        put(:errors, Map.put(get(:errors), error, id))
        id
    end
  end

  # A message or a key can have bytes that are not UTF-8: JSON has only text.
  defp text(value) when is_binary(value), do: String.replace_invalid(value)
  defp text(value), do: inspect(value)
end
