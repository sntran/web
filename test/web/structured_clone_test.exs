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
  alias Web.Internal.StructuredData
  alias Web.Internal.StructuredData.Node
  alias Web.Internal.StructuredData.Record
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
    shared = ArrayBuffer.new("shared")

    assert [first, second] = Web.structured_clone([shared, shared])
    assert first.id == second.id
    refute first.id == shared.id
  end

  def web_platform_test(%{"kind" => "shared_reference_object"}) do
    shared = ArrayBuffer.new("shared")

    assert %{"x" => first, "y" => second} = Web.structured_clone(%{"x" => shared, "y" => shared})
    assert first.id == second.id
    refute first.id == shared.id
  end

  def web_platform_test(%{"kind" => "data_clone_error"}) do
    assert_raise DOMException, fn ->
      Web.structured_clone(Web.Response.new())
    end
  end

  def web_platform_test(%{"kind" => "transfer_array_buffer", "bytes" => bytes}) do
    buffer = ArrayBuffer.new(IO.iodata_to_binary(bytes))
    clone = Web.structured_clone(buffer, transfer: [buffer])

    assert to_string(clone) == IO.iodata_to_binary(bytes)
    assert ArrayBuffer.byte_length(clone) == length(bytes)
    assert ArrayBuffer.byte_length(buffer) == 0
  end

  def web_platform_test(%{"kind" => "transfer_blob_error"}) do
    assert_raise DOMException, fn ->
      Web.structured_clone(Blob.new(["payload"]), transfer: [Blob.new(["payload"])])
    end
  end

  def web_platform_test(_test_case), do: :ok

  defmodule Point do
    defstruct [:x, :y]
  end

  defp data_clone_error(fun) do
    exception = assert_raise DOMException, fun
    assert exception.name == "DataCloneError"
    assert exception.code == 25
    exception.message
  end

  describe "data" do
    test "the clone of plain data is the same term" do
      value = %{
        "list" => [1, 2.5, "three", :four, nil, true],
        :tuple => {:ok, [1, {2, 3}]},
        "map" => %{1 => %{"deep" => [%{a: 1}]}},
        "bits" => <<1::size(3)>>,
        "improper" => [1, 2 | 3],
        "set" => MapSet.new([1, 2]),
        "date" => ~U[2024-05-06 07:08:09Z],
        "range" => 1..10//2
      }

      assert Web.structured_clone(value) === value
    end

    test "a struct that has only data stays the same struct" do
      assert Web.structured_clone(%Point{x: 1, y: [2]}) === %Point{x: 1, y: [2]}

      error = %Web.TypeError{message: "wrong", cause: %RuntimeError{message: "cause"}}
      assert Web.structured_clone(error) === error

      headers = Headers.new([{"x-test", "1"}, {"x-test", "2"}])
      assert Headers.to_list(Web.structured_clone(headers)) == Headers.to_list(headers)

      params = URLSearchParams.new([{"a", "1"}, {"a", "2"}])
      assert URLSearchParams.to_list(Web.structured_clone(params)) == [{"a", "1"}, {"a", "2"}]
    end

    test "the record of plain data is the term, and has no node" do
      value = [%{"a" => {1, 2}}]

      assert %Record{value: ^value, plain: true, ports: []} = StructuredData.serialize(value)
      assert StructuredData.deserialize(StructuredData.serialize(value)) === value
    end

    test "a large and deep value is cloned in a short time" do
      deep = Enum.reduce(1..5_000, [], fn _index, acc -> [acc] end)
      wide = Enum.map(1..50_000, &%{"index" => &1, "text" => "abc"})

      {time, clone} = :timer.tc(fn -> Web.structured_clone({deep, wide}) end)

      assert clone === {deep, wide}
      # The first algorithm made a binary of each part: its time increased
      # with the square of the depth.
      assert time < 2_000_000
    end
  end

  describe "values with an identity" do
    test "an ArrayBuffer gets a new identity and the same bytes" do
      buffer = ArrayBuffer.new("hello")
      clone = Web.structured_clone(buffer)

      assert to_string(clone) == "hello"
      refute clone.id == buffer.id

      _moved = ArrayBuffer.transfer(clone)
      assert to_string(buffer) == "hello"
    end

    test "a view is a view on the clone of its buffer" do
      buffer = ArrayBuffer.new("hello")
      view = Uint8Array.new(buffer, 1, 3)

      clone = Web.structured_clone(%{"buffer" => buffer, "view" => view, "again" => view})

      assert to_string(clone["view"]) == "ell"
      assert clone["view"].buffer.id == clone["buffer"].id
      assert clone["again"].id == clone["view"].id
      refute clone["view"].id == view.id
      refute clone["buffer"].id == buffer.id
    end

    test "a blob and a file get a new identity and the same content" do
      blob = Blob.new(["hello"], type: "text/plain")

      file = File.new([blob, " world"], "hello.txt", type: "text/plain", last_modified: 123)

      [blob_clone, file_clone, blob_again] = Web.structured_clone([blob, file, blob])

      assert Blob.to_binary(blob_clone) == "hello"
      assert blob_clone.type == "text/plain"
      refute blob_clone.id == blob.id
      assert blob_again.id == blob_clone.id

      assert %File{name: "hello.txt", type: "text/plain"} = file_clone
      assert file_clone.size == file.size
      # The File API: "Set serialized.[[LastModified]]".
      assert file_clone.last_modified == 123
      refute file_clone.id == file.id

      assert Blob.to_binary(Blob.new(file_clone.parts)) == "hello world"
    end

    test "a file of a parsed form keeps its name and its size with no bytes" do
      body =
        ~s(--b\r\nContent-Disposition: form-data; name="field"\r\n\r\nvalue\r\n) <>
          ~s(--b\r\nContent-Disposition: form-data; name="upload"; filename="a.txt"\r\n) <>
          "Content-Type: text/plain\r\n\r\nhello\r\n" <>
          ~s(--b\r\nContent-Disposition: form-data; name="after"\r\n\r\ndone\r\n--b--\r\n)

      # A change of a parsed form drops the bytes of its files that no
      # reader took. Each file keeps its size.
      form = body |> Web.FormData.parse("b") |> Web.FormData.append("extra", "x")
      file = Web.FormData.get(form, "upload")
      assert %File{name: "a.txt", parts: [], stream: nil, size: 5} = file

      clone = Web.structured_clone(file)
      assert %File{name: "a.txt", type: "text/plain", size: 5} = clone
      assert clone.last_modified == file.last_modified
    end

    test "two equal blobs stay two blobs" do
      first = Blob.new(["payload"], type: "text/plain")
      second = Blob.new(["payload"], type: "text/plain")

      [first_clone, second_clone] = Web.structured_clone([first, second])

      refute first_clone.id == second_clone.id
      assert Blob.to_binary(first_clone) == Blob.to_binary(second_clone)
    end

    test "a buffer with no identity gets a new node each time" do
      buffer = %ArrayBuffer{id: nil, data: "legacy", byte_length: 6}

      [first, second] = Web.structured_clone([buffer, buffer])

      assert to_string(first) == "legacy"
      refute first.id == second.id

      clone = Web.structured_clone(buffer, transfer: [buffer])
      assert to_string(clone) == "legacy"
    end

    test "a Regex is compiled again" do
      regex = ~r/fo+/im
      clone = Web.structured_clone(%{regex => [regex]})

      assert [{key, [value]}] = Map.to_list(clone)
      assert Regex.source(key) == "fo+"
      assert Regex.opts(value) == Regex.opts(regex)
      assert Regex.match?(value, "FOO")
    end

    test "a value with an identity can be a key, an element of a tuple, and a tail" do
      buffer = ArrayBuffer.new("k")

      clone = Web.structured_clone(%{buffer => {buffer, [1 | buffer]}})

      assert [{key, {element, [1 | tail]}}] = Map.to_list(clone)
      assert key.id == element.id
      assert key.id == tail.id
      refute key.id == buffer.id
    end

    test "the record has a node for the value, and the same node for the same value" do
      buffer = ArrayBuffer.new("x")

      assert %Record{plain: false, value: [node, node]} =
               StructuredData.serialize([buffer, buffer])

      assert %Node{type: :array_buffer, data: "x"} = node
    end
  end

  describe "values that cannot be cloned" do
    test "a pid, a port, a reference, and a function" do
      assert data_clone_error(fn -> Web.structured_clone(self()) end) == "A pid cannot be cloned."

      assert data_clone_error(fn -> Web.structured_clone([1, make_ref()]) end) ==
               "A reference cannot be cloned."

      assert data_clone_error(fn -> Web.structured_clone(%{"f" => fn -> :ok end}) end) ==
               "A function cannot be cloned."

      port = Port.open({:spawn, "cat"}, [:binary])

      try do
        assert data_clone_error(fn -> Web.structured_clone({port}) end) ==
                 "A port cannot be cloned."
      after
        Port.close(port)
      end
    end

    test "the message names the struct that has the value" do
      stream = Web.ReadableStream.from("payload")

      assert data_clone_error(fn -> Web.structured_clone(%{"body" => stream}) end) ==
               "A Web.ReadableStream cannot be cloned."

      assert data_clone_error(fn -> Web.structured_clone(Web.Response.new()) end) ==
               "A Web.Response cannot be cloned."

      assert data_clone_error(fn ->
               Web.structured_clone([Web.Request.new("https://example.com")])
             end) == "A Web.Request cannot be cloned."

      for live <- [
            Web.Promise.resolve(1),
            Web.AbortSignal.abort(),
            Web.AbortController.new()
          ] do
        assert data_clone_error(fn -> Web.structured_clone(%{"value" => live}) end) ==
                 "A #{inspect(live.__struct__)} cannot be cloned."
      end
    end

    test "a file that has a stream" do
      file = %{
        File.new([], "stream.txt", type: "text/plain")
        | stream: Web.ReadableStream.from("payload")
      }

      assert data_clone_error(fn -> Web.structured_clone(file) end) ==
               "A file that has a stream cannot be cloned."
    end

    test "a detached ArrayBuffer, also below a view" do
      buffer = ArrayBuffer.new("hello")
      view = Uint8Array.new(buffer)
      _moved = ArrayBuffer.transfer(buffer)

      assert data_clone_error(fn -> Web.structured_clone(buffer) end) ==
               "A detached ArrayBuffer cannot be cloned."

      assert data_clone_error(fn -> Web.structured_clone([view]) end) ==
               "A detached ArrayBuffer cannot be cloned."
    end

    test "a MessagePort that is not in the transfer list" do
      {port1, port2} = MessageChannel.new()

      assert data_clone_error(fn -> Web.structured_clone(%{"port" => port1}) end) ==
               "A MessagePort cannot be cloned. Put it in the transfer list."

      MessagePort.close(port1)
      MessagePort.close(port2)
    end

    test "an internal record" do
      record = StructuredData.serialize(ArrayBuffer.new("x"))

      data_clone_error(fn -> Web.structured_clone(record) end)
      data_clone_error(fn -> Web.structured_clone([record.value]) end)
    end
  end

  describe "the transfer list" do
    test "a transferred ArrayBuffer is detached, and the clone has its bytes" do
      buffer = ArrayBuffer.new("hello")
      clone = Web.structured_clone(%{"buffer" => buffer}, transfer: [buffer])

      assert to_string(clone["buffer"]) == "hello"
      assert ArrayBuffer.byte_length(clone["buffer"]) == 5
      assert ArrayBuffer.detached?(buffer)
      assert ArrayBuffer.byte_length(buffer) == 0
    end

    test "a transferred value that is not in the message is detached too" do
      buffer = ArrayBuffer.new("hello")

      assert Web.structured_clone("message", transfer: [buffer]) == "message"
      assert ArrayBuffer.detached?(buffer)
    end

    test "a detached ArrayBuffer cannot be transferred" do
      buffer = ArrayBuffer.new("hello")
      _moved = ArrayBuffer.transfer(buffer)

      assert data_clone_error(fn -> Web.structured_clone("message", transfer: [buffer]) end) ==
               "A detached ArrayBuffer cannot be transferred."
    end

    test "the same value two times is an error" do
      buffer = ArrayBuffer.new("hello")

      assert data_clone_error(fn -> Web.structured_clone(buffer, transfer: [buffer, buffer]) end) ==
               "The transfer list has the same value two times."

      refute ArrayBuffer.detached?(buffer)
    end

    test "a value that is not transferable is an error" do
      blob = Blob.new(["hello"], type: "text/plain")

      assert data_clone_error(fn -> Web.structured_clone(blob, transfer: [blob]) end) =~
               "cannot be transferred"

      data_clone_error(fn -> Web.structured_clone(1, transfer: ["text"]) end)
    end

    test "nothing is detached when the message cannot be cloned" do
      buffer = ArrayBuffer.new("hello")
      {port1, port2} = MessageChannel.new()

      data_clone_error(fn ->
        Web.structured_clone(%{"bad" => self()}, transfer: [buffer, port1])
      end)

      refute ArrayBuffer.detached?(buffer)

      # The handle of the port is valid: a transfer is possible.
      assert %MessagePort{} = Web.structured_clone(port1, transfer: [port1])
      MessagePort.close(port2)
    end

    test "a transferred MessagePort gives a new handle, and the first handle is detached" do
      {port1, port2} = MessageChannel.new()
      test = self()

      moved = Web.structured_clone(port1, transfer: [port1])

      assert %MessagePort{} = moved
      refute moved == port1

      assert data_clone_error(fn -> Web.structured_clone(port1, transfer: [port1]) end) =~
               "closed or detached"

      MessagePort.onmessage(port2, fn event -> send(test, {:port2, event.data}) end)

      # The first handle sends nothing. The new handle sends.
      assert :ok = MessagePort.post_message(port1, "from the first handle")
      assert :ok = MessagePort.post_message(moved, "from the new handle")

      assert_receive {:port2, "from the new handle"}
      refute_receive {:port2, _other}, 50

      MessagePort.close(moved)
      MessagePort.close(port2)
    end

    test "the record has the transferred ports in the sequence of the list" do
      {port1, port2} = MessageChannel.new()
      {port3, port4} = MessageChannel.new()

      record = StructuredData.serialize([port3], transfer: [port1, port3])

      assert %Record{plain: false, ports: [first, second]} = record
      assert first.address == port1.address
      assert second.address == port3.address

      assert {[in_message], [moved1, moved3]} = StructuredData.deserialize_with_ports(record)
      assert in_message == moved3
      assert moved1.address == port1.address

      Enum.each([moved1, moved3, port2, port4], &MessagePort.close/1)
    end
  end

  describe "options" do
    test "use Web imports structured_clone/1 and structured_clone/2" do
      assert UsingWeb.clone(%{"ok" => true}) == %{"ok" => true}

      buffer = ArrayBuffer.new("hi")
      clone = UsingWeb.clone(buffer, transfer: [buffer])

      assert to_string(clone) == "hi"
      assert ArrayBuffer.byte_length(buffer) == 0
    end

    test "options that are not correct raise TypeError" do
      assert_raise TypeError, ~r/Unknown options/, fn ->
        Web.structured_clone(%{}, foo: :bar)
      end

      assert_raise TypeError, ~r/:transfer must be a list/, fn ->
        Web.structured_clone(%{}, transfer: :invalid)
      end

      assert_raise TypeError, ~r/keyword list/, fn ->
        Web.structured_clone(%{}, [:not_a_keyword])
      end

      assert_raise TypeError, ~r/keyword list/, fn ->
        Web.structured_clone(%{}, "invalid")
      end

      assert_raise TypeError, ~r/:port_holder must be a pid/, fn ->
        StructuredData.serialize(%{}, port_holder: :invalid)
      end
    end

    test "DOMException.exception/1 accepts a name" do
      exception = DOMException.exception("DataCloneError")

      assert exception.name == "DataCloneError"
      assert exception.message == "DataCloneError"
      assert exception.code == 25
    end
  end

  describe "properties" do
    property "the clone of data is the same term" do
      check all(value <- data_term(), max_runs: 200) do
        assert Web.structured_clone(value) === value
        assert %Record{plain: true} = StructuredData.serialize(value)
      end
    end

    property "the clone has the same content, and a second clone too" do
      check all(value <- cloneable_term(), max_runs: 100) do
        clone = Web.structured_clone(value)
        clone_twice = Web.structured_clone(clone)

        assert canonicalize(clone) == canonicalize(value)
        assert canonicalize(clone_twice) == canonicalize(clone)
      end
    end

    property "the clone shares no identity with the source" do
      check all(value <- cloneable_term(), max_runs: 100) do
        clone = Web.structured_clone(value)

        assert MapSet.disjoint?(identities(value), identities(clone))
        # One identity in the source is one identity in the clone.
        assert MapSet.size(identities(clone)) == MapSet.size(identities(value))
      end
    end

    property "a value that cannot be cloned makes the full value impossible to clone" do
      check all(value <- invalid_term(), max_runs: 100) do
        data_clone_error(fn -> Web.structured_clone(value) end)
      end
    end

    property "a transfer detaches each buffer of the list, and only those" do
      check all(
              data <- StreamData.list_of(StreamData.binary(max_length: 8), max_length: 5),
              picks <- StreamData.list_of(StreamData.boolean(), length: length(data)),
              max_runs: 100
            ) do
        buffers = Enum.map(data, &ArrayBuffer.new/1)
        moved = for {buffer, true} <- Enum.zip(buffers, picks), do: buffer

        clone = Web.structured_clone(buffers, transfer: moved)

        assert Enum.map(clone, &to_string/1) == data

        for {buffer, moved?} <- Enum.zip(buffers, picks) do
          assert ArrayBuffer.detached?(buffer) == moved?
        end
      end
    end

    property "a record goes to a different process and gives the same content" do
      check all(value <- cloneable_term(), max_runs: 50) do
        record = StructuredData.serialize(value)

        task = Task.async(fn -> canonicalize(StructuredData.deserialize(record)) end)

        assert Task.await(task) == canonicalize(value)
      end
    end
  end

  defp data_term do
    leaf =
      StreamData.one_of([
        StreamData.integer(),
        StreamData.float(),
        StreamData.binary(max_length: 16),
        StreamData.bitstring(max_length: 16),
        StreamData.boolean(),
        StreamData.constant(nil),
        StreamData.atom(:alphanumeric),
        date_time_gen()
      ])

    StreamData.tree(leaf, fn inner ->
      StreamData.one_of([
        StreamData.list_of(inner, max_length: 3),
        StreamData.map(StreamData.list_of(inner, max_length: 3), &List.to_tuple/1),
        StreamData.map_of(inner, inner, max_length: 3),
        StreamData.map(StreamData.list_of(inner, max_length: 3), &MapSet.new/1),
        StreamData.map({inner, inner}, fn {x, y} -> %Point{x: x, y: y} end),
        StreamData.map({inner, inner}, fn {head, tail} -> [head | tail] end)
      ])
    end)
  end

  # The identities of the values in a term.
  defp identities(%ArrayBuffer{id: id}), do: MapSet.new([id])

  defp identities(%Uint8Array{id: id, buffer: buffer}) do
    MapSet.put(identities(buffer), id)
  end

  defp identities(%Blob{id: id, parts: parts}), do: MapSet.put(identities(parts), id)
  defp identities(%File{id: id, parts: parts}), do: MapSet.put(identities(parts), id)
  defp identities(%Regex{}), do: MapSet.new()
  defp identities(%_{} = struct), do: identities(Map.from_struct(struct))

  defp identities(%{} = map) do
    Enum.reduce(map, MapSet.new(), fn {key, value}, acc ->
      acc |> MapSet.union(identities(key)) |> MapSet.union(identities(value))
    end)
  end

  defp identities(list) when is_list(list) do
    Enum.reduce(list, MapSet.new(), &MapSet.union(identities(&1), &2))
  end

  defp identities(_other), do: MapSet.new()

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
          type: StreamData.string(:alphanumeric, max_length: 12),
          last_modified: StreamData.integer()
        })
        |> StreamData.map(fn %{name: name, type: type, last_modified: last_modified} ->
          File.new(parts, name, type: type, last_modified: last_modified)
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
    {:array_buffer, to_string(value), ArrayBuffer.byte_length(value)}
  end

  defp canonicalize(%Uint8Array{} = value) do
    {:uint8_array, canonicalize(value.buffer), value.byte_offset, value.byte_length}
  end

  defp canonicalize(%Blob{} = value) do
    {:blob, Enum.map(value.parts, &canonicalize/1), value.type, value.size}
  end

  defp canonicalize(%File{} = value) do
    {:file, Enum.map(value.parts, &canonicalize/1), value.type, value.name, value.size,
     value.last_modified}
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
