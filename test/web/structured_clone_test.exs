defmodule Web.StructuredCloneTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  use Web.Platform.Test,
    urls: [
      "https://raw.githubusercontent.com/web-platform-tests/wpt/master/html/webappapis/structured-clone/structured-clone-battery-of-tests.js",
      "https://raw.githubusercontent.com/web-platform-tests/wpt/master/html/webappapis/structured-clone/structured-clone-battery-of-tests-with-transferables.js"
    ],
    prefix: "structuredClone WPT subset"

  alias Web.ArrayBuffer
  alias Web.Blob
  alias Web.DOMException
  alias Web.File
  alias Web.Headers
  alias Web.Internal.Reference
  alias Web.Internal.StructuredData
  alias Web.MessageChannel
  alias Web.MessagePort
  alias Web.TypeError
  alias Web.Uint8Array
  alias Web.URLSearchParams

  defmodule UsingWeb do
    use Web

    def clone(value, opts \\ []) do
      structured_clone(value, opts)
    end
  end

  @impl Web.Platform.Test
  def web_platform_test(%{"kind" => "primitive", "value" => {:js_special_number, _kind}}), do: :ok

  def web_platform_test(%{"kind" => "primitive", "value" => value}) do
    clone = Web.structured_clone(value)
    assert :erlang.term_to_binary(clone) == :erlang.term_to_binary(value)
  end

  def web_platform_test(%{"kind" => "date_time", "unix_ms" => unix_ms}) do
    case DateTime.from_unix(trunc(unix_ms / 1000)) do
      {:ok, date_time} -> assert Web.structured_clone(date_time) == date_time
      {:error, _reason} -> :ok
    end
  end

  def web_platform_test(%{"kind" => "blob", "parts" => parts, "type" => type}) do
    input = Blob.new(parts, type: type)
    clone = Web.structured_clone(input)

    assert Blob.to_binary(clone) == Blob.to_binary(input)
    assert clone.type == input.type
  end

  def web_platform_test(%{"kind" => "shared_reference_array"}) do
    shared = %{"value" => 1}
    serialized = StructuredData.serialize([shared, shared])

    assert %{type: :list, items: [shared_id, shared_id]} =
             Map.fetch!(serialized.nodes, serialized.root)

    assert [first, second] = Web.structured_clone([shared, shared])
    assert first == second
  end

  def web_platform_test(%{"kind" => "shared_reference_object"}) do
    shared = %{"value" => 1}
    serialized = StructuredData.serialize(%{"x" => shared, "y" => shared})

    value_ids =
      serialized.nodes
      |> Map.fetch!(serialized.root)
      |> Map.fetch!(:entries)
      |> Enum.map(fn {_key_id, value_id} -> value_id end)
      |> Enum.uniq()

    assert value_ids == [Enum.at(value_ids, 0)]
    assert %{"x" => first, "y" => second} = Web.structured_clone(%{"x" => shared, "y" => shared})
    assert first == second
  end

  def web_platform_test(%{"kind" => "data_clone_error"}) do
    assert_raise DOMException, fn ->
      Web.structured_clone(Web.Response.new())
    end
  end

  def web_platform_test(%{"kind" => "transfer_array_buffer", "bytes" => bytes}) do
    buffer = ArrayBuffer.new(IO.iodata_to_binary(bytes))
    clone = Web.structured_clone(buffer, transfer: [buffer])

    assert ArrayBuffer.data(clone) == IO.iodata_to_binary(bytes)
    assert ArrayBuffer.byte_length(clone) == length(bytes)
    assert ArrayBuffer.byte_length(buffer) == 0
  end

  def web_platform_test(%{"kind" => "transfer_blob_error"}) do
    assert_raise DOMException, fn ->
      Web.structured_clone(Blob.new(["payload"]), transfer: [Blob.new(["payload"])])
    end
  end

  def web_platform_test(_test_case), do: :ok

  test "clones supported primitives and collections" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    regex = ~r/foo/im
    buffer = ArrayBuffer.new("hello")
    blob = Blob.new(["hello"], type: "text/plain")
    file = File.new([blob], name: "upload", filename: "hello.txt", type: "text/plain")
    headers = Headers.new([{"x-test", "1"}, {"x-test", "2"}])
    params = URLSearchParams.new([{"a", "1"}, {"a", "2"}])
    bytes = Uint8Array.new(buffer, 1, 3)

    value = %{
      "list" => [1, 2, 3],
      "map" => %{"ok" => true},
      "set" => MapSet.new([1, 2]),
      "date" => now,
      "regex" => regex,
      "blob" => blob,
      "file" => file,
      "headers" => headers,
      "params" => params,
      "buffer" => buffer,
      "bytes" => bytes
    }

    clone = Web.structured_clone(value)

    assert clone["list"] == [1, 2, 3]
    assert clone["map"] == %{"ok" => true}
    assert clone["set"] == MapSet.new([1, 2])
    assert clone["date"] == now
    assert Regex.source(clone["regex"]) == Regex.source(regex)
    assert Regex.opts(clone["regex"]) == Regex.opts(regex)
    assert Blob.to_binary(clone["blob"]) == Blob.to_binary(blob)
    assert clone["blob"].type == blob.type
    assert clone["file"].name == file.name
    assert clone["file"].filename == file.filename
    assert clone["file"].type == file.type
    assert clone["file"].size == file.size

    assert Blob.to_binary(Blob.new(clone["file"].parts, type: clone["file"].type)) ==
             Blob.to_binary(Blob.new(file.parts, type: file.type))

    assert Headers.to_list(clone["headers"]) == [{"x-test", "1"}, {"x-test", "2"}]
    assert URLSearchParams.to_list(clone["params"]) == [{"a", "1"}, {"a", "2"}]
    assert ArrayBuffer.data(clone["buffer"]) == ArrayBuffer.data(buffer)
    assert ArrayBuffer.byte_length(clone["buffer"]) == ArrayBuffer.byte_length(buffer)
    assert Uint8Array.to_binary(clone["bytes"]) == "ell"
  end

  test "preserves duplicated references across the cloned graph" do
    shared = %{"value" => 1}
    serialized = StructuredData.serialize([shared, shared])
    clone = Web.structured_clone([shared, shared])
    root = Map.fetch!(serialized.nodes, serialized.root)

    assert Enum.at(clone, 0) == Enum.at(clone, 1)
    assert %{type: :list, items: [shared_id, shared_id]} = root
    refute :erts_debug.same(Enum.at(clone, 0), shared)
  end

  test "supports ArrayBuffer transfer validation" do
    buffer = ArrayBuffer.new("hello")
    clone = Web.structured_clone(%{"buffer" => buffer}, transfer: [buffer])

    assert ArrayBuffer.data(clone["buffer"]) == "hello"
    assert ArrayBuffer.byte_length(clone["buffer"]) == 5
    assert ArrayBuffer.byte_length(buffer) == 0
  end

  test "rejects detached ArrayBuffers in transfer lists" do
    buffer = ArrayBuffer.new("hello")
    ArrayBuffer.detach(buffer)

    assert_raise Web.TypeError, fn ->
      Web.structured_clone(%{"buffer" => buffer}, transfer: [buffer])
    end
  end

  test "rejects cloning detached ArrayBuffers directly" do
    buffer = ArrayBuffer.new("hello")
    ArrayBuffer.detach(buffer)

    assert_raise Web.TypeError, fn ->
      Web.structured_clone(buffer)
    end
  end

  test "supports legacy ArrayBuffer transfer key fallback without identities" do
    buffer = %ArrayBuffer{id: nil, data: "legacy", byte_length: 6}
    serialized = StructuredData.serialize(buffer, transfer: [buffer])

    assert %{type: :array_buffer, data: "legacy", transferred: true} =
             Map.fetch!(serialized.nodes, serialized.root)

    clone = StructuredData.deserialize(serialized)

    assert ArrayBuffer.data(clone) == "legacy"
    assert ArrayBuffer.byte_length(clone) == 6
  end

  test "rejects duplicate transfer entries" do
    buffer = ArrayBuffer.new("hello")

    assert_raise DOMException, fn ->
      Web.structured_clone(buffer, transfer: [buffer, buffer])
    end
  end

  test "rejects non-transferable values in transfer lists" do
    blob = Blob.new(["hello"], type: "text/plain")

    assert_raise DOMException, fn ->
      Web.structured_clone(blob, transfer: [blob])
    end
  end

  test "raises DataCloneError for unsupported values" do
    assert_raise DOMException, fn ->
      Web.structured_clone(self())
    end

    assert_raise DOMException, fn ->
      Web.structured_clone(fn -> :ok end)
    end

    port = Port.open({:spawn, "cat"}, [:binary])

    try do
      assert_raise DOMException, fn ->
        Web.structured_clone(port)
      end
    after
      Port.close(port)
    end
  end

  test "use Web imports structured_clone/1 and structured_clone/2" do
    assert UsingWeb.clone(%{"ok" => true}) == %{"ok" => true}

    buffer = ArrayBuffer.new("hi")
    clone = UsingWeb.clone(buffer, transfer: [buffer])

    assert ArrayBuffer.data(clone) == "hi"
    assert ArrayBuffer.byte_length(buffer) == 0
  end

  test "DOMException.exception/1 supports name shorthand" do
    exception = DOMException.exception("DataCloneError")

    assert exception.name == "DataCloneError"
    assert exception.message == "DataCloneError"
    assert exception.code == 25
  end

  test "structured_clone validates options eagerly" do
    assert_raise ArgumentError, fn ->
      Web.structured_clone(%{}, foo: :bar)
    end

    assert_raise ArgumentError, fn ->
      Web.structured_clone(%{}, transfer: :invalid)
    end

    assert_raise ArgumentError, fn ->
      Web.structured_clone(%{}, [:not_a_keyword])
    end

    assert_raise ArgumentError, fn ->
      Web.structured_clone(%{}, "invalid")
    end

    assert_raise ArgumentError, fn ->
      StructuredData.serialize(%{}, message_port_recipient: :invalid)
    end
  end

  test "MessagePort transfers require an explicit recipient pid during serialization" do
    {port1, port2} = MessageChannel.new()

    exception =
      assert_raise DOMException, fn ->
        StructuredData.serialize(%{"port" => port1}, transfer: [port1])
      end

    assert exception.name == "DataCloneError"

    assert :ok = MessagePort.close(port1)

    assert_raise DOMException, fn ->
      MessagePort.post_message(port2, "closed")
    end
  end

  test "structured_clone rejects tuples, bitstrings, and files backed by live streams" do
    assert_raise DOMException, fn ->
      Web.structured_clone({:tuple})
    end

    assert_raise DOMException, fn ->
      Web.structured_clone(<<1::size(1)>>)
    end

    file =
      File.new([],
        name: "upload",
        filename: "stream.txt",
        type: "text/plain",
        stream: Web.ReadableStream.from("payload")
      )

    assert_raise DOMException, fn ->
      Web.structured_clone(file)
    end
  end

  test "StructuredData.deserialize/1 represents circular serialized graphs with references" do
    assert [%Reference{id: 1}] =
             StructuredData.deserialize(%{root: 1, nodes: %{1 => %{type: :list, items: [1]}}})
  end

  test "preserves distinct blob identity for equal-but-distinct blobs" do
    first = Blob.new(["payload"], type: "text/plain")
    second = Blob.new(["payload"], type: "text/plain")

    serialized = StructuredData.serialize([first, second])
    root = Map.fetch!(serialized.nodes, serialized.root)
    [first_clone, second_clone] = Web.structured_clone([first, second])

    assert %{type: :list, items: [first_id, second_id]} = root
    refute first_id == second_id
    refute first_clone.id == second_clone.id
    assert Blob.to_binary(first_clone) == Blob.to_binary(second_clone)
  end

  property "supported values remain round-trip invariant across repeated clones" do
    check all(value <- cloneable_term(), max_runs: 100) do
      clone = Web.structured_clone(value)
      clone_twice = Web.structured_clone(clone)

      assert canonicalize(clone) == canonicalize(value)
      assert canonicalize(clone_twice) == canonicalize(clone)
    end
  end

  property "unsupported values shrink toward a non-serializable leaf" do
    check all(value <- invalid_term(), max_runs: 50) do
      assert_raise DOMException, fn ->
        Web.structured_clone(value)
      end
    end
  end

  property "circular serialized graphs materialize reference placeholders" do
    check all(key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 8), max_runs: 25) do
      assert [%Reference{id: 1}] =
               StructuredData.deserialize(%{root: 1, nodes: %{1 => %{type: :list, items: [1]}}})

      circular_map =
        StructuredData.deserialize(%{
          root: 1,
          nodes: %{
            1 => %{type: :map, entries: [{2, 1}]},
            2 => %{type: :primitive, value: key}
          }
        })

      assert %Reference{id: 1} = Map.fetch!(circular_map, key)
    end
  end

  property "equal-but-distinct blobs remain distinct after cloning" do
    check all(
            parts <- StreamData.list_of(StreamData.binary(max_length: 8), max_length: 3),
            type <- StreamData.string(:alphanumeric, max_length: 12),
            max_runs: 50
          ) do
      first = Blob.new(parts, type: type)
      second = Blob.new(parts, type: type)

      assert [first_clone, second_clone] = Web.structured_clone([first, second])
      refute first_clone.id == second_clone.id
      assert Blob.to_binary(first_clone) == Blob.to_binary(second_clone)
      assert first_clone.type == second_clone.type
    end
  end

  property "transferred ArrayBuffers detach the source buffer" do
    check all(data <- StreamData.binary(max_length: 16), max_runs: 50) do
      buffer = ArrayBuffer.new(data)
      clone = Web.structured_clone(buffer, transfer: [buffer])

      assert ArrayBuffer.data(clone) == data
      assert ArrayBuffer.byte_length(clone) == byte_size(data)
      assert ArrayBuffer.byte_length(buffer) == 0

      assert_raise TypeError, fn ->
        ArrayBuffer.data(buffer)
      end

      assert_raise TypeError, fn ->
        Uint8Array.new(buffer)
      end
    end
  end

  defp cloneable_term do
    StreamData.tree(cloneable_leaf(), fn inner ->
      StreamData.one_of([
        StreamData.list_of(inner, max_length: 3),
        StreamData.map_of(cloneable_key(), inner, max_length: 3),
        StreamData.map(StreamData.list_of(inner, max_length: 3), &MapSet.new/1)
      ])
    end)
  end

  defp cloneable_leaf do
    StreamData.one_of([
      StreamData.integer(),
      StreamData.float(),
      StreamData.binary(max_length: 16),
      StreamData.boolean(),
      StreamData.constant(nil),
      date_time_gen(),
      regex_gen(),
      array_buffer_gen(),
      uint8_array_gen(),
      blob_gen(),
      file_gen(),
      headers_gen(),
      url_search_params_gen()
    ])
  end

  defp cloneable_key do
    StreamData.one_of([
      StreamData.integer(),
      StreamData.binary(max_length: 12),
      StreamData.boolean(),
      StreamData.constant(nil)
    ])
  end

  defp date_time_gen do
    StreamData.map(StreamData.integer(-2_000_000_000..2_000_000_000), fn seconds ->
      DateTime.from_unix!(seconds)
    end)
  end

  defp regex_gen do
    StreamData.bind(StreamData.string(:alphanumeric, max_length: 8), fn source ->
      StreamData.map(
        StreamData.member_of([[], [:caseless], [:multiline], [:caseless, :multiline]]),
        fn opts ->
          Regex.compile!(source, opts)
        end
      )
    end)
  end

  defp array_buffer_gen do
    StreamData.map(StreamData.binary(max_length: 16), &ArrayBuffer.new/1)
  end

  defp uint8_array_gen do
    StreamData.bind(StreamData.binary(max_length: 16), fn data ->
      buffer = ArrayBuffer.new(data)
      max_length = byte_size(data)

      uint8_array_for_buffer(buffer, max_length)
    end)
  end

  defp blob_gen do
    StreamData.bind(
      StreamData.list_of(StreamData.binary(max_length: 8), max_length: 3),
      fn parts ->
        StreamData.map(StreamData.string(:alphanumeric, max_length: 12), fn type ->
          Blob.new(parts, type: type)
        end)
      end
    )
  end

  defp file_gen do
    StreamData.bind(
      StreamData.list_of(StreamData.binary(max_length: 8), max_length: 3),
      fn parts ->
        StreamData.fixed_map(%{
          name: StreamData.string(:alphanumeric, max_length: 8),
          filename: StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
          type: StreamData.string(:alphanumeric, max_length: 12)
        })
        |> StreamData.map(fn %{name: name, filename: filename, type: type} ->
          File.new(parts, name: name, filename: filename, type: type)
        end)
      end
    )
  end

  defp uint8_array_for_buffer(buffer, max_length) do
    StreamData.bind(StreamData.integer(0..max_length), fn offset ->
      StreamData.map(StreamData.integer(0..(max_length - offset)), fn length ->
        Uint8Array.new(buffer, offset, length)
      end)
    end)
  end

  defp headers_gen do
    entry_gen =
      StreamData.fixed_map(%{
        name: StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
        value: StreamData.string(:alphanumeric, max_length: 12)
      })

    StreamData.map(StreamData.list_of(entry_gen, max_length: 4), fn entries ->
      Headers.new(Enum.map(entries, fn %{name: name, value: value} -> {name, value} end))
    end)
  end

  defp url_search_params_gen do
    pair_gen =
      StreamData.fixed_map(%{
        key: StreamData.string(:alphanumeric, max_length: 8),
        value: StreamData.string(:alphanumeric, max_length: 12)
      })

    StreamData.map(StreamData.list_of(pair_gen, max_length: 4), fn pairs ->
      URLSearchParams.new(Enum.map(pairs, fn %{key: key, value: value} -> {key, value} end))
    end)
  end

  defp invalid_term do
    StreamData.tree(invalid_leaf(), fn inner ->
      StreamData.one_of([
        StreamData.list_of(inner, min_length: 1, max_length: 3),
        StreamData.map_of(cloneable_key(), inner, min_length: 1, max_length: 3),
        StreamData.map(StreamData.list_of(inner, min_length: 1, max_length: 3), &MapSet.new/1)
      ])
    end)
  end

  defp invalid_leaf do
    StreamData.one_of([
      StreamData.constant(self()),
      StreamData.constant(fn -> :ok end),
      StreamData.constant(make_ref())
    ])
  end

  defp canonicalize(value) when is_integer(value) or is_float(value) or is_binary(value) do
    value
  end

  defp canonicalize(value) when value in [nil, true, false], do: value

  defp canonicalize(%DateTime{} = value) do
    {:date_time, DateTime.to_iso8601(value), value.time_zone, value.utc_offset, value.std_offset}
  end

  defp canonicalize(%Regex{} = value) do
    {:regex, Regex.source(value), Enum.sort(Regex.opts(value))}
  end

  defp canonicalize(%ArrayBuffer{} = value) do
    {:array_buffer, ArrayBuffer.data(value), ArrayBuffer.byte_length(value)}
  end

  defp canonicalize(%Uint8Array{} = value) do
    {:uint8_array, canonicalize(value.buffer), value.byte_offset, value.byte_length}
  end

  defp canonicalize(%Blob{} = value) do
    {:blob, Enum.map(value.parts, &canonicalize/1), value.type, value.size}
  end

  defp canonicalize(%File{} = value) do
    {:file, Enum.map(value.parts, &canonicalize/1), value.type, value.name, value.filename,
     value.size}
  end

  defp canonicalize(%Headers{} = value) do
    {:headers, Headers.to_list(value)}
  end

  defp canonicalize(%URLSearchParams{} = value) do
    {:url_search_params, URLSearchParams.to_list(value)}
  end

  defp canonicalize(%MapSet{} = value) do
    value
    |> MapSet.to_list()
    |> Enum.map(&canonicalize/1)
    |> Enum.sort_by(&:erlang.term_to_binary/1)
    |> then(&{:map_set, &1})
  end

  defp canonicalize(value) when is_list(value) do
    Enum.map(value, &canonicalize/1)
  end

  defp canonicalize(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {canonicalize(key), canonicalize(nested)} end)
    |> Enum.sort_by(&:erlang.term_to_binary/1)
    |> then(&{:map, &1})
  end
end
