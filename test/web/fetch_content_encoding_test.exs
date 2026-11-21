defmodule Web.FetchContentEncodingTest do
  # `fetch` decodes the content codings of a response body, as the Fetch
  # Standard specifies. The server is Bandit. A test measures the memory of
  # the VM, thus the tests do not run at the same time as other tests.
  use ExUnit.Case, async: false
  use ExUnitProperties
  use Web

  import Bitwise

  alias Web.Internal.Brotli.Encoder, as: Brotli
  alias Web.Internal.ContentDecoder
  alias Web.TestBrotliWriter, as: B

  @table __MODULE__

  defmodule Server do
    @moduledoc false
    use Plug.Builder

    plug(:respond)

    # Gives the headers of the request.
    def respond(%{request_path: "/headers"} = conn, _options) do
      send_resp(conn, 200, JSON.encode!(Map.new(conn.req_headers)))
    end

    # Gives a response that the test stored in the table: its status, its
    # headers, and its chunks. A chunk can be `{:sleep, ms}`.
    def respond(%{request_path: "/body/" <> id} = conn, _options) do
      [{_id, response}] = :ets.lookup(Web.FetchContentEncodingTest, id)
      conn = Enum.reduce(response.headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)

      case response.chunks do
        {:full, body} ->
          send_resp(conn, response.status, body)

        chunks ->
          conn = send_chunked(conn, response.status)

          Enum.reduce(chunks, conn, fn
            # The pause is a part of the scenario: a slow server.
            {:sleep, ms}, conn ->
              Process.sleep(ms)
              conn

            chunk, conn ->
              {:ok, conn} = chunk(conn, chunk)
              conn
          end)
      end
    end
  end

  setup_all do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, server} = Bandit.start_link(plug: Server, scheme: :http, port: 0, startup_log: false)
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    %{base: "http://localhost:#{port}"}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp encode("gzip", data), do: :zlib.gzip(data)
  defp encode("x-gzip", data), do: :zlib.gzip(data)
  defp encode("deflate", data), do: :zlib.compress(data)
  defp encode("raw deflate", data), do: :zlib.zip(data)
  defp encode("br", data), do: brotli(data)
  defp encode("zstd", data), do: Web.TestZstd.compress(data)
  defp encode("deflate, gzip", data), do: data |> :zlib.compress() |> :zlib.gzip()
  defp encode("gzip, br", data), do: data |> :zlib.gzip() |> brotli()

  defp brotli(data) do
    {first, encoder} = Brotli.push(Brotli.new(), data)
    first <> Brotli.finish(encoder)
  end

  # A brotli stream of `count` meta-blocks of 16 MiB of zeros. The first
  # command inserts a zero and copies at the distance 1, and the others copy
  # at the last distance.
  defp brotli_zeros(count) do
    size = 1 <<< 24
    {literal, _literals} = B.simple([0], 256)
    {command, commands} = B.simple([399, 391], 704)
    {distance, distances} = B.simple([16, 0], 64)

    blocks =
      for block <- 1..count do
        first? = block == 1

        [
          B.header(block == count, size),
          B.one_of_each(literal, command, distance),
          if(first?,
            do: [B.symbol(commands, 399), {size - 1 - 2118, 24}, B.symbol(distances, 16), {0, 1}],
            else: [B.symbol(commands, 391), {size - 2118, 24}, B.symbol(distances, 0)]
          )
        ]
      end

    B.bytes([B.window(16), blocks])
  end

  defp header("raw deflate"), do: "deflate"
  defp header(coding), do: coding

  # Stores a response, and returns its URL.
  defp serve(base, response) do
    id = Integer.to_string(System.unique_integer([:positive]))
    response = Map.merge(%{status: 200, headers: []}, response)
    :ets.insert(@table, {id, response})
    base <> "/body/" <> id
  end

  defp encoded_url(base, coding, data, chunks \\ nil) do
    encoded = encode(coding, data)

    serve(base, %{
      headers: [{"content-encoding", header(coding)}],
      chunks: chunks || {:full, encoded}
    })
  end

  defp text(url, init \\ []), do: await(Response.text(await(fetch(url, init))))

  defp split(binary, sizes) do
    {chunks, rest} =
      Enum.reduce(sizes, {[], binary}, fn size, {chunks, rest} ->
        size = min(size, byte_size(rest))
        <<chunk::binary-size(^size), rest::binary>> = rest
        {[chunk | chunks], rest}
      end)

    Enum.reverse([rest | chunks])
  end

  # ---------------------------------------------------------------------------
  # Decoding
  # ---------------------------------------------------------------------------

  describe "a response with a content coding" do
    test "has the decoded body, and its headers with no change", %{base: base} do
      data = :crypto.strong_rand_bytes(10_000) <> :binary.copy("text ", 10_000)

      for coding <- [
            "gzip",
            "x-gzip",
            "deflate",
            "raw deflate",
            "br",
            "zstd",
            "deflate, gzip",
            "gzip, br"
          ] do
        encoded = encode(coding, data)
        response = await(fetch(encoded_url(base, coding, data)))

        assert Headers.get(response.headers, "content-encoding") == header(coding)
        assert Headers.get(response.headers, "content-length") == "#{byte_size(encoded)}"
        assert await(Response.array_buffer(response)) |> ArrayBuffer.data() == data, coding
      end
    end

    test "with a coding that the library does not know has the body with no change", %{
      base: base
    } do
      url =
        serve(base, %{headers: [{"content-encoding", "compress"}], chunks: {:full, "raw bytes"}})

      assert text(url) == "raw bytes"
    end

    test "arrives in chunks that end at each place", %{base: base} do
      data = "a body in small chunks " <> :binary.copy("z", 500)
      encoded = encode("gzip", data)

      for position <- [1, 2, 9, 10, div(byte_size(encoded), 2), byte_size(encoded) - 1] do
        <<first::binary-size(^position), second::binary>> = encoded
        url = encoded_url(base, "gzip", data, [first, {:sleep, 5}, second])
        assert text(url) == data
      end
    end

    test "that is not valid gives a TypeError to the reader", %{base: base} do
      url = serve(base, %{headers: [{"content-encoding", "gzip"}], chunks: {:full, "not gzip"}})

      assert %TypeError{message: "The response body cannot be decoded.", cause: cause} =
               catch_exit(text(url))

      assert %ContentDecoder.Error{message: "The gzip data is not valid."} = cause
    end

    test "that is cut gives a TypeError to the reader", %{base: base} do
      encoded = encode("zstd", :crypto.strong_rand_bytes(4_000))
      cut = binary_part(encoded, 0, byte_size(encoded) - 4)
      url = serve(base, %{headers: [{"content-encoding", "zstd"}], chunks: {:full, cut}})

      assert %TypeError{message: "The response body cannot be decoded.", cause: cause} =
               catch_exit(text(url))

      assert cause.message == "The zstd data is not complete."
    end

    test "with the coding br that is not valid or is cut gives a TypeError", %{base: base} do
      url = serve(base, %{headers: [{"content-encoding", "br"}], chunks: {:full, <<0x11>>}})
      assert %TypeError{cause: cause} = catch_exit(text(url))
      assert cause.message == "The br data is not valid."

      encoded = encode("br", :crypto.strong_rand_bytes(4_000))
      cut = binary_part(encoded, 0, byte_size(encoded) - 4)
      url = serve(base, %{headers: [{"content-encoding", "br"}], chunks: {:full, cut}})
      assert %TypeError{cause: cause} = catch_exit(text(url))
      assert cause.message == "The br data is not complete."
    end

    test "with no body is not decoded", %{base: base} do
      url = encoded_url(base, "gzip", "data")
      assert %Response{status: 200, body: nil} = await(fetch(url, method: "HEAD"))

      url = serve(base, %{status: 204, headers: [{"content-encoding", "gzip"}], chunks: []})
      assert %Response{status: 204, body: nil} = await(fetch(url))
    end

    test "of a large body is read with flat memory", %{base: base} do
      # 256 MiB of zeros are 260 KB with gzip.
      encoded = encode("gzip", :binary.copy(<<0>>, 256 * 1_048_576))

      url =
        serve(base, %{
          headers: [{"content-encoding", "gzip"}],
          chunks: split(encoded, List.duplicate(16_384, 16))
        })

      :erlang.garbage_collect()
      start = :erlang.memory(:binary)

      {bytes, peak} =
        Enum.reduce(await(fetch(url)).body, {0, 0}, fn chunk, {bytes, peak} ->
          {bytes + chunk.byte_length, max(peak, :erlang.memory(:binary))}
        end)

      assert bytes == 256 * 1_048_576
      assert peak - start < 64 * 1_048_576
    end

    test "of a large body with the coding br is read with flat memory", %{base: base} do
      # 256 MiB of zeros in 16 meta-blocks of 16 MiB: each meta-block has one
      # copy at the distance 1.
      url =
        serve(base, %{
          headers: [{"content-encoding", "br"}],
          chunks: {:full, brotli_zeros(16)}
        })

      :erlang.garbage_collect()
      start = :erlang.memory(:binary)

      {bytes, peak} =
        Enum.reduce(await(fetch(url)).body, {0, 0}, fn chunk, {bytes, peak} ->
          {bytes + chunk.byte_length, max(peak, :erlang.memory(:binary))}
        end)

      assert bytes == 256 * 1_048_576
      assert peak - start < 64 * 1_048_576
    end
  end

  # ---------------------------------------------------------------------------
  # The request header
  # ---------------------------------------------------------------------------

  describe "the header accept-encoding of the request" do
    defp request_header(base, init) do
      await(Response.json(await(fetch(base <> "/headers", init))))["accept-encoding"]
    end

    test "has the codings that the library decodes", %{base: base} do
      assert request_header(base, []) == "gzip, deflate, br, zstd"
    end

    test "keeps the value of the caller", %{base: base} do
      assert request_header(base, headers: %{"accept-encoding" => "identity"}) == "identity"
    end

    test "is identity for a request of a range", %{base: base} do
      assert request_header(base, headers: %{"range" => "bytes=0-10"}) == "identity"
    end
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "a compressed body in chunks of each size gives the input", %{base: base} do
    check all(
            data <- binary(max_length: 50_000),
            coding <- member_of(["gzip", "deflate", "raw deflate", "br", "zstd", "deflate, gzip"]),
            sizes <- list_of(integer(1..8_192), max_length: 12),
            max_runs: 50
          ) do
      chunks = encode(coding, data) |> split(sizes) |> Enum.reject(&(&1 == ""))
      url = encoded_url(base, coding, data, chunks)

      assert await(Response.array_buffer(await(fetch(url)))) |> ArrayBuffer.data() == data
    end
  end
end
