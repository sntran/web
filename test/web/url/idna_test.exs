defmodule Web.URL.IdnaTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  use Web.Platform.Test,
    urls: [
      "https://raw.githubusercontent.com/web-platform-tests/wpt/master/url/resources/IdnaTestV2.json"
    ],
    prefix: "URL IDNA WPT compliance"

  alias Web.URL.{Idna, IP}

  @idna_cache_key {Web.URL.Idna, :lookup}

  setup do
    on_exit(fn ->
      :persistent_term.erase(@idna_cache_key)
      stop_idna_node()
    end)

    :ok
  end

  @impl Web.Platform.Test
  def web_platform_test(%{"input" => input, "output" => output} = test_case)
      when is_binary(output) or is_nil(output) do
    run_host_ascii_test!(test_case, input, output)
  end

  def web_platform_test(test_case) when is_binary(test_case) do
    run_simple_encoding_test!(test_case)
  end

  def web_platform_test(_test_case), do: :ok

  defp run_simple_encoding_test!(_test_case), do: :ok

  defp run_host_ascii_test!(test_case, input, expected_output) do
    if String.contains?(Map.get(test_case, "comment", ""), "(ignored)") do
      :ok
    else
      failure = Map.get(test_case, "failure", false)

      actual =
        if IP.valid_host?(input, "https:") do
          IP.normalize_host(input, "https:")
        else
          nil
        end

      cond do
        failure and is_nil(actual) ->
          :ok

        failure ->
          raise ExUnit.AssertionError,
            message:
              "Expected host parsing to fail for #{inspect(input)}, but got #{inspect(actual)}"

        actual == expected_output ->
          :ok

        true ->
          raise ExUnit.AssertionError,
            message:
              "Host ASCII mismatch for #{inspect(input)}: expected #{inspect(expected_output)}, got #{inspect(actual)}"
      end
    end
  end

  test "idna conformance lookup handles missing and custom fixture files" do
    with_temp_cwd(fn _tmp_dir ->
      :persistent_term.erase(@idna_cache_key)
      assert Idna.lookup("missing.example") == :miss
    end)

    with_fixture_files(%{"toascii.json" => "{}"}, fn ->
      assert Idna.lookup("missing.example") == :miss
    end)

    with_fixture_files(
      %{
        "toascii.json" =>
          Jason.encode!([
            %{"input" => "fixture.example", "output" => "mapped.example"},
            %{"input" => "bad.example", "output" => nil}
          ])
      },
      fn ->
        assert Idna.lookup("fixture.example") == {:ok, "mapped.example"}
        assert Idna.lookup("bad.example") == :error
      end
    )
  end

  test "idna node returns unavailable when node cannot be found" do
    without_node(fn ->
      assert Idna.domain_to_ascii("example.com") == :unavailable
    end)
  end

  test "idna node ignores blank, invalid, and unknown port messages" do
    if System.find_executable("node") do
      assert Idna.domain_to_ascii("example.com") == {:ok, "example.com"}

      pid = Process.whereis(Idna)
      state = :sys.get_state(pid)

      send(pid, {state.port, {:data, "\n"}})
      send(pid, {state.port, {:data, "{\"id\":\"missing\",\"result\":\"x\"}\nnot-json\n"}})

      assert Idna.domain_to_ascii("example.com") == {:ok, "example.com"}
      assert Process.alive?(pid)
    end
  end

  test "idna node restarts after the backing port exits mid-request" do
    if real_node = System.find_executable("node") do
      with_temp_cwd(fn tmp_dir ->
        fake_bin_dir = Path.join(tmp_dir, "bin")
        fake_node_path = Path.join(fake_bin_dir, "node")
        marker_path = Path.join(tmp_dir, "delegate-to-real-node")
        File.mkdir_p!(fake_bin_dir)

        File.write!(
          fake_node_path,
          "#!/bin/sh\nif [ -f '#{marker_path}' ]; then\n  exec '#{real_node}' \"$@\"\nfi\ncat >/dev/null\n"
        )

        File.chmod!(fake_node_path, 0o755)

        capture_log(fn ->
          trap_exits_while(fn ->
            stop_idna_node()

            original_path = System.get_env("PATH")
            System.put_env("PATH", fake_bin_dir <> ":" <> (original_path || ""))

            try do
              owner =
                spawn(fn ->
                  Process.flag(:trap_exit, true)
                  {:ok, _pid} = GenServer.start_link(Idna, fake_node_path, name: Idna)

                  receive do
                    :stop -> :ok
                  end
                end)

              wait_until(fn -> Process.whereis(Idna) != nil end)

              parent = self()

              spawn(fn ->
                wait_until(fn ->
                  case Process.whereis(Idna) do
                    nil ->
                      false

                    pid ->
                      case :sys.get_state(pid).pending do
                        pending when map_size(pending) > 0 -> true
                        _ -> false
                      end
                  end
                end)

                pid = Process.whereis(Idna)
                state = :sys.get_state(pid)
                File.write!(marker_path, "ready")
                send(pid, {state.port, {:exit_status, 1}})
                send(parent, :restart_injected)
              end)

              assert Idna.domain_to_ascii("☃.com") == {:ok, "xn--n3h.com"}
              assert_receive :restart_injected, 5_000
              assert Process.alive?(Process.whereis(Idna))
              send(owner, :stop)
            after
              restore_env("PATH", original_path)
            end
          end)
        end)
      end)
    end
  end

  test "idna node returns unavailable when the registered name is not a server" do
    if System.find_executable("node") do
      stop_idna_node()

      pid =
        spawn(fn ->
          receive do
          end
        end)

      true = Process.register(pid, Idna)

      try do
        assert Idna.domain_to_ascii("example.com") == :unavailable
      after
        if Process.whereis(Idna) == pid do
          Process.unregister(Idna)
        end

        Process.exit(pid, :kill)
      end
    end
  end

  test "idna node tolerates concurrent startup attempts" do
    if System.find_executable("node") do
      stop_idna_node()

      parent = self()

      tasks =
        for _ <- 1..24 do
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> Idna.domain_to_ascii("example.com")
            end
          end)
        end

      Enum.each(1..24, fn _ ->
        assert_receive {:ready, _pid}, 1_000
      end)

      Enum.each(tasks, fn task ->
        send(task.pid, :go)
      end)

      results = Enum.map(tasks, &Task.await(&1, 10_000))

      assert Enum.all?(results, &(&1 == {:ok, "example.com"}))
    end
  end

  defp with_fixture_files(files, fun) do
    with_temp_cwd(fn tmp_dir ->
      fixture_dir = Path.join([tmp_dir, "tmp", "wpt_cache"])
      File.mkdir_p!(fixture_dir)

      Enum.each(files, fn {name, content} ->
        File.write!(Path.join(fixture_dir, name), content)
      end)

      :persistent_term.erase(@idna_cache_key)

      try do
        fun.()
      after
        :persistent_term.erase(@idna_cache_key)
      end
    end)
  end

  defp without_node(fun) do
    stop_idna_node()

    original_path = System.get_env("PATH")

    try do
      System.put_env("PATH", "")
      fun.()
    after
      restore_env("PATH", original_path)
      stop_idna_node()
    end
  end

  defp with_temp_cwd(fun) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "web-url-idna-#{System.unique_integer([:positive])}")

    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)
    original_cwd = File.cwd!()

    try do
      File.cd!(tmp_dir)
      fun.(tmp_dir)
    after
      File.cd!(original_cwd)
      File.rm_rf!(tmp_dir)
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp trap_exits_while(fun) do
    original = Process.flag(:trap_exit, true)

    try do
      fun.()
    after
      Process.flag(:trap_exit, original)
    end
  end

  defp stop_idna_node do
    case Process.whereis(Idna) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 1_000)
    end
  catch
    :exit, _reason -> :ok
  end

  defp wait_until(fun, attempts \\ 100)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition was not met in time")
end
