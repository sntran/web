defmodule Web.Internal.ContentDecoderBrotliTest do
  # The setting `:brotli` of the application. A setting is global, thus
  # the tests do not run at the same time as other tests.
  use ExUnit.Case, async: false
  use ExUnitProperties
  use Web

  alias Web.Internal.Brotli.Encoder, as: Brotli
  alias Web.Internal.ContentDecoder, as: Decoder
  alias Web.Internal.ContentDecoder.Error
  alias Web.TestFakeBrotliNif, as: FakeNif

  setup context do
    previous = Application.fetch_env(:web, :brotli)

    if setting = context[:brotli] do
      Application.put_env(:web, :brotli, setting)
    end

    # The module of the Hex package: see `Web.TestFakeBrotliNif`.
    if context[:fake] != false, do: FakeNif.install()

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:web, :brotli, value)
        :error -> Application.delete_env(:web, :brotli)
      end

      FakeNif.remove()
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp brotli(data) do
    {first, encoder} = Brotli.push(Brotli.new(), data)
    first <> Brotli.finish(encoder)
  end

  defp br, do: Decoder.new([{"content-encoding", "br"}])

  defp decode(stages, chunks), do: stages |> pieces(chunks) |> IO.iodata_to_binary()

  defp pieces(stages, chunks) do
    {pieces, stages} =
      Enum.reduce(chunks, {[], stages}, fn chunk, {pieces, stages} ->
        {:more, pieces, stages} = drain(Decoder.push(stages, chunk), pieces)
        {pieces, stages}
      end)

    {:done, pieces, _stages} = drain(Decoder.finish(stages), pieces)
    Enum.reverse(pieces)
  end

  defp drain(stages, pieces) do
    case Decoder.pull(stages) do
      {:piece, piece, stages} -> drain(stages, [piece | pieces])
      {status, stages} -> {status, pieces, stages}
    end
  end

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
  # The settings
  # ---------------------------------------------------------------------------

  describe "the setting :brotli" do
    test "is :elixir when it is not set: the decoder in Elixir, and a request accepts br" do
      Application.delete_env(:web, :brotli)
      assert [%{kind: :brotli}] = br()
      assert [%{kind: :brotli}] = Decoder.format("brotli")
      assert Decoder.accept_encoding() == "gzip, deflate, br, zstd"
    end

    @tag brotli: :elixir
    test ":elixir uses the decoder in Elixir, also when the Hex package is there" do
      assert [%{kind: :brotli}] = br()
      assert Decoder.accept_encoding() == "gzip, deflate, br, zstd"
      assert decode(br(), [brotli("data")]) == "data"
      assert FakeNif.created() == 0
    end

    @tag brotli: :native
    test ":native uses the decoder of the Hex package brotli, and a request accepts br" do
      assert [%{kind: :native_brotli}] = br()
      assert [%{kind: :native_brotli}] = Decoder.format("brotli")
      assert Decoder.accept_encoding() == "gzip, deflate, br, zstd"
      assert decode(br(), [brotli("data")]) == "data"
      assert FakeNif.created() == 3
    end

    @tag brotli: :not_requested
    test ":not_requested removes br from the request, and decodes br in Elixir" do
      assert Decoder.accept_encoding() == "gzip, deflate, zstd"
      assert [%{kind: :brotli}] = br()
      assert [%{kind: :brotli}] = Decoder.format("brotli")
      assert decode(br(), [brotli("data")]) == "data"
      assert FakeNif.created() == 0
    end

    @tag brotli: :native, fake: false
    test ":native with no Hex package brotli raises" do
      message = ~r/needs the Hex package brotli/
      assert_raise ArgumentError, message, fn -> Decoder.accept_encoding() end
      assert_raise ArgumentError, message, fn -> br() end
    end

    @tag brotli: :zstd
    test "a value that is not known raises" do
      message = ~r/must be :elixir, :native, or :not_requested, got: :zstd/
      assert_raise ArgumentError, message, fn -> Decoder.accept_encoding() end
      assert_raise ArgumentError, message, fn -> Decoder.format("brotli") end
    end
  end

  # ---------------------------------------------------------------------------
  # The decoder of the Hex package
  # ---------------------------------------------------------------------------

  describe "the native decoder" do
    @describetag brotli: :native

    # A pull gives approximately 64 KiB: see `Web.Internal.ContentDecoder`.
    test "gives the data in pieces" do
      data = :crypto.strong_rand_bytes(20_000) <> :binary.copy("hello ", 50_000)
      pieces = pieces(br(), [brotli(data)])
      assert IO.iodata_to_binary(pieces) == data
      assert length(pieces) > 1
      assert Enum.all?(pieces, &(byte_size(&1) < 200_000))
    end

    test "accepts one byte at a time, and an empty body" do
      data = :binary.copy("one byte at a time ", 200)
      encoded = brotli(data)
      assert decode(br(), split(encoded, List.duplicate(1, byte_size(encoded)))) == data
      assert decode(br(), []) == ""
    end

    test "gives the end again after the end" do
      for stages <- [br(), Decoder.format("brotli")] do
        stages = stages |> Decoder.push(brotli("data")) |> Decoder.finish()
        assert {:piece, "data", stages} = Decoder.pull(stages)
        assert {:done, stages} = Decoder.pull(stages)
        assert {:done, _stages} = Decoder.pull(stages)
      end

      assert {:done, stages} = Decoder.pull(Decoder.finish(br()))
      assert {:done, _stages} = Decoder.pull(stages)
    end

    test "drops the data after the end of an HTTP body" do
      assert decode(br(), [brotli("data") <> "x", "more data"]) == "data"
      assert decode(br(), [brotli("data"), "x"]) == "data"
    end

    test "refuses data that is not valid, or not complete" do
      assert_raise Error, "The br data is not valid.", fn -> decode(br(), [<<0x11, 0, 0>>]) end
      encoded = brotli(:crypto.strong_rand_bytes(5_000))
      cut = binary_part(encoded, 0, byte_size(encoded) - 3)
      assert_raise Error, "The br data is not complete.", fn -> decode(br(), [cut]) end
    end

    test "the format brotli needs data, and refuses data after the end" do
      assert_raise Error, "The brotli data is not complete.", fn ->
        decode(Decoder.format("brotli"), [])
      end

      encoded = brotli("data")

      for chunks <- [[encoded <> "x"], [encoded, "x"], [encoded <> "xy"]] do
        assert_raise Error, "The brotli data is not valid.", fn ->
          decode(Decoder.format("brotli"), chunks)
        end
      end

      assert decode(Decoder.format("brotli"), split(encoded, [1, 2, 3])) == "data"
    end

    test "a pull gives the output before the error for data after the end" do
      stages = Decoder.push(Decoder.format("brotli"), brotli("data") <> "x")
      assert {:piece, "data", failed} = Decoder.pull(stages)
      assert_raise Error, ~r/is not valid/, fn -> Decoder.pull(failed) end
      assert Decoder.close(failed) == :ok
    end

    property "gives the input for each split of the data" do
      check all(
              parts <-
                list_of(
                  one_of([
                    binary(max_length: 3_000),
                    map(integer(1..200_000), &:binary.copy(<<0>>, &1))
                  ]),
                  max_length: 5
                ),
              strict? <- boolean(),
              sizes <- list_of(integer(1..8_192), max_length: 20),
              max_runs: 100
            ) do
        data = IO.iodata_to_binary(parts)
        stages = if strict?, do: Decoder.format("brotli"), else: br()
        pieces = pieces(stages, split(brotli(data), sizes))
        assert IO.iodata_to_binary(pieces) == data
        assert Enum.all?(pieces, &(byte_size(&1) < 200_000))

        # A piece does not keep the larger output of the C library.
        assert Enum.all?(pieces, &(:binary.referenced_byte_size(&1) == byte_size(&1)))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The streams of the Compression Standard
  # ---------------------------------------------------------------------------

  @tag brotli: :native
  test "DecompressionStream uses the native decoder" do
    data = :binary.copy("decompress with the native decoder ", 1_000)
    encoded = brotli(data)

    output =
      split(encoded, [100, 1, 5_000])
      |> ReadableStream.from()
      |> ReadableStream.pipe_through(DecompressionStream.new("brotli"))
      |> Web.TestBytes.binaries()

    assert IO.iodata_to_binary(output) == data
    assert FakeNif.created() == 1
  end
end
