defmodule Web.BodyStandardTest do
  # The rules of the body of a request and a response in the Fetch Standard:
  # "consume body", the body stream as a byte stream, `clone()`,
  # `textStream()`, and the pipe of a body.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.ArrayBuffer
  alias Web.Blob
  alias Web.Internal.LazyStream
  alias Web.ReadableStream
  alias Web.ReadableStreamBYOBReader, as: BYOBReader
  alias Web.ReadableStreamDefaultReader, as: Reader
  alias Web.Request
  alias Web.Response
  alias Web.TypeError
  alias Web.Uint8Array

  # The forms of a body, from the bytes of the body.
  defp body_forms(bytes) do
    [
      bytes,
      Blob.new([bytes]),
      ArrayBuffer.new(bytes),
      Uint8Array.from(bytes)
    ]
  end

  defp stream_of(chunks) do
    ReadableStream.new(%{
      start: fn controller ->
        for chunk <- chunks, do: Web.ReadableStreamDefaultController.enqueue(controller, chunk)
        Web.ReadableStreamDefaultController.close(controller)
      end
    })
  end

  # A process that holds a body, as the process of a `fetch` request: it
  # gives its bytes to a read of all the bytes, or to the stream that a
  # stream read starts.
  defp held_body(bytes) do
    holder =
      spawn(fn ->
        receive do
          {:web_body, _ref, {:take, monitor, from}} ->
            send(from, {monitor, {:ok, bytes}})

          # The first pull of the stream process: it comes with the first
          # read. The holder finds the stream process with the key.
          {:web_body, ref, :pull} ->
            [{stream, _value}] = Registry.lookup(LazyStream.registry(), ref)
            ReadableStream.enqueue(stream, Uint8Array.from(bytes))
            ReadableStream.close(stream)
        end

        receive do
          :stop -> :ok
        end
      end)

    {holder, %ReadableStream{lazy: LazyStream.new({:held, holder})}}
  end

  @functions [
    &Response.text/1,
    &Response.json/1,
    &Response.array_buffer/1,
    &Response.bytes/1,
    &Response.blob/1
  ]

  describe "a body function" do
    property "takes the reader before it returns, and the reader keeps its lock" do
      check all(
              bytes <- string(:alphanumeric, max_length: 100),
              body <- member_of(body_forms(~s("#{bytes}")) ++ [:stream, :large]),
              function <- member_of(@functions)
            ) do
        body =
          case body do
            :stream -> stream_of([Uint8Array.from(~s("#{bytes}"))])
            :large -> ~s("#{String.duplicate("x", 70_000)}")
            body -> body
          end

        response = Response.new(body)
        promise = function.(response)

        assert Response.body_used?(response)
        assert ReadableStream.locked?(response.body)
        assert_raise TypeError, fn -> ReadableStream.get_reader(response.body) end

        _value = await(promise)
        assert ReadableStream.locked?(response.body)
        assert_raise TypeError, fn -> ReadableStream.get_reader(response.body) end

        assert %TypeError{message: "body already used"} = catch_exit(await(function.(response)))
      end
    end

    test "takes the reader of a body that a process holds before it returns" do
      {holder, body} = held_body("held")
      response = Response.new(body)
      promise = Response.text(response)

      assert ReadableStream.locked?(response.body)
      assert await(promise) == "held"
      send(holder, :stop)
    end

    test "rejects for a stream with a reader, and gives the error of an errored stream" do
      response = Response.new(stream_of(["a"]))
      _reader = ReadableStream.get_reader(response.body)

      for function <- @functions do
        assert %TypeError{message: "ReadableStream is already locked"} =
                 catch_exit(await(function.(response)))
      end

      error = %RuntimeError{message: "start error"}

      errored =
        Response.new(
          ReadableStream.new(%{start: &Web.ReadableStreamDefaultController.error(&1, error)})
        )

      assert ^error = catch_exit(await(Response.form_data(errored)))
    end

    test "formData() reads the body before the TypeError of a type that is not a form" do
      pull_error = %RuntimeError{message: "pull error"}

      for {headers, expected} <- [
            {[], pull_error},
            {[{"content-type", "application/x-www-form-urlencoded"}], pull_error}
          ] do
        body =
          ReadableStream.new(%{pull: &Web.ReadableStreamDefaultController.error(&1, pull_error)})

        assert ^expected =
                 catch_exit(await(Response.form_data(Response.new(body, headers: headers))))
      end

      response = Response.new(stream_of(["a=1"]))

      assert %TypeError{message: "Cannot parse form data" <> _} =
               catch_exit(await(Response.form_data(response)))

      assert Response.body_used?(response)

      form =
        await(
          Response.form_data(
            Response.new(stream_of(["a=1&b", "=2"]),
              headers: [{"content-type", "application/x-www-form-urlencoded"}]
            )
          )
        )

      assert Web.FormData.get(form, "b") == "2"
    end

    # The steps "consume body" do not use the signal of the request.
    test "reads the body also after an abort of the request signal" do
      for body <- ["a=1", stream_of(["a=1"])] do
        controller = Web.AbortController.new()

        request =
          Request.new("https://example.com/",
            method: "POST",
            body: body,
            headers: [{"content-type", "application/x-www-form-urlencoded"}],
            duplex: "half",
            signal: controller.signal
          )

        Web.AbortController.abort(controller, :stop)
        assert Web.FormData.get(await(Request.form_data(request)), "a") == "1"
      end
    end

    test "reads a multipart form also after an abort of the request signal" do
      controller = Web.AbortController.new()
      form = Web.FormData.new() |> Web.FormData.append("a", "1")

      request =
        Request.new("https://example.com/", method: "POST", body: form, signal: controller.signal)

      Web.AbortController.abort(controller, :stop)
      assert Web.FormData.get(await(Request.form_data(request)), "a") == "1"
    end

    test "rejects for a body that an enumeration read, or that a cancel closed" do
      read = Response.new("a")
      assert [_chunk] = Enum.to_list(read.body)

      canceled = Response.new("a")
      assert :ok = await(ReadableStream.cancel(canceled.body))

      for response <- [read, canceled], function <- @functions do
        assert %TypeError{message: "body already used"} = catch_exit(await(function.(response)))
      end
    end
  end

  describe "the body stream" do
    property "is a byte stream: a BYOB reader reads each form of a body" do
      check all(
              bytes <- binary(min_length: 1, max_length: 200),
              body <- member_of(body_forms(bytes)),
              size <- integer(1..64)
            ) do
        for struct <- [
              Response.new(body),
              Request.new("https://example.com/", method: "POST", body: body)
            ] do
          reader = ReadableStream.get_reader(struct.body, mode: "byob")
          assert read_byob(reader, size, []) == bytes
        end
      end
    end

    test "is a byte stream for a form and for URLSearchParams" do
      form = Web.FormData.new() |> Web.FormData.append("name", "value")
      params = Web.URLSearchParams.new("a=1")

      for body <- [form, params] do
        response = Response.new(body)
        reader = ReadableStream.get_reader(response.body, mode: "byob")
        text = read_byob(reader, 16, [])
        assert text =~ "name" or text == "a=1"
      end
    end

    test "gives no chunk for no bytes, and the close delimiter for an empty form" do
      for body <- body_forms("") do
        assert Enum.to_list(Response.new(body).body) == []
      end

      form = Web.FormData.new()
      text = await(Response.text(Response.new(form)))
      assert text == "--#{form.boundary}--\r\n"
      assert %Web.FormData{} = await(Response.form_data(Response.new(form)))
    end

    test "of a stream from the caller is the same stream" do
      stream = stream_of(["a"])
      assert Response.new(stream).body == stream

      assert_raise TypeError, ~r/not a byte stream/, fn ->
        ReadableStream.get_reader(stream, mode: "byob")
      end
    end
  end

  defp read_byob(reader, size, acc) do
    case await(BYOBReader.read(reader, Uint8Array.new(ArrayBuffer.new(size)))) do
      %{done: true} -> acc |> Enum.reverse() |> IO.iodata_to_binary()
      %{value: view} -> read_byob(reader, size, [Uint8Array.to_binary(view) | acc])
    end
  end

  describe "a pipe of a body" do
    test "disturbs the body when the function returns, before a read" do
      response = Response.new(stream_of(["a"]))
      destination = Web.WritableStream.new(%{}, high_water_mark: 0)
      _promise = ReadableStream.pipe_to(response.body, destination)

      assert Response.body_used?(response)

      other = Response.new("a")

      _readable =
        ReadableStream.pipe_through(other.body, %{
          writable: Web.WritableStream.new(%{}, high_water_mark: 0),
          readable: ReadableStream.new()
        })

      assert Response.body_used?(other)
    end
  end

  test "a cancel of an errored stream disturbs it" do
    response =
      Response.new(
        ReadableStream.new(%{start: &Web.ReadableStreamDefaultController.error(&1, :boom)})
      )

    reader = ReadableStream.get_reader(response.body)
    refute Response.body_used?(response)

    assert :boom = catch_exit(await(Reader.cancel(reader, :reason)))
    assert Response.body_used?(response)
  end

  describe "clone/1" do
    test "gives the second branch a structured clone of each chunk" do
      chunk = Uint8Array.from("abc")
      {original, clone} = Response.clone(Response.new(stream_of([chunk])))

      [first] = Enum.to_list(original.body)
      [second] = Enum.to_list(clone.body)

      assert first == chunk
      assert Uint8Array.to_binary(second) == "abc"
      refute second.buffer.id == chunk.buffer.id

      # The buffers are separate: a detach of one has no effect on the other.
      ArrayBuffer.detach(first.buffer)
      assert Uint8Array.to_binary(second) == "abc"
    end

    test "errors the two branches and cancels the body for a chunk that cannot be cloned" do
      test = self()

      body =
        ReadableStream.new(%{
          start: &Web.ReadableStreamDefaultController.enqueue(&1, test),
          cancel: fn reason -> send(test, {:cancel, reason}) end
        })

      {original, clone} = Response.clone(Response.new(body))

      for branch <- [original, clone] do
        assert %Web.DOMException{name: "DataCloneError"} =
                 catch_exit(await(Response.text(branch)))
      end

      assert_receive {:cancel, %Web.DOMException{name: "DataCloneError"}}
    end

    test "is different from tee/1, which gives the same chunk to the two branches" do
      chunk = Uint8Array.from("abc")
      stream = stream_of([chunk])

      for branch <- ReadableStream.tee(Web.ReadableStream.__with_process__(stream)) do
        assert Enum.to_list(branch) == [chunk]
      end
    end

    test "refuses a body that is disturbed or locked" do
      used = Response.new("a")
      await(Response.text(used))
      assert_raise TypeError, "body already used", fn -> Response.clone(used) end

      locked = Response.new("a")
      _reader = ReadableStream.get_reader(locked.body)
      assert_raise TypeError, "ReadableStream is already locked", fn -> Response.clone(locked) end
    end
  end

  describe "text_stream/1" do
    property "gives the UTF-8 decode of the bytes as text chunks, for each split" do
      check all(
              text <- string(:printable),
              cuts <- list_of(integer(0..byte_size(text)), max_length: 4)
            ) do
        chunks = split(text, cuts) |> Enum.map(&Uint8Array.from/1)

        for struct <- [
              Response.new(stream_of(chunks)),
              Request.new("https://example.com/", method: "POST", body: text)
            ] do
          stream = struct.__struct__.text_stream(struct)
          assert struct.__struct__.body_used?(struct)

          parts = Enum.to_list(stream)
          assert Enum.all?(parts, &is_binary/1)
          assert Enum.join(parts) == text
        end
      end
    end

    test "decodes UTF-8 for each charset of the content-type" do
      bytes = <<0x68, 0x00, 0x69, 0x00, 0xFF>>

      for type <- ["text/plain; charset=utf-16le", "text/plain; charset=invalid"] do
        response = Response.new(bytes, headers: [{"content-type", type}])
        assert response |> Response.text_stream() |> Enum.join() == "h\0i\0�"
      end
    end

    test "locks the body for the pipe" do
      # The pipe waits for a chunk of this stream: the lock stays.
      response = Response.new(ReadableStream.new())
      _stream = Response.text_stream(response)

      assert Response.body_used?(response)
      assert ReadableStream.locked?(response.body)
    end

    test "gives a new stream with no chunks for no body" do
      response = Response.new()
      first = Response.text_stream(response)
      second = Response.text_stream(response)

      refute first == second
      refute Response.body_used?(response)
      assert Enum.to_list(first) == []
      assert Enum.to_list(second) == []
    end

    test "raises for a body that is disturbed or locked" do
      used = Request.new("https://example.com/", method: "POST", body: "a")
      _promise = Request.text(used)
      assert_raise TypeError, fn -> Request.text_stream(used) end

      locked = Response.new("a")
      _reader = ReadableStream.get_reader(locked.body)
      assert_raise TypeError, fn -> Response.text_stream(locked) end

      canceled = Response.new("a")
      assert :ok = await(ReadableStream.cancel(canceled.body))
      refute ReadableStream.locked?(canceled.body)
      assert_raise TypeError, "body already used", fn -> Response.text_stream(canceled) end
    end
  end

  defp split(text, cuts) do
    cuts = cuts |> Enum.sort() |> Enum.uniq()

    {parts, rest, _at} =
      Enum.reduce(cuts, {[], text, 0}, fn cut, {parts, rest, at} ->
        {part, rest} = :erlang.split_binary(rest, cut - at)
        {[part | parts], rest, cut}
      end)

    Enum.reverse([rest | parts])
  end

  describe "the proxy of a body" do
    test "of a body that a process holds goes through a stream" do
      {holder, body} = held_body("held")
      proxy = Web.Body.__proxy__(body)

      assert ReadableStream.locked?(body)
      assert await(Response.text(Response.new(proxy))) == "held"
      send(holder, :stop)
    end

    test "refuses a stream with no process that is locked" do
      body = ReadableStream.__from__("abc")
      [_left, _right] = ReadableStream.tee(body)

      assert_raise TypeError, "ReadableStream is already locked", fn ->
        Web.Body.__proxy__(body)
      end
    end

    test "of a stream with no process that has a process now goes through a stream" do
      body = ReadableStream.__from__("abc")
      reader = ReadableStream.get_reader(body)
      :ok = Reader.release_lock(reader)

      proxy = Web.Body.__proxy__(body)
      assert ReadableStream.locked?(body)
      assert Enum.map_join(proxy, &Uint8Array.to_binary/1) == "abc"
    end
  end
end
