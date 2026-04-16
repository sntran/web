defmodule Web.URL.IPTest do
  use ExUnit.Case, async: false

  alias Web.URL.IP

  setup do
    on_exit(fn ->
      stop_host_cache_owner()
    end)

    :ok
  end

  test "ip helpers cover invalid bracketed and non-ipv6 colon hosts" do
    assert IP.split_host_and_port("[::1") == {"[::1", ""}
    assert IP.split_host_and_port("[bad]:80") == {"[bad]:80", ""}

    refute IP.valid_host?("[bad]", "http:")
    assert IP.valid_host?(".", "file:")
    assert IP.valid_host?("..", "file:")
    assert IP.normalize_host(".", "file:") == ""
    assert IP.normalize_host("..", "file:") == ""
    assert IP.normalize_host("AB:CD:ZZ", "custom:") == "ab:cd:zz"
    assert IP.normalize_host("9999999999999", "http:") == "9999999999999"
  end

  test "ip host cache tolerates concurrent table creation" do
    stop_host_cache_owner()

    parent = self()

    tasks =
      for _ <- 1..64 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> IP.normalize_host("example.com", "http:")
          end
        end)
      end

    Enum.each(1..64, fn _ ->
      assert_receive {:ready, _pid}, 1_000
    end)

    Enum.each(tasks, fn task ->
      send(task.pid, :go)
    end)

    assert Enum.all?(Enum.map(tasks, &Task.await(&1, 10_000)), &(&1 == "example.com"))
  after
    stop_host_cache_owner()
  end

  defp stop_host_cache_owner do
    case Process.whereis(:web_url_host_cache_owner) do
      nil -> :ok
      pid -> Process.exit(pid, :kill)
    end
  end
end
