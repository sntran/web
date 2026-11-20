defmodule Web.Test.QuickJS.Bridge do
  @moduledoc false

  # Runs one file of web-platform-tests in QuickJS against the library.
  #
  # QuickJS runs `testharness.js` and the test file with no change. The
  # classes of the interfaces come from the WebIDL files of WPT: see
  # `test/support/wpt/quickjs/webidl_layer.js`. Each method of a class sends
  # a call to this process, in lines of JSON on the standard input and
  # output of QuickJS. This process calls the function of the library, and
  # gives the result back.
  #
  # The library has immutable structs. A JavaScript object is a handle: this
  # process keeps the struct of each handle. An operation that returns
  # `undefined` in WebIDL, such as `append` of `Headers`, puts the new struct
  # of the library in the handle.
  #
  # The name of a member goes to a function of the library with these rules:
  #
  #   * the constructor is `new`;
  #   * `getSetCookie` is `get_set_cookie`, and a boolean can end with `?`;
  #   * the setter of an attribute is `name/2` or `set_name/2`;
  #   * the getter of an attribute is `name/1`, or a field of the struct;
  #   * the pairs of an iterable come from `entries/1` or `to_list/1`.
  #
  # A member with no function of the library fails with a message that
  # names the missing function.

  alias Web.Platform.Test, as: WPT
  alias Web.Test.QuickJS

  @runner Path.expand("../wpt/quickjs/runner.js", __DIR__)
  @layer Path.expand("../wpt/quickjs/webidl_layer.js", __DIR__)
  @timeout 60_000

  @interfaces %{
    "Headers" => Web.Headers,
    "TextDecoder" => Web.TextDecoder,
    "TextEncoder" => Web.TextEncoder,
    "URL" => Web.URL,
    "URLSearchParams" => Web.URLSearchParams
  }

  @idls [
    "interfaces/encoding.idl",
    "interfaces/fetch.idl",
    "interfaces/url.idl"
  ]

  @handles {__MODULE__, :handles}

  @doc """
  Runs the WPT file at `path`, such as `"url/url-searchparams.any.js"`.
  Returns `%{status: status, message: message, results: results, log: log}`:
  the status of the harness, and a map from the name of each test to
  `{status, message}`.
  """
  def run!(path) do
    source = File.read!(WPT.tree_file!(path))

    start = %{
      harness: WPT.tree_file!("resources/testharness.js"),
      idlParser: WPT.tree_file!("resources/webidl2/lib/webidl2.js"),
      layer: @layer,
      idls: Enum.map(@idls, &WPT.tree_file!/1),
      exposed: Map.keys(@interfaces),
      scripts: Enum.map(meta_scripts(source, Path.dirname(path)), &WPT.tree_file!/1),
      test: WPT.tree_file!(path),
      dir: Path.dirname(path)
    }

    port =
      Port.open({:spawn_executable, QuickJS.path!()}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:line, 65_536},
        args: [@runner]
      ])

    Process.put(@handles, {1, %{}})
    Port.command(port, JSON.encode!(start) <> "\n")

    try do
      loop(port, %{line: "", results: %{}, order: [], log: [], done: nil})
    after
      Process.delete(@handles)
      close(port)
    end
  end

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

  defp loop(port, state) do
    receive do
      {^port, {:data, {:noeol, chunk}}} ->
        loop(port, %{state | line: state.line <> chunk})

      {^port, {:data, {:eol, chunk}}} ->
        line = state.line <> chunk
        state = %{state | line: ""}

        case handle_line(line, port, state) do
          {:done, state} -> finish(state)
          state -> loop(port, state)
        end

      {^port, {:exit_status, status}} ->
        finish(%{
          state
          | done: state.done || {"CRASH", "QuickJS stopped with the status #{status}."}
        })
    after
      @timeout -> finish(%{state | done: {"TIMEOUT", "No message in #{@timeout} ms."}})
    end
  end

  defp finish(state) do
    {status, message} = state.done

    %{
      status: status,
      message: message,
      results: state.results,
      order: Enum.reverse(state.order),
      log: state.log |> Enum.reverse() |> Enum.join("\n")
    }
  end

  defp handle_line("{" <> _rest = line, port, state) do
    case JSON.decode!(line) do
      %{"t" => "call", "id" => id} = message ->
        reply(port, id, call(message))
        state

      %{"t" => "resource", "id" => id, "p" => path} ->
        reply(port, id, resource(path))
        state

      %{"t" => "result", "name" => name, "status" => status, "message" => message} ->
        %{
          state
          | results: Map.put(state.results, name, {status, message}),
            order: [name | state.order]
        }

      %{"t" => "done", "status" => status, "message" => message} ->
        {:done, %{state | done: {status, message}}}
    end
  end

  # A line that is not JSON is an output of QuickJS, for example an error
  # of a script.
  defp handle_line(line, _port, state), do: %{state | log: [line | state.log]}

  # A data file of a test. A path that is not a file, for example a
  # directory, gives a `TypeError` to the `fetch` of the test.
  defp resource(path) do
    case File.read(WPT.tree_file!(path)) do
      {:ok, text} ->
        {:ok, text}

      {:error, reason} ->
        {:error, %{"name" => "TypeError", "message" => "No file #{path}: #{reason}"}}
    end
  rescue
    error -> {:error, %{"name" => "TypeError", "message" => Exception.message(error)}}
  catch
    :exit, reason -> {:error, %{"name" => "TypeError", "message" => inspect(reason)}}
  end

  defp reply(port, id, {:ok, value}), do: send_line(port, %{"id" => id, "ok" => value})
  defp reply(port, id, {:error, error}), do: send_line(port, %{"id" => id, "error" => error})

  defp send_line(port, message), do: Port.command(port, JSON.encode!(message) <> "\n")

  # ---------------------------------------------------------------------------
  # A call of the library
  # ---------------------------------------------------------------------------

  defp call(%{"i" => interface, "k" => kind} = message) do
    module = Map.fetch!(@interfaces, interface)
    args = Enum.map(Map.get(message, "a", []), &decode/1)
    self = with %{"$h" => handle} <- message["self"], do: fetch_handle(handle)

    case invoke(kind, module, message["m"], self, args) do
      {:ok, result} ->
        {:ok, result(kind, message, module, result)}

      {:missing, name} ->
        {:error, %{"name" => "TypeError", "message" => "The library has no #{name}."}}
    end
  rescue
    error ->
      if System.get_env("WEB_BRIDGE_DEBUG"),
        do: IO.puts(Exception.format(:error, error, __STACKTRACE__))

      {:error, error_of(error)}
  catch
    kind, reason ->
      {:error, %{"name" => "Error", "message" => "#{kind}: #{inspect(reason)}"}}
  end

  defp invoke("constructor", module, _member, _self, args),
    do: apply_first(module, [{"new", args}])

  defp invoke("operation", module, member, self, args) do
    name = snake(member)
    apply_first(module, [{name, [self | args]}, {name <> "?", [self | args]}])
  end

  defp invoke("static", module, member, _self, args),
    do: apply_first(module, [{snake(member), args}])

  defp invoke("getter", module, member, self, []) do
    name = snake(member)

    case apply_first(module, [{name, [self]}, {name <> "?", [self]}]) do
      {:missing, _} = missing -> field(self, [name, name <> "?"], missing)
      found -> found
    end
  end

  defp invoke("setter", module, member, self, [value]) do
    name = snake(member)
    apply_first(module, [{name, [self, value]}, {"set_" <> name, [self, value]}])
  end

  defp invoke("iterate", module, _member, self, []),
    do: apply_first(module, [{"entries", [self]}, {"to_list", [self]}])

  defp invoke("stringify", module, _member, self, []) do
    case apply_first(module, [{"to_string", [self]}, {"href", [self]}]) do
      {:missing, _} = missing ->
        if String.Chars.impl_for(self), do: {:ok, to_string(self)}, else: missing

      found ->
        found
    end
  end

  # The first function that the module exports, with the arity of its
  # arguments.
  defp apply_first(module, candidates) do
    Code.ensure_loaded(module)

    Enum.find_value(candidates, fn {name, args} ->
      atom = String.to_atom(name)
      if function_exported?(module, atom, length(args)), do: {:ok, apply(module, atom, args)}
    end) || {:missing, describe(module, candidates)}
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

  # An operation or a setter that changes the object puts the new struct
  # in its handle.
  defp result("setter", message, module, value), do: update(message, module, value)

  defp result("operation", %{"mut" => true} = message, module, value),
    do: update(message, module, value)

  defp result("iterate", _message, _module, pairs),
    do: Enum.map(pairs, fn {key, value} -> [encode(key), encode(value)] end)

  defp result(_kind, _message, _module, value), do: encode(value)

  defp update(%{"self" => %{"$h" => handle}}, module, %module{} = value) do
    put_handle(handle, value)
    %{"$u" => 1}
  end

  defp update(_message, _module, _value), do: %{"$u" => 1}

  defp snake(name), do: Macro.underscore(name)

  # An error of the library goes to JavaScript with the name of its kind.
  # An error that is not an error of a Standard, such as `ArgumentError`,
  # keeps its own name: the test then shows that the library raises a
  # different error than the Standard.
  defp error_of(%Web.TypeError{message: message}),
    do: %{"name" => "TypeError", "message" => message}

  defp error_of(%Web.RangeError{message: message}),
    do: %{"name" => "RangeError", "message" => message}

  defp error_of(%Web.SyntaxError{message: message}),
    do: %{"name" => "SyntaxError", "message" => message}

  defp error_of(%Web.DOMException{} = error),
    do: %{"name" => "DOMException", "domName" => error.name, "message" => error.message}

  defp error_of(error) do
    %{"name" => "Error", "message" => "#{inspect(error.__struct__)}: #{Exception.message(error)}"}
  end

  # ---------------------------------------------------------------------------
  # The values
  # ---------------------------------------------------------------------------

  defp fetch_handle(handle) do
    {_next, handles} = Process.get(@handles)
    Map.fetch!(handles, handle)
  end

  defp put_handle(handle, value) do
    {next, handles} = Process.get(@handles)
    Process.put(@handles, {next, Map.put(handles, handle, value)})
  end

  defp new_handle(value) do
    {next, handles} = Process.get(@handles)
    Process.put(@handles, {next + 1, Map.put(handles, next, value)})
    next
  end

  defp decode(%{"$h" => handle}), do: fetch_handle(handle)
  defp decode(%{"$b" => bytes}), do: :erlang.list_to_binary(bytes)
  defp decode(%{"$u" => _}), do: nil
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

  @classes Map.new(@interfaces, fn {name, module} -> {module, name} end)

  defp encode(nil), do: nil
  defp encode(value) when is_boolean(value) or is_number(value), do: value
  defp encode(value) when is_atom(value), do: Atom.to_string(value)

  defp encode(value) when is_binary(value) do
    if String.valid?(value), do: value, else: %{"$b" => :binary.bin_to_list(value)}
  end

  defp encode(list) when is_list(list), do: Enum.map(list, &encode/1)
  defp encode(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> encode()

  defp encode(%Web.Uint8Array{} = view),
    do: %{"$b" => :binary.bin_to_list(Web.Uint8Array.to_binary(view))}

  defp encode(%module{} = struct) when is_map_key(@classes, module),
    do: %{"$h" => new_handle(struct), "$c" => Map.fetch!(@classes, module)}

  defp encode(%_{} = struct), do: struct |> Map.from_struct() |> encode()
  defp encode(%{} = map), do: %{"$o" => Map.new(map, fn {k, v} -> {to_string(k), encode(v)} end)}
end
