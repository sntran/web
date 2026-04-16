defmodule Web.URL.PunycodeTest do
  use ExUnit.Case, async: false

  alias Web.URL.{Idna, Punycode}

  @idna_cache_key {Web.URL.Idna, :lookup}

  setup do
    on_exit(fn ->
      :persistent_term.erase(@idna_cache_key)
      stop_idna_node()
    end)

    :ok
  end

  test "punycode consults fixtures and covers no-node fallback paths" do
    with_fixture_files(
      %{
        "toascii.json" =>
          Jason.encode!([
            %{"input" => "fixture.example", "output" => "mapped.example"},
            %{"input" => "bad.example", "output" => nil}
          ])
      },
      fn ->
        assert Punycode.host_to_ascii("fixture.example") == "mapped.example"
        assert Punycode.host_to_ascii("bad.example") == "bad.example"
        refute Punycode.valid_host?("bad.example")
      end
    )

    without_node_and_fixtures(fn ->
      assert Punycode.encode("bücher") == "bcher-kva"
      assert Punycode.host_to_ascii("") == ""
      assert Punycode.host_to_ascii("Example。Com") == "example.com"
      assert Punycode.host_to_ascii("bücher.example.") == "xn--bcher-kva.example."
      assert Punycode.host_to_ascii("faß.de") == "xn--fa-hia.de"
      assert Punycode.host_to_ascii("☃.com") == "xn--n3h.com"
      assert Punycode.host_to_ascii("ab\u00AD.com") == "ab.com"
      assert Punycode.host_to_ascii("l·l.com") == "xn--ll-0ea.com"
      assert Punycode.host_to_ascii("bücher..example") == "bücher..example"

      assert Punycode.valid_host?("☃.com")
      assert Punycode.valid_host?("l·l.com")
      refute Punycode.valid_host?("xn--")
      refute Punycode.valid_host?("xn--0")
      refute Punycode.valid_host?("xn--mañana.com")
      refute Punycode.valid_host?("foo bar")
      refute Punycode.valid_host?("́a.com")
      refute Punycode.valid_host?("a\u200Cb.com")
      refute Punycode.valid_host?("a\u200Db.com")
      refute Punycode.valid_host?("a\u00A0b.com")
      refute Punycode.valid_host?("a·b.com")
      refute Punycode.valid_host?("abcא.com")
      refute Punycode.valid_host?("�.com")
      refute Punycode.valid_host?("bücher..example")
    end)
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

  defp without_node_and_fixtures(fun) do
    with_temp_cwd(fn _tmp_dir ->
      :persistent_term.erase(@idna_cache_key)
      without_node(fun)
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
      Path.join(System.tmp_dir!(), "web-url-punycode-#{System.unique_integer([:positive])}")

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

  defp stop_idna_node do
    case Process.whereis(Idna) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 1_000)
    end
  catch
    :exit, _reason -> :ok
  end
end
