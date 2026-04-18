defmodule Web.Platform.TestTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Web.Platform.Test, as: PlatformTest

  defmodule ScriptedHTTPServer do
    def start_link(scripts, opts \\ []) do
      parent = self()
      observer = Keyword.get(opts, :observer, parent)

      {:ok, pid} =
        Task.start_link(fn ->
          {:ok, listen_socket} =
            :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

          {:ok, port} = :inet.port(listen_socket)
          send(parent, {:port, port})

          Enum.each(List.wrap(scripts), fn script ->
            {:ok, socket} = :gen_tcp.accept(listen_socket)
            handle_client(socket, script, observer)
          end)

          :gen_tcp.close(listen_socket)
        end)

      port =
        receive do
          {:port, port} -> port
        after
          1_000 -> raise "ScriptedHTTPServer failed to start"
        end

      %{pid: pid, port: port}
    end

    defp handle_client(socket, script, observer) do
      case script do
        :close ->
          :gen_tcp.close(socket)

        _ ->
          {:ok, request} = :gen_tcp.recv(socket, 0, 1_000)
          send(observer, {:scripted_http_request, request_path(request)})
          serve_script(socket, script)
      end
    end

    defp serve_script(socket, {:tracked_response, tracker, delay_ms, status, headers, body}) do
      Agent.update(tracker, fn %{current: current, max: max} = state ->
        next = current + 1
        %{state | current: next, max: Kernel.max(max, next)}
      end)

      try do
        Process.sleep(delay_ms)
        send_response(socket, status, headers, body)
      after
        Agent.update(tracker, fn %{current: current} = state ->
          %{state | current: Kernel.max(current - 1, 0)}
        end)

        :gen_tcp.close(socket)
      end
    end

    defp serve_script(socket, {:response, status, headers, body}) do
      send_response(socket, status, headers, body)
      :gen_tcp.close(socket)
    end

    defp serve_script(socket, {:response, status, headers, body, delay_ms}) do
      Process.sleep(delay_ms)
      send_response(socket, status, headers, body)
      :gen_tcp.close(socket)
    end

    defp serve_script(
           socket,
           {:partial_response, status, headers, partial_body, total_length, delay_ms}
         ) do
      send_partial_response(socket, status, headers, partial_body, total_length)
      Process.sleep(delay_ms)
      :gen_tcp.close(socket)
    end

    defp send_response(socket, status, headers, body) do
      body = IO.iodata_to_binary(body)

      headers =
        [{"content-length", byte_size(body)} | headers]
        |> Enum.map_join(fn {name, value} -> "#{name}: #{value}\r\n" end)

      response =
        [
          "HTTP/1.1 ",
          Integer.to_string(status),
          " ",
          status_text(status),
          "\r\n",
          headers,
          "\r\n",
          body
        ]
        |> IO.iodata_to_binary()

      case :gen_tcp.send(socket, response) do
        :ok -> :ok
        {:error, :closed} -> :ok
      end
    end

    defp send_partial_response(socket, status, headers, partial_body, total_length) do
      partial_body = IO.iodata_to_binary(partial_body)

      headers =
        [{"content-length", total_length} | headers]
        |> Enum.map_join(fn {name, value} -> "#{name}: #{value}\r\n" end)

      response =
        [
          "HTTP/1.1 ",
          Integer.to_string(status),
          " ",
          status_text(status),
          "\r\n",
          headers,
          "\r\n",
          partial_body
        ]
        |> IO.iodata_to_binary()

      case :gen_tcp.send(socket, response) do
        :ok -> :ok
        {:error, :closed} -> :ok
      end
    end

    defp request_path(request) do
      request
      |> String.split("\r\n", parts: 2)
      |> hd()
      |> String.split(" ", parts: 3)
      |> Enum.at(1)
    end

    defp status_text(200), do: "OK"
    defp status_text(429), do: "Too Many Requests"
    defp status_text(status), do: Integer.to_string(status)
  end

  test "load_json!/1 retries 429 responses with retry-after headers" do
    basename = unique_basename("rate-limited")
    path = "/#{basename}"

    server =
      ScriptedHTTPServer.start_link([
        {:response, 429, [{"retry-after", "0"}], ""},
        {:response, 200, [{"content-type", "application/json"}], ~s([{"ok":true}])}
      ])

    url = "http://127.0.0.1:#{server.port}#{path}"

    try do
      clear_cache(url)

      assert [%{"ok" => true}] == PlatformTest.load_json!(url)
      assert_receive {:scripted_http_request, ^path}, 1_000
      assert_receive {:scripted_http_request, ^path}, 1_000
    after
      clear_cache(url)
    end
  end

  test "load_json!/1 retries transient network failures" do
    basename = unique_basename("transient")
    path = "/#{basename}"

    server =
      ScriptedHTTPServer.start_link([
        :close,
        {:response, 200, [{"content-type", "application/json"}], ~s({"ok":true})}
      ])

    url = "http://127.0.0.1:#{server.port}#{path}"

    try do
      clear_cache(url)

      assert %{"ok" => true} == PlatformTest.load_json!(url)
      assert_receive {:scripted_http_request, ^path}, 1_000
    after
      clear_cache(url)
    end
  end

  test "load_json!/1 shares a global governor capped at five concurrent fetches" do
    {:ok, tracker} = Agent.start_link(fn -> %{current: 0, max: 0} end)

    urls =
      for index <- 1..8 do
        basename = unique_basename("governor-#{index}")

        server =
          ScriptedHTTPServer.start_link([
            {:tracked_response, tracker, 150, 200, [{"content-type", "application/json"}],
             ~s({"index":#{index}})}
          ])

        url = "http://127.0.0.1:#{server.port}/#{basename}"
        clear_cache(url)
        url
      end

    try do
      results =
        urls
        |> Task.async_stream(&PlatformTest.load_json!/1,
          max_concurrency: 8,
          ordered: false,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.sort_by(results, & &1["index"]) ==
               Enum.map(1..8, fn index -> %{"index" => index} end)

      assert Agent.get(tracker, & &1.max) == 5
    after
      Enum.each(urls, &clear_cache/1)
      Agent.stop(tracker)
    end
  end

  test "load_json!/1 fails promptly when a response body stalls after headers" do
    basename = unique_basename("stalled-body")
    path = "/#{basename}"

    server =
      ScriptedHTTPServer.start_link([
        {:partial_response, 200, [{"content-type", "application/json"}], "{", 8, 500}
      ])

    url = "http://127.0.0.1:#{server.port}#{path}"

    try do
      clear_cache(url)

      started_at = System.monotonic_time(:millisecond)

      with_wpt_options(
        [fetch_timeout_ms: 100, max_total_fetch_ms: 150, max_fetch_attempts: 1],
        fn ->
          assert %ArgumentError{} =
                   catch_exit(
                     (fn ->
                        PlatformTest.load_json!(url)
                      end).()
                   )
        end
      )

      assert elapsed_ms(started_at) < 400
      assert_receive {:scripted_http_request, ^path}, 1_000
    after
      clear_cache(url)
    end
  end

  test "load_json!/1 bounds total retry time for stalled responses" do
    basename = unique_basename("retry-budget")
    path = "/#{basename}"

    server =
      ScriptedHTTPServer.start_link([
        {:partial_response, 200, [{"content-type", "application/json"}], "{", 8, 500},
        {:partial_response, 200, [{"content-type", "application/json"}], "{", 8, 500}
      ])

    url = "http://127.0.0.1:#{server.port}#{path}"

    try do
      clear_cache(url)

      started_at = System.monotonic_time(:millisecond)

      with_wpt_options(
        [
          fetch_timeout_ms: 100,
          max_total_fetch_ms: 220,
          max_fetch_attempts: 4,
          base_backoff_ms: 10,
          max_backoff_ms: 10
        ],
        fn ->
          assert %ArgumentError{} =
                   catch_exit(
                     (fn ->
                        PlatformTest.load_json!(url)
                      end).()
                   )
        end
      )

      assert elapsed_ms(started_at) < 700
      assert_receive {:scripted_http_request, ^path}, 1_000
    after
      clear_cache(url)
    end
  end

  test "load_many!/1 parses supported structured clone JS datasets" do
    basename = "structured-clone-battery-of-tests.js"
    path = "/#{basename}"

    js = """
    check('primitive true', true, compare_primitive);
    check('primitive string, NUL', '\\u0000', compare_primitive);
    check('Date 0', new Date(0), compare_Date);
    check('RegExp empty', new RegExp(''), compare_RegExp('(?:)'));
    function func_Blob_basic() { return new Blob(['foo'], {type:'text/x-bar'}); }
    function func_Blob_empty() { return new Blob(['']); }
    function func_Blob_NUL() { return new Blob(['\\u0000']); }
    check('Blob basic', func_Blob_basic, compare_Blob);
    check('Blob empty', func_Blob_empty, compare_Blob);
    check('Blob NUL', func_Blob_NUL, compare_Blob);
    check('Array with identical property values', function() { const obj = {}; return [obj, obj]; }, compare_Array(check_identical_property_values('0', '1')));
    structuredCloneBatteryOfTests.push({ description: 'Serializing a non-serializable platform object fails', async f(runner, t) {} });
    """

    server =
      ScriptedHTTPServer.start_link([
        {:response, 200, [{"content-type", "text/javascript"}], js}
      ])

    url = "http://127.0.0.1:#{server.port}#{path}"

    try do
      clear_cache(url)

      assert [%{url: ^url, cases: cases}] = PlatformTest.load_many!([url])
      assert Enum.any?(cases, &(&1["kind"] == "primitive" and &1["value"] == true))
      assert Enum.any?(cases, &(&1["kind"] == "blob" and &1["type"] == "text/x-bar"))
      assert Enum.any?(cases, &(&1["kind"] == "shared_reference_array"))
      assert Enum.any?(cases, &(&1["kind"] == "data_clone_error"))
    after
      clear_cache(url)
    end
  end

  test "load_many!/1 parses supported structured clone transfer JS datasets" do
    basename = "structured-clone-battery-of-tests-with-transferables.js"
    path = "/#{basename}"

    js = """
    structuredCloneBatteryOfTests.push({
      description: 'ArrayBuffer',
      async f(runner) {
        const buffer = new Uint8Array([1, 2]).buffer;
        const copy = await runner.structuredClone(buffer, [buffer]);
      }
    });

    structuredCloneBatteryOfTests.push({
      description: 'Transferring a non-transferable platform object fails',
      async f(runner, t) {
        const blob = new Blob();
      }
    });
    """

    server =
      ScriptedHTTPServer.start_link([
        {:response, 200, [{"content-type", "text/javascript"}], js}
      ])

    url = "http://127.0.0.1:#{server.port}#{path}"

    try do
      clear_cache(url)

      assert [%{url: ^url, cases: cases}] = PlatformTest.load_many!([url])

      assert Enum.any?(cases, &(&1["kind"] == "transfer_array_buffer" and &1["bytes"] == [1, 2]))
      assert Enum.any?(cases, &(&1["kind"] == "transfer_blob_error"))
    after
      clear_cache(url)
    end
  end

  defp unique_basename(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}.json"
  end

  defp elapsed_ms(started_at) do
    System.monotonic_time(:millisecond) - started_at
  end

  defp with_wpt_options(options, fun) do
    key = Web.Platform.Test
    previous = Application.get_env(:web, key, [])
    Application.put_env(:web, key, options)

    try do
      fun.()
    after
      Application.put_env(:web, key, previous)
    end
  end

  defp clear_cache(url) do
    basename = Path.basename(url)
    cache_dir = Path.expand("tmp/wpt_cache", Elixir.File.cwd!())

    Enum.each([basename, basename <> ".meta"], fn filename ->
      path = Path.join(cache_dir, filename)

      if Elixir.File.exists?(path) do
        Elixir.File.rm!(path)
      end
    end)
  end
end
