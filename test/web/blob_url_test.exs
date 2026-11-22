defmodule Web.BlobURLTest do
  # The blob URLs of the File API, and their fetch.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Blob
  alias Web.Internal.BlobURLStore
  alias Web.URL

  @uuid ~r/^blob:null\/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  defp fetch(url, init \\ []), do: Web.Promise.wait(Web.fetch(url, init))

  defp text(response), do: Web.await(Web.Response.text(response))

  test "create_object_url/1 gives a unique blob URL with a UUID of version 4" do
    blob = Blob.new(["a"])
    urls = for _ <- 1..200, do: URL.create_object_url(blob)

    assert Enum.all?(urls, &Regex.match?(@uuid, &1))
    assert length(Enum.uniq(urls)) == 200
    assert URL.origin(URL.new(hd(urls))) == "null"

    assert_raise Web.TypeError, fn -> URL.create_object_url("text") end
  end

  test "a fetch of a blob URL gives the bytes, the size, and the type of the blob" do
    blob = Blob.new(["hello"], type: "text/plain")
    url = URL.create_object_url(blob)

    for target <- [url, url <> "#fragment", Web.Request.new(url)] do
      assert {:fulfilled, response} = fetch(target)
      assert {response.status, response.status_text, response.url} == {200, "OK", url}
      assert Web.Headers.get(response.headers, "content-length") == "5"
      assert Web.Headers.get(response.headers, "content-type") == "text/plain"
      assert text(response) == "hello"
    end

    file = Web.File.new(["bits"], "a.txt")
    assert {:fulfilled, response} = fetch(URL.create_object_url(file))
    assert Web.Headers.get(response.headers, "content-type") == ""
    assert text(response) == "bits"
  end

  test "a fetch of a URL that is not in the store, or with a method other than GET, fails" do
    url = URL.create_object_url(Blob.new(["a"]))

    for {target, init} <- [
          {url <> "?query", []},
          {url <> "/path", []},
          {"blob:null/00000000-0000-4000-8000-000000000000", []},
          {url, [method: "POST"]},
          {url, [method: "HEAD"]}
        ] do
      assert {:rejected, %Web.TypeError{}} = fetch(target, init)
    end
  end

  test "revoke_object_url/1 revokes only the exact URL" do
    url = URL.create_object_url(Blob.new(["a"]))

    assert URL.revoke_object_url(url <> "#fragment") == :ok
    assert URL.revoke_object_url("https://example.com/") == :ok
    assert URL.revoke_object_url("not a URL") == :ok
    assert URL.revoke_object_url("blob:null/unknown") == :ok
    assert {:fulfilled, _response} = fetch(url)

    # A fetch reads the store when it starts: a revoke after it has no
    # effect on it.
    promise = Web.fetch(url)
    assert URL.revoke_object_url(url) == :ok
    assert {:fulfilled, response} = Web.Promise.wait(promise)
    assert text(response) == "a"

    assert {:rejected, %Web.TypeError{}} = fetch(url)
  end

  test "the dispatcher gives the response with fetch/1 of Web.Dispatcher" do
    url = URL.create_object_url(Blob.new(["abc"]))

    assert {:ok, %Web.Response{status: 200}} =
             Web.Dispatcher.Blob.fetch(Web.Request.new(url))

    assert {:error, :blob_url_method_not_get} =
             Web.Dispatcher.Blob.fetch(Web.Request.new(url, method: "PUT"))

    request = %{Web.Request.new(url) | dispatcher: Web.Dispatcher.Blob}
    assert {:fulfilled, %Web.Response{}} = fetch(request)

    assert {:error, :blob_url_not_found} =
             Web.Dispatcher.Blob.fetch(Web.Request.new("https://example.com/"))
  end

  describe "the lifetime of a blob URL" do
    # The store does the requests one at a time. The test suspends it, and
    # puts the add of a process and the stop of that process in its mailbox
    # in a known sequence.
    test "a process that stops while its add waits gets no URL" do
      store = Process.whereis(BlobURLStore)
      test = self()

      # The process has a URL: the store monitors it.
      {maker, monitor} =
        spawn_monitor(fn ->
          send(test, {:first, URL.create_object_url(Blob.new(["a"]))})
          send(test, {:second_url, "blob:null/" <> Base.encode16(:crypto.strong_rand_bytes(4))})

          receive do
            {:add, url} -> BlobURLStore.add(url, Blob.new(["b"]))
          end
        end)

      assert_receive {:first, first}
      assert_receive {:second_url, second}

      true = :erlang.suspend_process(store)

      try do
        send(maker, {:add, second})
        await_add(store, maker)
        Process.exit(maker, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^maker, :killed}
      after
        :erlang.resume_process(store)
      end

      # The store did the add: the call of the test comes after it.
      _state = :sys.get_state(store)

      eventually(fn ->
        BlobURLStore.resolve(first) == nil and
          BlobURLStore.resolve(second) == nil
      end)
    end

    test "a process with no URL that stops while its add waits gets no URL" do
      store = Process.whereis(BlobURLStore)
      url = "blob:null/" <> Base.encode16(:crypto.strong_rand_bytes(4))
      true = :erlang.suspend_process(store)

      try do
        {maker, monitor} =
          spawn_monitor(fn -> BlobURLStore.add(url, Blob.new(["a"])) end)

        await_add(store, maker)
        Process.exit(maker, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^maker, :killed}
      after
        :erlang.resume_process(store)
      end

      # The store did the add: the call of the test comes after it.
      _state = :sys.get_state(store)

      eventually(fn -> BlobURLStore.resolve(url) == nil end)
    end
  end

  # Waits until the mailbox of the store has the add of the process. Other
  # tests can use the store at the same time.
  defp await_add(store, maker, attempts \\ 200) do
    {:messages, messages} = Process.info(store, :messages)

    cond do
      Enum.any?(
        messages,
        &match?({:"$gen_call", {^maker, _tag}, {:add, _url, _blob, _owner}}, &1)
      ) ->
        :ok

      attempts == 0 ->
        flunk("the mailbox of the store does not have the add")

      true ->
        Process.sleep(5) && await_add(store, maker, attempts - 1)
    end
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end

  describe "a request with a Range header" do
    setup do
      %{url: URL.create_object_url(Blob.new(["0123456789"], type: "text/plain"))}
    end

    defp range(url, value) do
      case fetch(url, headers: [{"range", value}]) do
        {:fulfilled, response} ->
          {response.status, response.status_text,
           Web.Headers.get(response.headers, "content-range"),
           Web.Headers.get(response.headers, "content-length"),
           Web.Headers.get(response.headers, "content-type"), text(response)}

        {:rejected, %Web.TypeError{}} ->
          :network_error
      end
    end

    test "gives the status 206 and the bytes of one range", %{url: url} do
      assert range(url, "bytes=2-4") ==
               {206, "Partial Content", "bytes 2-4/10", "3", "text/plain", "234"}

      assert range(url, "bytes = 7 -") ==
               {206, "Partial Content", "bytes 7-9/10", "3", "text/plain", "789"}

      assert range(url, "bytes=-3") ==
               {206, "Partial Content", "bytes 7-9/10", "3", "text/plain", "789"}

      assert range(url, "bytes=8-100") ==
               {206, "Partial Content", "bytes 8-9/10", "2", "text/plain", "89"}
    end

    test "gives a network error for a range that is not valid", %{url: url} do
      for value <-
            ["bytes=10-", "bytes=4-2", "bytes=-", "bytes=a-b", "bits=0-1", "bytes0-1"] ++
              ["bytes=0-1,3-4", "bytes=+1-2", "bytes=1-+2"] do
        assert range(url, value) == :network_error, value
      end
    end

    property "the bytes of a range are the bytes of the slice of the range" do
      check all(first <- integer(0..9), length <- integer(1..12)) do
        url = URL.create_object_url(Blob.new(["0123456789"]))
        last = first + length - 1
        expected = binary_part("0123456789", first, min(length, 10 - first))

        assert {206, _, _, _, _, ^expected} = range(url, "bytes=#{first}-#{last}")
      end
    end
  end
end
