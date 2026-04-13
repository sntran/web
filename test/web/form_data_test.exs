defmodule Web.FormDataTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.AbortController
  alias Web.AsyncContext
  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultReader

  defmodule ShutdownCallMachine do
    @behaviour :gen_statem

    def start_link do
      :gen_statem.start(__MODULE__, :ok, [])
    end

    def callback_mode, do: :handle_event_function

    def init(:ok), do: {:ok, :running, nil}

    def handle_event({:call, _from}, _request, :running, data) do
      {:stop, {:shutdown, :call_failed}, data}
    end
  end

  test "parse parses text and file parts" do
    boundary = "----web-boundary"

    payload =
      multipart_payload(boundary, [
        %{name: "field", value: "value"},
        %{name: "upload", filename: "hello.txt", content_type: "text/plain", value: "hello file"}
      ])

    stream = payload |> chunk_binary([3, 2, 7, 1, 5]) |> ReadableStream.from()
    form_data = Web.FormData.parse(stream, boundary)

    assert Web.FormData.get(form_data, "field") == "value"

    assert %Web.File{name: "upload", filename: "hello.txt", type: "text/plain"} =
             file = Web.FormData.get(form_data, "upload")

    assert Enum.join(Web.File.stream(file), "") == "hello file"
  end

  test "parse raises on malformed multipart payload" do
    assert_raise Web.TypeError, ~r/missing opening boundary/, fn ->
      Web.FormData.parse("bad multipart", "boundary")
    end
  end

  test "parse decodes RFC 5987 filename* parameters" do
    boundary = "----utf8-boundary"

    payload =
      multipart_payload(boundary, [
        %{
          name: "upload",
          value: "payload",
          disposition:
            "form-data; name=\"upload\"; filename=\"fallback.txt\"; filename*=utf-8''%E2%82%ACrates.txt"
        }
      ])

    form_data = Web.FormData.parse(payload, boundary)

    assert %Web.File{filename: "€rates.txt"} =
             Web.FormData.get(form_data, "upload")
  end

  test "later fields stay blocked until the active file stream advances upstream" do
    boundary = "----stall-boundary"

    payload =
      multipart_payload(boundary, [
        %{name: "upload", filename: "big.txt", content_type: "text/plain", value: "hello file"},
        %{name: "after", value: "done"}
      ])

    {stream, tracker} = tracked_source(byte_chunks(payload))
    form_data = Web.FormData.parse(stream, boundary)
    file = Web.FormData.get(form_data, "upload")
    pulls_before = stable_source_pulls(tracker)

    later_field = Task.async(fn -> Web.FormData.get(form_data, "after") end)

    Process.sleep(50)
    assert Task.yield(later_field, 0) == nil
    assert stable_source_pulls(tracker) == pulls_before

    assert Enum.join(Web.File.stream(file), "") == "hello file"
    assert Task.await(later_field) == "done"
    assert source_pulls(tracker) > pulls_before
  end

  test "pending get and has queries resolve after the active file finishes" do
    boundary = "pending-success-boundary"

    payload =
      multipart_payload(boundary, [
        %{
          name: "upload",
          filename: "big.txt",
          content_type: "text/plain",
          value: String.duplicate("a", 64)
        },
        %{name: "after", value: "done"}
      ])

    {stream, _tracker} = tracked_source(byte_chunks(payload))
    form = Web.FormData.parse(stream, boundary)
    file = Web.FormData.get(form, "upload")

    get_waiter = Task.async(fn -> Web.FormData.get(form, "after") end)
    has_waiter = Task.async(fn -> Web.FormData.has?(form, "after") end)

    Process.sleep(50)
    assert Task.yield(get_waiter, 0) == nil
    assert Task.yield(has_waiter, 0) == nil

    assert Enum.join(Web.File.stream(file), "") == String.duplicate("a", 64)
    assert Task.await(get_waiter) == "done"
    assert Task.await(has_waiter) == true
  end

  test "cancel propagates cancellation to child file streams and upstream" do
    boundary = "----cancel-boundary"

    payload =
      multipart_payload(boundary, [
        %{name: "upload", filename: "big.txt", content_type: "text/plain", value: "hello file"}
      ])

    {stream, tracker} = tracked_source(byte_chunks(payload))
    form_data = Web.FormData.parse(stream, boundary)
    file = Web.FormData.get(form_data, "upload")
    child_stream = Web.File.stream(file)

    assert :ok = Web.FormData.cancel(form_data, :user_cancelled)
    assert_eventually(fn -> source_cancel_reason(tracker) == :user_cancelled end)
    assert_eventually(fn -> not Process.alive?(form_data.coordinator) end)
    assert_eventually(fn -> not Process.alive?(child_stream.controller_pid) end)
  end

  test "local form data operations remain eager" do
    form =
      Web.FormData.new(boundary: "  eager-boundary  ")
      |> Web.FormData.append("a", "1")
      |> Web.FormData.append("b", Web.Blob.new(["blob"], type: "text/plain"), "blob.txt")

    assert Web.FormData.get(form, "a") == "1"
    assert Web.FormData.has?(form, "a") == true
    assert [%Web.File{filename: "blob.txt", type: "text/plain"}] = Web.FormData.get_all(form, "b")
    assert Web.FormData.content_type(form) == "multipart/form-data; boundary=eager-boundary"

    updated =
      form
      |> Web.FormData.set("a", "2")
      |> Web.FormData.delete("b")

    assert Web.FormData.get(updated, "a") == "2"
    assert Web.FormData.has?(updated, "b") == false
    assert Enum.to_list(Web.FormData.entries(updated)) == [["a", "2"]]
    assert Web.FormData.cancel(updated) == :ok
  end

  test "append uses blob filename fallback and file filename override" do
    blob_form =
      Web.FormData.new()
      |> Web.FormData.append("upload", Web.Blob.new(["x"], type: "text/plain"))

    assert %Web.File{filename: "blob", type: "text/plain"} =
             Web.FormData.get(blob_form, "upload")

    file = Web.File.new(["x"], name: "upload", filename: "old.txt", type: "text/plain")
    updated = Web.FormData.new() |> Web.FormData.append("upload", file, "new.txt")
    assert %Web.File{filename: "new.txt"} = Web.FormData.get(updated, "upload")
  end

  test "append preserves existing file metadata when no filename override is provided" do
    file = Web.File.new(["x"], name: "upload", filename: "kept.txt", type: "text/plain")

    form =
      Web.FormData.new()
      |> Web.FormData.append("upload", file)

    assert %Web.File{filename: "kept.txt", type: "text/plain"} =
             Web.FormData.get(form, "upload")
  end

  test "static files stream from blob parts when no live stream is attached" do
    file = Web.File.new(["hello"], name: "upload", filename: "hello.txt", type: "text/plain")
    assert Enum.join(Web.File.stream(file), "") == "hello"
  end

  test "live forms drain before eager mutations" do
    boundary = "live-mutate-boundary"

    form =
      multipart_payload(boundary, [
        %{name: "a", value: "1"},
        %{name: "b", value: "2"}
      ])
      |> Web.FormData.parse(boundary)

    # Enum.to_list collects all entries as [name, value] pairs
    assert Enum.to_list(form) == [["a", "1"], ["b", "2"]]
    assert Enum.to_list(Web.FormData.entries(form)) == [["a", "1"], ["b", "2"]]

    # Mutations on a static form work eagerly
    static = %{form | coordinator: nil}
    appended = Web.FormData.append(static, "c", "3")
    assert Web.FormData.get(appended, "c") == "3"

    replaced = Web.FormData.set(static, "a", "9")
    assert Web.FormData.get(replaced, "a") == "9"

    deleted = Web.FormData.delete(static, "b")
    assert Web.FormData.has?(deleted, "b") == false

    # Mutations directly on a still-live form trigger internal drain
    form2 =
      multipart_payload(boundary, [
        %{name: "a", value: "1"},
        %{name: "b", value: "2"}
      ])
      |> Web.FormData.parse(boundary)

    appended2 = Web.FormData.append(form2, "c", "3")
    assert Web.FormData.get(appended2, "c") == "3"
    assert Web.FormData.get(appended2, "a") == "1"

    form3 =
      multipart_payload(boundary, [
        %{name: "a", value: "1"},
        %{name: "b", value: "2"}
      ])
      |> Web.FormData.parse(boundary)

    replaced2 = Web.FormData.set(form3, "a", "9")
    assert Web.FormData.get(replaced2, "a") == "9"

    form4 =
      multipart_payload(boundary, [
        %{name: "a", value: "1"},
        %{name: "b", value: "2"}
      ])
      |> Web.FormData.parse(boundary)

    deleted2 = Web.FormData.delete(form4, "b")
    assert Web.FormData.has?(deleted2, "b") == false
  end

  test "live forms return nil, false, and [] for missing fields after completion" do
    boundary = "missing-fields-boundary"

    form =
      multipart_payload(boundary, [
        %{name: "present", value: "1"}
      ])
      |> Web.FormData.parse(boundary)

    assert Web.FormData.get(form, "missing") == nil
    assert Web.FormData.has?(form, "missing") == false
    assert Web.FormData.get_all(form, "missing") == []
  end

  test "empty multipart bodies parse successfully" do
    form = Web.FormData.parse("--empty-boundary--\r\n", "empty-boundary")
    assert Enum.to_list(Web.FormData.entries(form)) == []
  end

  test "freeze pattern snapshots a live form and releases resources" do
    boundary = "freeze-pattern-boundary"

    payload =
      multipart_payload(boundary, [
        %{name: "destination", value: "archive"},
        %{
          name: "payload",
          filename: "big.bin",
          content_type: "application/octet-stream",
          value: String.duplicate("z", 1024)
        },
        %{name: "after", value: "done"}
      ])

    {stream, _tracker} = tracked_source(byte_chunks(payload))
    live_form = Web.FormData.parse(stream, boundary)
    file = Web.FormData.get(live_form, "payload")
    file_stream_pid = Web.File.stream(file).controller_pid

    # Freeze a live coordinator into a static snapshot.
    frozen = Enum.into(%Web.FormData{}, live_form)

    assert frozen.coordinator == nil
    assert Web.FormData.get(frozen, "destination") == "archive"
    assert Web.FormData.get(frozen, "after") == "done"
    assert %Web.File{filename: "big.bin", stream: nil} = Web.FormData.get(frozen, "payload")

    assert_eventually(fn -> not Process.alive?(live_form.coordinator) end)
    assert_eventually(fn -> ReadableStream.locked?(stream) == false end)
    assert_eventually(fn -> not Process.alive?(file_stream_pid) end)
  end

  test "discard on cancel drains the current file body and reaches subsequent fields" do
    boundary = "discard-boundary"

    form =
      multipart_payload(boundary, [
        %{name: "upload", filename: "discard.txt", content_type: "text/plain", value: "skip me"},
        %{name: "after", value: "visible"}
      ])
      |> Web.FormData.parse(boundary)

    file = Web.FormData.get(form, "upload")
    assert :ok = await(ReadableStream.cancel(Web.File.stream(file), :skip_part))
    assert Web.FormData.get(form, "after") == "visible"
  end

  test "discard on cancel drains tracked sources and reaches subsequent fields" do
    boundary = "tracked-discard-boundary"

    payload =
      multipart_payload(boundary, [
        %{
          name: "upload",
          filename: "discard.txt",
          content_type: "text/plain",
          value: String.duplicate("b", 64)
        },
        %{name: "after", value: "visible"}
      ])

    {stream, _tracker} = tracked_source(byte_chunks(payload))
    form = Web.FormData.parse(stream, boundary)
    file = Web.FormData.get(form, "upload")

    assert :ok = await(ReadableStream.cancel(Web.File.stream(file), :skip_part))
    assert Web.FormData.get(form, "after") == "visible"
  end

  test "live coordinator has and get_all resolve both discovered and later fields" do
    boundary = "rpc-boundary"

    form =
      multipart_payload(boundary, [
        %{name: "first", value: "one"},
        %{name: "upload", filename: "rpc.txt", content_type: "text/plain", value: "payload"},
        %{name: "tail", value: "a"},
        %{name: "tail", value: "b"}
      ])
      |> Web.FormData.parse(boundary)

    assert is_pid(form.coordinator)
    assert Web.FormData.has?(form, "first") == true
    assert Web.FormData.has?(form, "upload") == true
    file = Web.FormData.get(form, "upload")

    later_values = Task.async(fn -> Web.FormData.get_all(form, "tail") end)

    assert Enum.join(Web.File.stream(file), "") == "payload"
    assert Task.await(later_values) == ["a", "b"]
  end

  test "malformed header recovery releases the upstream lock" do
    boundary = "recover-boundary"

    stream =
      ReadableStream.from([
        "--#{boundary}\r\n",
        "Content-Disposition: form-data; name=\"field\""
      ])

    assert_raise Web.TypeError, ~r/part headers are incomplete/, fn ->
      Web.FormData.parse(stream, boundary)
    end

    assert_eventually(fn -> ReadableStream.locked?(stream) == false end)
  end

  test "coordinator ignores unrelated messages when no signal subscription is active" do
    boundary = "ignore-message-boundary"
    file_body = String.duplicate("x", 128)

    {stream, _tracker} =
      boundary
      |> multipart_payload([
        %{name: "upload", filename: "x.txt", content_type: "text/plain", value: file_body},
        %{name: "after", value: "ok"}
      ])
      |> byte_chunks()
      |> tracked_source()

    form =
      Web.FormData.parse(stream, boundary)

    file = Web.FormData.get(form, "upload")

    send(form.coordinator, :unrelated_message)

    assert_eventually(fn -> Process.alive?(form.coordinator) end)
    assert Enum.join(Web.File.stream(file), "") == file_body
    assert Web.FormData.get(form, "after") == "ok"
  end

  test "coordinator ignores unrelated messages while a signal subscription is active" do
    boundary = "ignore-signal-message-boundary"
    controller = Web.AbortController.new()
    file_body = String.duplicate("x", 128)

    {stream, _tracker} =
      boundary
      |> multipart_payload([
        %{name: "upload", filename: "x.txt", content_type: "text/plain", value: file_body},
        %{name: "after", value: "ok"}
      ])
      |> byte_chunks()
      |> tracked_source()

    form =
      Web.FormData.parse(stream, boundary, signal: controller.signal)

    file = Web.FormData.get(form, "upload")

    send(form.coordinator, :unrelated_message)

    assert_eventually(fn -> Process.alive?(form.coordinator) end)
    assert Enum.join(Web.File.stream(file), "") == file_body
    assert Web.FormData.get(form, "after") == "ok"
  end

  test "false-positive boundary prefixes inside file contents are preserved" do
    boundary = "false-positive-boundary"
    file_body = "abc\r\n--#{boundary}Xstill-file"

    form =
      multipart_payload(boundary, [
        %{name: "upload", filename: "false.txt", content_type: "text/plain", value: file_body}
      ])
      |> Web.FormData.parse(boundary)

    file = Web.FormData.get(form, "upload")
    assert Enum.join(Web.File.stream(file), "") == file_body
  end

  test "quoted filename parameters unescape quoted-string escapes" do
    boundary = "quoted-name-boundary"

    form =
      multipart_payload(boundary, [
        %{
          name: "upload",
          value: "payload",
          disposition: "form-data; name=\"upload\"; filename=\"a\\\"b.txt\""
        }
      ])
      |> Web.FormData.parse(boundary)

    assert %Web.File{filename: "a\"b.txt"} = Web.FormData.get(form, "upload")
  end

  test "filename* decodes iso-8859-1 values" do
    boundary = "latin1-boundary"

    form =
      multipart_payload(boundary, [
        %{
          name: "upload",
          value: "payload",
          disposition: "form-data; name=\"upload\"; filename*=iso-8859-1''%A3rates.txt"
        }
      ])
      |> Web.FormData.parse(boundary)

    assert %Web.File{filename: "£rates.txt"} = Web.FormData.get(form, "upload")
  end

  test "filename* preserves invalid percent escapes" do
    boundary = "invalid-percent-boundary"

    form =
      multipart_payload(boundary, [
        %{
          name: "upload",
          value: "payload",
          disposition: "form-data; name=\"upload\"; filename*=utf-8''bad%ZZname.txt"
        }
      ])
      |> Web.FormData.parse(boundary)

    assert %Web.File{filename: "bad%ZZname.txt"} = Web.FormData.get(form, "upload")
  end

  test "malformed extended filename parameters fall back to regular decoding" do
    boundary = "extended-fallback-boundary"

    form =
      multipart_payload(boundary, [
        %{
          name: "upload",
          value: "payload",
          disposition: "form-data; name=\"upload\"; filename*=not-rfc5987"
        }
      ])
      |> Web.FormData.parse(boundary)

    assert %Web.File{filename: "not-rfc5987"} = Web.FormData.get(form, "upload")
  end

  test "filename* with an unknown charset falls back to decoded bytes" do
    boundary = "unknown-charset-boundary"

    form =
      multipart_payload(boundary, [
        %{
          name: "upload",
          value: "payload",
          disposition: "form-data; name=\"upload\"; filename*=x-custom''abc.txt"
        }
      ])
      |> Web.FormData.parse(boundary)

    assert %Web.File{filename: "abc.txt"} = Web.FormData.get(form, "upload")
  end

  test "filename* with an unknown charset preserves percent-decoded bytes" do
    boundary = "unknown-charset-percent-boundary"

    form =
      multipart_payload(boundary, [
        %{
          name: "upload",
          value: "payload",
          disposition: "form-data; name=\"upload\"; filename*=x-custom''ab%20cd.txt"
        }
      ])
      |> Web.FormData.parse(boundary)

    assert %Web.File{filename: "ab cd.txt"} = Web.FormData.get(form, "upload")
  end

  test "invalid multipart chunk types raise a type error" do
    stream = ReadableStream.from([123])

    assert_raise Web.TypeError, ~r/Multipart stream chunk must be binary/, fn ->
      Web.FormData.parse(stream, "chunks")
    end
  end

  test "multipart parser accepts scripted Uint8Array and iodata chunks" do
    boundary = "scripted-mixed-chunk-boundary"

    payload =
      multipart_payload(boundary, [
        %{name: "field", value: "value"}
      ])

    prefix = binary_part(payload, 0, 8)
    suffix = binary_part(payload, 8, byte_size(payload) - 8)
    uint8 = prefix |> Web.ArrayBuffer.new() |> Web.Uint8Array.new()

    stream = scripted_stream([{:ok, uint8}, {:ok, [suffix]}, :done])
    form = Web.FormData.parse(stream, boundary)

    assert Web.FormData.get(form, "field") == "value"
  end

  test "pre-aborted signals exit immediately without locking or reading the source" do
    {stream, tracker} = tracked_source(byte_chunks("ignored"))
    signal = Web.AbortSignal.abort(:already_aborted)
    pulls_before = stable_source_pulls(tracker)

    assert :already_aborted = catch_exit(Web.FormData.parse(stream, "x", signal: signal))
    assert stable_source_pulls(tracker) == pulls_before
    assert ReadableStream.locked?(stream) == false
  end

  test "tracked partial opening boundaries raise missing opening boundary at EOF" do
    {stream, _tracker} = tracked_source(["--sho"])

    assert_raise Web.TypeError, ~r/missing opening boundary/, fn ->
      Web.FormData.parse(stream, "short-boundary")
    end
  end

  test "invalid header lines raise a type error" do
    payload = "--bad-header\r\nOops\r\n\r\nvalue\r\n--bad-header--\r\n"

    assert_raise Web.TypeError, ~r/invalid header line/, fn ->
      Web.FormData.parse(payload, "bad-header")
    end
  end

  test "source errors while parsing headers propagate" do
    boundary = "header-error-boundary"

    stream =
      erroring_source(
        ["--#{boundary}\r\nContent-Disposition"],
        Web.TypeError.exception("header read failed")
      )

    assert_raise Web.TypeError, "header read failed", fn ->
      Web.FormData.parse(stream, boundary)
    end
  end

  test "generic source errors while parsing headers exit the caller" do
    boundary = "header-generic-error-boundary"

    stream =
      scripted_stream([
        {:ok, "--#{boundary}\r\nContent-Disposition"},
        {:error, :header_weird}
      ])

    assert :header_weird = catch_exit(Web.FormData.parse(stream, boundary))
  end

  test "missing content disposition raises a type error" do
    payload =
      "--missing-disposition\r\n" <>
        "Content-Type: text/plain\r\n\r\n" <>
        "value\r\n" <>
        "--missing-disposition--\r\n"

    assert_raise Web.TypeError, ~r/missing content-disposition/, fn ->
      Web.FormData.parse(payload, "missing-disposition")
    end
  end

  test "non form-data dispositions raise a type error" do
    payload =
      "--attachment-boundary\r\n" <>
        "Content-Disposition: attachment; name=\"file\"\r\n\r\n" <>
        "value\r\n" <>
        "--attachment-boundary--\r\n"

    assert_raise Web.TypeError, ~r/missing form-data disposition/, fn ->
      Web.FormData.parse(payload, "attachment-boundary")
    end
  end

  test "missing disposition names raise a type error" do
    payload =
      "--missing-name\r\n" <>
        "Content-Disposition: form-data; filename=\"x.txt\"\r\n\r\n" <>
        "value\r\n" <>
        "--missing-name--\r\n"

    assert_raise Web.TypeError, ~r/missing disposition name/, fn ->
      Web.FormData.parse(payload, "missing-name")
    end
  end

  test "empty disposition names raise a type error" do
    payload =
      "--empty-name\r\n" <>
        ~s(Content-Disposition: form-data; name=""; filename="x.txt"\r\n\r\n) <>
        "value\r\n" <>
        "--empty-name--\r\n"

    assert_raise Web.TypeError, ~r/missing disposition name/, fn ->
      Web.FormData.parse(payload, "empty-name")
    end
  end

  test "incomplete header blocks raise a type error" do
    payload = "--incomplete\r\nContent-Disposition: form-data; name=\"field\""

    assert_raise Web.TypeError, ~r/part headers are incomplete/, fn ->
      Web.FormData.parse(payload, "incomplete")
    end
  end

  test "missing closing boundaries raise a type error" do
    payload = "--unterminated\r\nContent-Disposition: form-data; name=\"field\"\r\n\r\nvalue"

    assert_raise Web.TypeError, ~r/missing closing boundary/, fn ->
      Web.FormData.parse(payload, "unterminated")
    end
  end

  test "source errors while parsing field bodies propagate" do
    boundary = "field-error-boundary"

    stream =
      erroring_source(
        ["--#{boundary}\r\nContent-Disposition: form-data; name=\"field\"\r\n\r\nvalue"],
        Web.TypeError.exception("field read failed")
      )

    assert_raise Web.TypeError, "field read failed", fn ->
      Web.FormData.parse(stream, boundary)
    end
  end

  test "long truncated field bodies raise missing closing boundary after emitting data" do
    boundary = "long-field-boundary"

    stream =
      scripted_stream([
        {:ok,
         "--#{boundary}\r\nContent-Disposition: form-data; name=\"field\"\r\n\r\n" <>
           String.duplicate("h", 128)},
        :done
      ])

    assert_raise Web.TypeError, ~r/missing closing boundary/, fn ->
      Web.FormData.parse(stream, boundary)
    end
  end

  test "generic source errors while parsing long field bodies exit the caller" do
    boundary = "field-generic-error-boundary"

    stream =
      scripted_stream([
        {:ok,
         "--#{boundary}\r\nContent-Disposition: form-data; name=\"field\"\r\n\r\n" <>
           String.duplicate("i", 128)},
        {:error, :field_weird}
      ])

    assert :field_weird = catch_exit(Web.FormData.parse(stream, boundary))
  end

  test "invalid opening boundaries raise a type error" do
    payload = "--opening-boundary\rBAD"

    assert_raise Web.TypeError, ~r/invalid opening boundary/, fn ->
      Web.FormData.parse(payload, "opening-boundary")
    end
  end

  test "already locked upstream streams raise a type error" do
    stream = ReadableStream.from("payload")
    reader = ReadableStream.get_reader(stream)

    assert_raise Web.TypeError, "ReadableStream is already locked", fn ->
      Web.FormData.parse(stream, "locked-boundary")
    end

    assert :ok = ReadableStreamDefaultReader.release_lock(reader)
  end

  test "pid signals abort the coordinator and child stream" do
    boundary = "pid-signal-boundary"

    signal_pid =
      spawn(fn ->
        receive do
        end
      end)

    file_body = String.duplicate("p", 128)

    {stream, _tracker} =
      boundary
      |> multipart_payload([
        %{name: "upload", filename: "x.txt", content_type: "text/plain", value: file_body}
      ])
      |> byte_chunks()
      |> tracked_source()

    form = Web.FormData.parse(stream, boundary, signal: signal_pid)

    stream = form |> Web.FormData.get("upload") |> Web.File.stream()
    Process.exit(signal_pid, :pid_signal_abort)

    assert_eventually(fn -> not Process.alive?(form.coordinator) end)
    assert_eventually(fn -> not Process.alive?(stream.controller_pid) end)
  end

  test "token signals abort the coordinator and child stream" do
    boundary = "token-signal-boundary"
    file_body = String.duplicate("p", 128)

    {stream, _tracker} =
      boundary
      |> multipart_payload([
        %{name: "upload", filename: "x.txt", content_type: "text/plain", value: file_body}
      ])
      |> byte_chunks()
      |> tracked_source()

    form = Web.FormData.parse(stream, boundary, signal: :token_signal)

    stream = form |> Web.FormData.get("upload") |> Web.File.stream()
    send(form.coordinator, {:abort, :token_signal, :token_abort})

    assert_eventually(fn -> not Process.alive?(form.coordinator) end)
    assert_eventually(fn -> not Process.alive?(stream.controller_pid) end)
  end

  test "abort signals cancel child streams and upstream" do
    boundary = "signal-boundary"
    controller = Web.AbortController.new()
    file_body = String.duplicate("p", 128)

    {stream, tracker} =
      boundary
      |> multipart_payload([
        %{name: "upload", filename: "x.txt", content_type: "text/plain", value: file_body}
      ])
      |> byte_chunks()
      |> tracked_source()

    form = Web.FormData.parse(stream, boundary, signal: controller.signal)

    stream = form |> Web.FormData.get("upload") |> Web.File.stream()
    assert :ok = Web.AbortController.abort(controller, :signal_abort)
    assert_eventually(fn -> source_cancel_reason(tracker) == :signal_abort end)
    assert_eventually(fn -> not Process.alive?(form.coordinator) end)
    assert_eventually(fn -> not Process.alive?(stream.controller_pid) end)
  end

  test "ambient abort signals cancel the coordinator, child stream, and upstream" do
    boundary = "ambient-signal-boundary"
    controller = AbortController.new()
    file_body = String.duplicate("p", 128)
    key = AsyncContext.ambient_signal_key()
    previous = Process.get(key)

    {stream, tracker} =
      boundary
      |> multipart_payload([
        %{name: "upload", filename: "x.txt", content_type: "text/plain", value: file_body}
      ])
      |> byte_chunks()
      |> tracked_source()

    form =
      try do
        Process.put(key, controller.signal)
        Web.FormData.parse(stream, boundary)
      after
        restore_ambient_signal(key, previous)
      end

    file_stream = form |> Web.FormData.get("upload") |> Web.File.stream()

    assert :ok = AbortController.abort(controller, :ambient_abort)
    assert_eventually(fn -> source_cancel_reason(tracker) == :ambient_abort end)
    assert_eventually(fn -> not Process.alive?(form.coordinator) end)
    assert_eventually(fn -> not Process.alive?(file_stream.controller_pid) end)
  end

  test "multiple signal subscriptions ignore unrelated messages and honor explicit abort" do
    boundary = "multi-signal-ignore-boundary"
    explicit = AbortController.new()
    ambient = AbortController.new()
    file_body = String.duplicate("p", 128)
    key = AsyncContext.ambient_signal_key()
    previous = Process.get(key)

    {stream, tracker} =
      boundary
      |> multipart_payload([
        %{name: "upload", filename: "x.txt", content_type: "text/plain", value: file_body}
      ])
      |> byte_chunks()
      |> tracked_source()

    form =
      try do
        Process.put(key, ambient.signal)
        Web.FormData.parse(stream, boundary, signal: explicit.signal)
      after
        restore_ambient_signal(key, previous)
      end

    file_stream = form |> Web.FormData.get("upload") |> Web.File.stream()

    send(form.coordinator, {:unrelated, :message})
    Process.sleep(50)
    assert Process.alive?(form.coordinator)

    assert :ok = AbortController.abort(explicit, :explicit_abort)
    assert_eventually(fn -> source_cancel_reason(tracker) == :explicit_abort end)
    assert_eventually(fn -> not Process.alive?(form.coordinator) end)
    assert_eventually(fn -> not Process.alive?(file_stream.controller_pid) end)
    _ = AbortController.abort(ambient, :cleanup)
  end

  test "already-aborted explicit signal short-circuits when multiple signals are bound" do
    boundary = "multi-signal-aborted-boundary"
    ambient = AbortController.new()
    explicit = Web.AbortSignal.abort(:already_aborted)
    key = AsyncContext.ambient_signal_key()
    previous = Process.get(key)

    payload =
      multipart_payload(boundary, [
        %{name: "meta", value: "value"}
      ])

    try do
      Process.put(key, ambient.signal)

      assert catch_exit(Web.FormData.parse(payload, boundary, signal: explicit)) ==
               :already_aborted
    after
      restore_ambient_signal(key, previous)
    end

    _ = AbortController.abort(ambient, :cleanup)
  end

  test "token signals without an explicit reason default to aborted" do
    boundary = "token-default-boundary"
    file_body = String.duplicate("p", 128)

    {stream, _tracker} =
      boundary
      |> multipart_payload([
        %{name: "upload", filename: "x.txt", content_type: "text/plain", value: file_body}
      ])
      |> byte_chunks()
      |> tracked_source()

    form = Web.FormData.parse(stream, boundary, signal: :token_default_signal)

    stream = form |> Web.FormData.get("upload") |> Web.File.stream()
    send(form.coordinator, {:abort, :token_default_signal})

    assert_eventually(fn -> not Process.alive?(form.coordinator) end)
    assert_eventually(fn -> not Process.alive?(stream.controller_pid) end)
  end

  test "abort signal process exits abort the coordinator" do
    boundary = "abort-signal-down-boundary"
    controller = Web.AbortController.new()
    file_body = String.duplicate("p", 128)

    {stream, _tracker} =
      boundary
      |> multipart_payload([
        %{name: "upload", filename: "x.txt", content_type: "text/plain", value: file_body}
      ])
      |> byte_chunks()
      |> tracked_source()

    form = Web.FormData.parse(stream, boundary, signal: controller.signal)

    stream = form |> Web.FormData.get("upload") |> Web.File.stream()
    Process.exit(controller.signal.pid, :signal_process_down)

    assert_eventually(fn -> not Process.alive?(form.coordinator) end)
    assert_eventually(fn -> not Process.alive?(stream.controller_pid) end)
  end

  test "abort signal shutdown tuples abort the coordinator" do
    boundary = "abort-signal-shutdown-boundary"
    controller = Web.AbortController.new()
    file_body = String.duplicate("p", 128)

    {stream, _tracker} =
      boundary
      |> multipart_payload([
        %{name: "upload", filename: "x.txt", content_type: "text/plain", value: file_body}
      ])
      |> byte_chunks()
      |> tracked_source()

    form = Web.FormData.parse(stream, boundary, signal: controller.signal)

    stream = form |> Web.FormData.get("upload") |> Web.File.stream()
    Process.exit(controller.signal.pid, {:shutdown, {:aborted, :signal_shutdown}})

    assert_eventually(fn -> not Process.alive?(form.coordinator) end)
    assert_eventually(fn -> not Process.alive?(stream.controller_pid) end)
  end

  test "pending waiters receive closing-boundary errors when a cancelled file must be discarded" do
    boundary = "pending-discard-boundary"
    file_body = String.duplicate("a", 128)

    payload =
      "--#{boundary}\r\n" <>
        ~s(Content-Disposition: form-data; name="upload"; filename="bad.txt"\r\n) <>
        "Content-Type: text/plain\r\n\r\n" <>
        file_body

    {stream, _tracker} = tracked_source(byte_chunks(payload))
    form = Web.FormData.parse(stream, boundary)

    file = Web.FormData.get(form, "upload")

    waiter =
      Task.async(fn ->
        try do
          {:ok, Web.FormData.get(form, "after")}
        rescue
          e in Web.TypeError -> {:error, e}
        end
      end)

    Process.sleep(50)
    assert Task.yield(waiter, 0) == nil

    assert :ok = await(ReadableStream.cancel(Web.File.stream(file), :skip_part))

    assert {:error, %Web.TypeError{message: message}} = Task.await(waiter)
    assert message =~ "missing closing boundary"
    assert_eventually(fn -> not Process.alive?(form.coordinator) end)
  end

  test "pending waiters receive header errors after a file completes into malformed trailing parts" do
    boundary = "pending-header-boundary"

    payload =
      "--#{boundary}\r\n" <>
        ~s(Content-Disposition: form-data; name="upload"; filename="bad.txt"\r\n) <>
        "Content-Type: text/plain\r\n\r\n" <>
        "payload\r\n" <>
        "--#{boundary}\r\n" <>
        ~s(Content-Disposition: form-data; name="after")

    {stream, _tracker} = tracked_source(byte_chunks(payload))
    form = Web.FormData.parse(stream, boundary)
    file = Web.FormData.get(form, "upload")

    waiter =
      Task.async(fn ->
        try do
          {:ok, Web.FormData.get(form, "after")}
        rescue
          e in Web.TypeError -> {:error, e}
        end
      end)

    Process.sleep(50)
    assert Task.yield(waiter, 0) == nil
    assert Enum.join(Web.File.stream(file), "") == "payload"

    assert {:error, %Web.TypeError{message: message}} = Task.await(waiter)
    assert message =~ "part headers are incomplete"
    assert_eventually(fn -> not Process.alive?(form.coordinator) end)
  end

  test "reading a malformed truncated file errors the child stream" do
    boundary = "truncated-file-boundary"
    file_body = String.duplicate("c", 128)

    payload =
      "--#{boundary}\r\n" <>
        ~s(Content-Disposition: form-data; name="upload"; filename="bad.txt"\r\n) <>
        "Content-Type: text/plain\r\n\r\n" <>
        file_body

    {stream, _tracker} = tracked_source(byte_chunks(payload))
    form = Web.FormData.parse(stream, boundary)
    file = Web.FormData.get(form, "upload")

    result =
      Task.async(fn ->
        catch_exit(Enum.join(Web.File.stream(file), ""))
      end)
      |> Task.await()

    case result do
      {{:shutdown, %Web.TypeError{message: message}}, _} ->
        assert message =~ "missing closing boundary"

      {:noproc, _} ->
        assert true
    end

    assert_eventually(fn -> not Process.alive?(form.coordinator) end)
  end

  test "source errors while reading file bodies propagate to file readers" do
    boundary = "file-error-boundary"
    file_body = String.duplicate("e", 128)

    payload =
      "--#{boundary}\r\n" <>
        ~s(Content-Disposition: form-data; name="upload"; filename="bad.txt"\r\n) <>
        "Content-Type: text/plain\r\n\r\n" <>
        file_body

    {stream, _tracker} = tracked_source(byte_chunks(payload))
    form = Web.FormData.parse(stream, boundary)
    file = Web.FormData.get(form, "upload")
    ReadableStream.error(stream.controller_pid, Web.TypeError.exception("file read failed"))

    result =
      Task.async(fn ->
        try do
          {:ok, Enum.join(Web.File.stream(file), "")}
        rescue
          e in Web.TypeError -> {:error, e}
        catch
          :exit, reason -> {:exit, reason}
        end
      end)
      |> Task.await()

    assert match?({:error, %Web.TypeError{message: "The stream is errored."}}, result) or
             match?(
               {:exit, {{:shutdown, %Web.TypeError{message: "file read failed"}}, _}},
               result
             ) or
             match?({:exit, {:noproc, _}}, result)

    assert_eventually(fn -> not Process.alive?(form.coordinator) end)
  end

  test "source errors while discarding a cancelled file propagate to pending waiters" do
    boundary = "discard-error-boundary"
    file_body = String.duplicate("f", 128)

    payload =
      "--#{boundary}\r\n" <>
        ~s(Content-Disposition: form-data; name="upload"; filename="bad.txt"\r\n) <>
        "Content-Type: text/plain\r\n\r\n" <>
        file_body

    {stream, _tracker} = tracked_source(byte_chunks(payload))
    form = Web.FormData.parse(stream, boundary)
    file = Web.FormData.get(form, "upload")

    waiter =
      Task.async(fn ->
        try do
          {:ok, Web.FormData.get(form, "after")}
        rescue
          e in Web.TypeError -> {:error, e}
        end
      end)

    Process.sleep(50)
    assert Task.yield(waiter, 0) == nil
    ReadableStream.error(stream.controller_pid, Web.TypeError.exception("discard read failed"))
    assert :ok = await(ReadableStream.cancel(Web.File.stream(file), :skip_part))
    assert {:error, %Web.TypeError{message: "discard read failed"}} = Task.await(waiter)
  end

  test "calling a dead coordinator exits the caller" do
    boundary = "dead-coordinator-boundary"

    form =
      multipart_payload(boundary, [
        %{name: "field", value: "ok"}
      ])
      |> Web.FormData.parse(boundary)

    assert :ok = Web.FormData.cancel(form, :normal)
    assert {:noproc, _} = catch_exit(Web.FormData.get(form, "field"))
  end

  test "cancel with nil or normal reason does not cancel the upstream source" do
    boundary = "nil-normal-cancel-boundary"

    payload =
      multipart_payload(boundary, [
        %{
          name: "upload",
          filename: "cancel.txt",
          content_type: "text/plain",
          value: String.duplicate("d", 64)
        }
      ])

    {stream_a, tracker_a} = tracked_source(byte_chunks(payload))
    form_a = Web.FormData.parse(stream_a, boundary)
    _file_a = Web.FormData.get(form_a, "upload")

    assert :ok = Web.FormData.cancel(form_a, nil)
    assert source_cancel_reason(tracker_a) == nil
    assert_eventually(fn -> not Process.alive?(form_a.coordinator) end)

    {stream_b, tracker_b} = tracked_source(byte_chunks(payload))
    form_b = Web.FormData.parse(stream_b, boundary)
    _file_b = Web.FormData.get(form_b, "upload")

    assert :ok = Web.FormData.cancel(form_b, :normal)
    assert source_cancel_reason(tracker_b) == nil
    assert_eventually(fn -> not Process.alive?(form_b.coordinator) end)
  end

  test "parser child_pull closes controllers for stale and discarded pulls" do
    boundary = "child-pull-close-boundary"

    form =
      multipart_payload(boundary, [
        %{
          name: "upload",
          filename: "x.txt",
          content_type: "text/plain",
          value: String.duplicate("g", 64)
        }
      ])
      |> Web.FormData.parse(boundary)

    _file = Web.FormData.get(form, "upload")

    stale_stream = ReadableStream.new()
    stale_reader = ReadableStream.get_reader(stale_stream)

    assert :ok =
             Web.FormData.Parser.child_pull(
               form.coordinator,
               999,
               %Web.ReadableStreamDefaultController{pid: stale_stream.controller_pid}
             )

    assert :done = ReadableStream.read(stale_stream.controller_pid)
    assert :ok = ReadableStreamDefaultReader.release_lock(stale_reader)

    discarded_stream = ReadableStream.new()
    discarded_reader = ReadableStream.get_reader(discarded_stream)

    assert :ok = Web.FormData.Parser.child_cancel(form.coordinator, 1, :skip_part)

    assert :ok =
             Web.FormData.Parser.child_pull(
               form.coordinator,
               1,
               %Web.ReadableStreamDefaultController{pid: discarded_stream.controller_pid}
             )

    assert :done = ReadableStream.read(discarded_stream.controller_pid)
    assert :ok = ReadableStreamDefaultReader.release_lock(discarded_reader)
  end

  test "parser child_pull closes controllers after parsing is already done" do
    boundary = "child-pull-done-boundary"

    form =
      multipart_payload(boundary, [
        %{name: "field", value: "ok"}
      ])
      |> Web.FormData.parse(boundary)

    closed_stream = ReadableStream.new()
    closed_reader = ReadableStream.get_reader(closed_stream)

    assert :ok =
             Web.FormData.Parser.child_pull(
               form.coordinator,
               1,
               %Web.ReadableStreamDefaultController{pid: closed_stream.controller_pid}
             )

    assert :done = ReadableStream.read(closed_stream.controller_pid)
    assert :ok = ReadableStreamDefaultReader.release_lock(closed_reader)

    # Also cover the dead-coordinator path: child_pull must close the controller
    # to avoid resource leaks even when the coordinator is already gone.
    Web.FormData.cancel(form, :done)

    assert_eventually(fn -> not Process.alive?(form.coordinator) end)

    dead_stream = ReadableStream.new()
    dead_reader = ReadableStream.get_reader(dead_stream)

    assert :ok =
             Web.FormData.Parser.child_pull(
               form.coordinator,
               1,
               %Web.ReadableStreamDefaultController{pid: dead_stream.controller_pid}
             )

    assert :done = ReadableStream.read(dead_stream.controller_pid)
    assert :ok = ReadableStreamDefaultReader.release_lock(dead_reader)
  end

  test "parser child_pull closes controllers for explicitly discarded active files" do
    boundary = "child-pull-discard-boundary"

    payload =
      multipart_payload(boundary, [
        %{
          name: "upload",
          filename: "x.txt",
          content_type: "text/plain",
          value: String.duplicate("z", 64)
        }
      ])

    {stream, _tracker} = tracked_source(byte_chunks(payload))
    form = Web.FormData.parse(stream, boundary)
    _file = Web.FormData.get(form, "upload")

    closed_stream = ReadableStream.new()
    closed_reader = ReadableStream.get_reader(closed_stream)

    assert :ok = Web.FormData.Parser.child_cancel(form.coordinator, 1, :skip_part)

    assert :ok =
             Web.FormData.Parser.child_pull(
               form.coordinator,
               1,
               %Web.ReadableStreamDefaultController{pid: closed_stream.controller_pid}
             )

    assert :done = ReadableStream.read(closed_stream.controller_pid)
    assert :ok = ReadableStreamDefaultReader.release_lock(closed_reader)
  end

  test "parser child_pull closes controllers when the coordinator is forced into discard mode" do
    boundary = "forced-discard-branch-boundary"

    payload =
      multipart_payload(boundary, [
        %{
          name: "upload",
          filename: "x.txt",
          content_type: "text/plain",
          value: String.duplicate("y", 64)
        }
      ])

    {stream, _tracker} = tracked_source(byte_chunks(payload))
    form = Web.FormData.parse(stream, boundary)

    _file = Web.FormData.get(form, "upload")

    :sys.replace_state(form.coordinator, fn {:running, data} ->
      {:running, put_in(data.current_file.mode, :discard)}
    end)

    closed_stream = ReadableStream.new()
    closed_reader = ReadableStream.get_reader(closed_stream)

    assert :ok =
             Web.FormData.Parser.child_pull(
               form.coordinator,
               1,
               %Web.ReadableStreamDefaultController{pid: closed_stream.controller_pid}
             )

    assert :done = ReadableStream.read(closed_stream.controller_pid)
    assert :ok = ReadableStreamDefaultReader.release_lock(closed_reader)
  end

  test "parser helper calls exit on shutdown and generic call failures" do
    shutdown_pid = crash_on_call({:shutdown, :call_failed})
    generic_pid = crash_on_call(:call_failed)

    assert :call_failed = catch_exit(Web.FormData.Parser.get(shutdown_pid, "field"))
    assert {:call_failed, _} = catch_exit(Web.FormData.Parser.get(generic_pid, "field"))
  end

  test "parser helper calls exit when a gen_statem shuts down during the call" do
    {:ok, pid} = ShutdownCallMachine.start_link()

    assert :call_failed = catch_exit(Web.FormData.Parser.get(pid, "field"))
  end

  test "parser helper catches bare shutdown exits from linked gen_statem calls" do
    parent = self()

    spawn(fn ->
      Process.flag(:trap_exit, true)
      {:ok, pid} = :gen_statem.start_link(ShutdownCallMachine, :ok, [])
      send(parent, {:linked_shutdown_result, catch_exit(Web.FormData.Parser.get(pid, "field"))})
    end)

    assert_receive {:linked_shutdown_result, :call_failed}
  end

  test "parse exits when the source controller crashes during reader acquisition" do
    stream = %ReadableStream{controller_pid: crash_on_call(:reader_crash)}

    assert {:reader_crash, _} = catch_exit(Web.FormData.parse(stream, "reader-crash-boundary"))
  end

  test "parser terminate normalizes normal and custom stop reasons" do
    data = %{
      signal_subscription: nil,
      current_file: nil,
      source_lock_released?: true,
      source_pid: self()
    }

    assert :ok = Web.FormData.Parser.terminate(:normal, :running, data)
    assert :ok = Web.FormData.Parser.terminate(:custom_stop, :running, data)
  end

  property "parses randomized chunked multipart text payloads" do
    check all(
            first <- string(:alphanumeric, min_length: 1, max_length: 32),
            second <- string(:alphanumeric, min_length: 1, max_length: 32),
            chunk_sizes <- list_of(integer(1..9), min_length: 1, max_length: 12)
          ) do
      boundary = "----prop-boundary"

      payload =
        multipart_payload(boundary, [
          %{name: "a", value: first},
          %{name: "b", value: second}
        ])

      stream = payload |> chunk_binary(chunk_sizes) |> ReadableStream.from()
      form_data = Web.FormData.parse(stream, boundary)

      assert Web.FormData.get(form_data, "a") == first
      assert Web.FormData.get(form_data, "b") == second
    end
  end

  test "boundary split exactly across chunks parses correctly" do
    boundary = "split-boundary"

    payload =
      multipart_payload(boundary, [
        %{name: "k", value: "v"}
      ])

    marker = "--" <> boundary <> "\r\n"
    split_at = byte_size(marker) - 1

    <<left::binary-size(split_at), right::binary>> = payload
    stream = ReadableStream.from([left, right])

    parsed = Web.FormData.parse(stream, boundary)
    assert Web.FormData.get(parsed, "k") == "v"
  end

  test "all one-byte chunks preserve file routing and trailing field discovery" do
    boundary = "one-byte-boundary"

    payload =
      "--#{boundary}\r\n" <>
        ~s(Content-Disposition: form-data; name="upload"; filename="tiny.txt"\r\n) <>
        "Content-Type: text/plain\r\n\r\n" <>
        "abc\r\n" <>
        "--#{boundary}\r\n" <>
        ~s(Content-Disposition: form-data; name="after"\r\n\r\n) <>
        "done\r\n" <>
        "--#{boundary}--\r\n"

    parsed = Web.FormData.parse(ReadableStream.from(byte_chunks(payload)), boundary)

    assert %Web.File{filename: "tiny.txt"} = file = Web.FormData.get(parsed, "upload")
    assert Enum.join(Web.File.stream(file), "") == "abc"
    assert Web.FormData.get(parsed, "after") == "done"
  end

  property "micro chunker preserves 10KB file payloads one byte at a time" do
    check all(payload <- string(:alphanumeric, length: 10_240), max_runs: 5) do
      boundary = "micro-boundary"

      multipart =
        multipart_payload(boundary, [
          %{name: "upload", filename: "tenk.txt", content_type: "text/plain", value: payload},
          %{name: "tail", value: "ok"}
        ])

      form = Web.FormData.parse(ReadableStream.from(byte_chunks(multipart)), boundary)
      file = Web.FormData.get(form, "upload")

      assert Enum.join(Web.File.stream(file), "") == payload
      assert Web.FormData.get(form, "tail") == "ok"
    end
  end

  test "multipart parser implementation is no longer public" do
    assert Code.ensure_loaded?(Web.Multipart.Parser) == false
  end

  # ---------------------------------------------------------------------------
  # Enumerable protocol coverage
  # ---------------------------------------------------------------------------

  test "Enumerable count and member? on static form fall back to linear scan" do
    form =
      Web.FormData.new()
      |> Web.FormData.append("a", "1")
      |> Web.FormData.append("b", "2")

    # These call Enumerable.count/1 and Enumerable.member?/2 which return
    # {:error, __MODULE__}, causing Enum to fall back to reduce-based counting.
    assert Enum.count(form) == 2
    assert Enum.member?(form, ["a", "1"]) == true
    assert Enum.member?(form, ["missing", "x"]) == false
    # Enum.slice uses Enumerable.slice/1 → {:error, __MODULE__} → linear fallback
    assert Enum.slice(form, 0, 1) == [["a", "1"]]
  end

  test "Enumerable iterate static form via Enum.to_list" do
    form =
      Web.FormData.new()
      |> Web.FormData.append("x", "hello")
      |> Web.FormData.append("y", "world")

    assert Enum.to_list(form) == [["x", "hello"], ["y", "world"]]
  end

  test "Enumerable early termination (halt) on live form via Enum.take" do
    boundary = "enum-take-boundary"

    form =
      multipart_payload(boundary, [
        %{name: "a", value: "1"},
        %{name: "b", value: "2"},
        %{name: "c", value: "3"}
      ])
      |> Web.FormData.parse(boundary)

    assert Enum.take(form, 1) == [["a", "1"]]

    Web.FormData.cancel(form)
  end

  test "Enumerable suspend path on live form via Stream.zip" do
    boundary = "stream-zip-boundary"

    form =
      multipart_payload(boundary, [
        %{name: "a", value: "1"},
        %{name: "b", value: "2"}
      ])
      |> Web.FormData.parse(boundary)

    # Stream.zip triggers the {:suspend, acc} path in Enumerable.reduce/3
    # as it interleaves two producers.
    result = Stream.zip(form, [:x, :y]) |> Enum.to_list()
    assert result == [{["a", "1"], :x}, {["b", "2"], :y}]

    Web.FormData.cancel(form)
  end

  test "Collectable builds static forms from tuple and list entries" do
    form =
      Enum.into(
        [{"a", "1"}, ["b", "2"]],
        Web.FormData.new(boundary: "collect-static-boundary")
      )

    assert Web.FormData.get(form, "a") == "1"
    assert Web.FormData.get(form, "b") == "2"
  end

  test "Collectable materializes live forms on completion" do
    boundary = "collect-live-boundary"

    live_form =
      multipart_payload(boundary, [
        %{name: "existing", value: "1"}
      ])
      |> Web.FormData.parse(boundary)

    collected = Enum.into([{"added", "2"}], live_form)

    assert collected.coordinator == nil
    assert Web.FormData.get(collected, "existing") == "1"
    assert Web.FormData.get(collected, "added") == "2"
  end

  test "Collectable raises on invalid entries and halts cleanly on upstream errors" do
    assert_raise ArgumentError,
                 ~r/Web\.FormData collectable expects \{name, value\} or \[name, value\]/,
                 fn ->
                   Enum.into([:bad], Web.FormData.new())
                 end

    stream =
      Stream.concat(
        [{"ok", "1"}],
        Stream.map([:boom], fn _ -> raise "collectable source failed" end)
      )

    assert_raise RuntimeError, "collectable source failed", fn ->
      Enum.into(stream, Web.FormData.new())
    end
  end

  test "Parser.entries/1 materializes live forms and serves concurrent callers" do
    boundary = "parser-entries-boundary"

    payload =
      multipart_payload(boundary, [
        %{name: "field", value: "1"},
        %{name: "upload", filename: "file.txt", content_type: "text/plain", value: "payload"},
        %{name: "after", value: "done"}
      ])

    split_marker = "--#{boundary}\r\nContent-Disposition: form-data; name=\"upload\""
    {split_at, _} = :binary.match(payload, split_marker)
    first_chunk = binary_part(payload, 0, split_at)
    second_chunk = binary_part(payload, split_at, byte_size(payload) - split_at)

    parent = self()
    {:ok, pull_state} = Agent.start_link(fn -> :blocked end)

    stream =
      ReadableStream.new(%{
        start: fn controller ->
          Web.ReadableStreamDefaultController.enqueue(controller, first_chunk)
        end,
        pull: fn controller ->
          case Agent.get_and_update(pull_state, fn
                 :blocked -> {:blocked, :released}
                 :released -> {:released, :done}
                 :done -> {:done, :done}
               end) do
            :blocked ->
              send(parent, :parser_entries_pull)
              Process.sleep(100)
              Web.ReadableStreamDefaultController.enqueue(controller, second_chunk)

            :released ->
              Web.ReadableStreamDefaultController.close(controller)

            :done ->
              Web.ReadableStreamDefaultController.close(controller)
          end
        end
      })

    form = Web.FormData.parse(stream, boundary)

    waiter = Task.async(fn -> Web.FormData.Parser.entries(form.coordinator) end)
    assert_receive :parser_entries_pull

    concurrent_waiter = Task.async(fn -> Web.FormData.Parser.entries(form.coordinator) end)
    Process.sleep(10)
    entries = Web.FormData.Parser.entries(form.coordinator)

    assert [
             {"field", "1"},
             {"upload", %Web.File{filename: "file.txt", stream: nil}},
             {"after", "done"}
           ] = Task.await(waiter)

    assert [
             {"field", "1"},
             {"upload", %Web.File{filename: "file.txt", stream: nil}},
             {"after", "done"}
           ] = Task.await(concurrent_waiter)

    assert [
             {"field", "1"},
             {"upload", %Web.File{filename: "file.txt", stream: nil}},
             {"after", "done"}
           ] =
             entries
  end

  test "drain_live with undiscovered file part covers materializing-mode header parse" do
    boundary = "drain-undiscovered-file-boundary"

    # After parse, coordinator is at :headers for "upload" (field1 triggered ready?).
    # Calling append without reading the file first triggers begin_materialization
    # while the file headers haven't been processed yet, which runs consume_headers
    # with materializing? = true (L677-686 + L604).
    form =
      multipart_payload(boundary, [
        %{name: "field1", value: "val1"},
        %{name: "upload", filename: "f.txt", content_type: "text/plain", value: "file-content"},
        %{name: "after", value: "done"}
      ])
      |> Web.FormData.parse(boundary)

    appended = Web.FormData.append(form, "extra", "extra_val")

    assert Web.FormData.get(appended, "field1") == "val1"
    assert Web.FormData.get(appended, "after") == "done"
    assert Web.FormData.get(appended, "extra") == "extra_val"
    # File is materialized with stream: nil (freeze_file materializing? = true, L1132)
    assert %Web.File{filename: "f.txt", stream: nil} = Web.FormData.get(appended, "upload")
  end

  test "Enumerable top-level halt and suspend pass-through on live form" do
    boundary = "enum-passthrough-boundary"

    form =
      multipart_payload(boundary, [%{name: "a", value: "1"}, %{name: "b", value: "2"}])
      |> Web.FormData.parse(boundary)

    # Top-level halt pass-through: required by the Enumerable protocol contract
    assert {:halted, :sentinel} =
             Enumerable.reduce(form, {:halt, :sentinel}, fn _, acc -> {:cont, acc} end)

    # Top-level suspend pass-through: used by Stream.zip / Stream.resource internals
    {:suspended, :sentinel, cont} =
      Enumerable.reduce(form, {:suspend, :sentinel}, fn _, acc -> {:cont, acc} end)

    # Resuming from suspended state completes normally
    {:done, _} = cont.({:cont, :sentinel})

    Web.FormData.cancel(form)
  end

  test "drain_live with two file parts covers materializing-mode header parse" do
    boundary = "drain-two-files-boundary"

    form =
      multipart_payload(boundary, [
        %{name: "file1", filename: "f1.txt", content_type: "text/plain", value: "content1"},
        %{name: "file2", filename: "f2.txt", content_type: "text/plain", value: "content2"},
        %{name: "after", value: "done"}
      ])
      |> Web.FormData.parse(boundary)

    # Park coordinator in :file, mode: :await_pull for file1
    _file = Web.FormData.get(form, "file1")

    # drain: begin_materialization discards file1 stream (L901-902),
    # discard_file_body advances to file2's headers,
    # consume_headers with materializing?=true runs L675-684 (discard mode file),
    # advance sees :file :discard for file2 (L602), discards file2, finds "after".
    result = Web.FormData.append(form, "extra", "val")

    assert Web.FormData.get(result, "after") == "done"
    assert Web.FormData.get(result, "extra") == "val"
    # Files are frozen with stream: nil (L1132) when materialized
    assert %Web.File{filename: "f1.txt", stream: nil} = Web.FormData.get(result, "file1")
    assert %Web.File{filename: "f2.txt", stream: nil} = Web.FormData.get(result, "file2")
  end

  test "drain_live on truncated file propagates upstream error (L418)" do
    boundary = "drain-error-boundary"

    truncated_payload =
      "--#{boundary}\r\n" <>
        ~s(Content-Disposition: form-data; name="upload"; filename="trunc.bin"\r\n) <>
        "Content-Type: application/octet-stream\r\n\r\n" <>
        String.duplicate("e", 64)

    form = Web.FormData.parse(truncated_payload, boundary)
    assert Process.alive?(form.coordinator)

    # Mutation triggers drain_live → Parser.materialize → hits EOF during file drain
    assert_raise Web.TypeError, ~r/missing closing boundary/, fn ->
      Web.FormData.append(form, "extra", "value")
    end
  end

  # ---------------------------------------------------------------------------
  # Micro-chunker stress tests (property-based)
  #
  # Feed valid multipart data one byte at a time, then verify Enumerable
  # iteration produces results identical to the source. This exercises every
  # possible split position for the sliding-window boundary scanner.
  # ---------------------------------------------------------------------------

  property "byte-by-byte field parsing: Enum.to_list matches source exactly" do
    check all(
            fields <-
              list_of(
                tuple(
                  {string(:alphanumeric, min_length: 1, max_length: 20),
                   string(:alphanumeric, min_length: 0, max_length: 50)}
                ),
                max_length: 8
              ),
            max_runs: 100
          ) do
      boundary = "prop-boundary"
      parts = Enum.map(fields, fn {name, value} -> %{name: name, value: value} end)
      payload = multipart_payload(boundary, parts)

      form =
        payload
        |> byte_chunks()
        |> ReadableStream.from()
        |> Web.FormData.parse(boundary)

      result = Enum.to_list(form)
      Web.FormData.cancel(form)

      expected = Enum.map(fields, fn {name, value} -> [name, value] end)
      assert result == expected
    end
  end

  property "byte-by-byte file parsing: inline stream reading matches source" do
    check all(
            files <-
              list_of(
                tuple(
                  {string(:alphanumeric, min_length: 1, max_length: 10),
                   string(:alphanumeric, min_length: 1, max_length: 10),
                   string(:alphanumeric, min_length: 0, max_length: 100)}
                ),
                max_length: 4
              ),
            max_runs: 50
          ) do
      boundary = "prop-file-boundary"

      parts =
        Enum.map(files, fn {name, filename, content} ->
          %{name: name, filename: filename, content_type: "text/plain", value: content}
        end)

      payload = multipart_payload(boundary, parts)

      form =
        payload
        |> byte_chunks()
        |> ReadableStream.from()
        |> Web.FormData.parse(boundary)

      # Read each file's stream inline during iteration, before requesting
      # the next entry. This matches the correct streaming usage pattern.
      result =
        Enum.reduce(form, [], fn [name, value], acc ->
          content = value |> Web.File.stream() |> Enum.join("")
          acc ++ [{name, content}]
        end)

      Web.FormData.cancel(form)

      expected = Enum.map(files, fn {name, _filename, content} -> {name, content} end)
      assert result == expected
    end
  end

  defp multipart_payload(boundary, parts) do
    body =
      Enum.map(parts, fn part ->
        disposition =
          case part do
            %{disposition: disposition} ->
              "Content-Disposition: #{disposition}\r\n"

            %{filename: filename} ->
              "Content-Disposition: form-data; name=\"#{part.name}\"; filename=\"#{filename}\"\r\n"

            _ ->
              "Content-Disposition: form-data; name=\"#{part.name}\"\r\n"
          end

        type_line =
          case part do
            %{content_type: type} -> "Content-Type: #{type}\r\n"
            _ -> ""
          end

        "--#{boundary}\r\n" <> disposition <> type_line <> "\r\n" <> part.value <> "\r\n"
      end)
      |> IO.iodata_to_binary()

    body <> "--#{boundary}--\r\n"
  end

  defp chunk_binary(binary, sizes) do
    do_chunk_binary(binary, sizes, sizes, [])
  end

  defp do_chunk_binary(<<>>, _sizes, _original_sizes, acc), do: Enum.reverse(acc)

  defp do_chunk_binary(binary, [], original_sizes, acc) do
    do_chunk_binary(binary, original_sizes, original_sizes, acc)
  end

  defp do_chunk_binary(binary, [size | rest_sizes], original_sizes, acc) do
    current_size = min(size, byte_size(binary))
    <<chunk::binary-size(current_size), rest::binary>> = binary
    do_chunk_binary(rest, rest_sizes, original_sizes, [chunk | acc])
  end

  defp byte_chunks(binary) do
    for <<byte <- binary>>, do: <<byte>>
  end

  defp erroring_source(chunks_before_error, reason) do
    ReadableStream.new(%{
      start: fn controller ->
        Enum.each(chunks_before_error, fn chunk ->
          Web.ReadableStreamDefaultController.enqueue(controller, chunk)
        end)

        Web.ReadableStreamDefaultController.error(controller, reason)
      end
    })
  end

  defp crash_on_call(reason) do
    spawn(fn ->
      receive do
        {:"$gen_call", {_from, _ref}, _message} -> exit(reason)
      end
    end)
  end

  defp scripted_stream(read_responses) do
    pid =
      spawn(fn ->
        scripted_stream_loop(read_responses, false)
      end)

    %ReadableStream{controller_pid: pid}
  end

  defp scripted_stream_loop(read_responses, locked?) do
    receive do
      {:"$gen_call", {from, ref}, {:get_reader, _pid}} ->
        reply = if locked?, do: {:error, :already_locked}, else: {:ok, make_ref()}
        send(from, {ref, reply})
        scripted_stream_loop(read_responses, match?({:ok, _}, reply))

      {:"$gen_call", {from, ref}, {:read, _pid}} ->
        case read_responses do
          [reply | rest] ->
            send(from, {ref, reply})
            scripted_stream_loop(rest, locked?)

          [] ->
            send(from, {ref, :done})
            scripted_stream_loop([], locked?)
        end

      {:"$gen_call", {from, ref}, {:release_lock, _pid}} ->
        send(from, {ref, :ok})
        scripted_stream_loop(read_responses, false)

      {:"$gen_call", {from, ref}, _message} ->
        send(from, {ref, {:error, :unexpected}})
        scripted_stream_loop(read_responses, locked?)
    end
  end

  defp tracked_source(chunks) do
    {:ok, tracker} =
      Agent.start_link(fn ->
        %{chunks: chunks, pulls: 0, cancel_reason: nil}
      end)

    stream =
      ReadableStream.new(%{
        pull: fn controller ->
          case Agent.get_and_update(tracker, fn %{chunks: queued, pulls: pulls} = state ->
                 next_pulls = pulls + 1

                 case queued do
                   [chunk | rest] ->
                     {{:chunk, chunk}, %{state | chunks: rest, pulls: next_pulls}}

                   [] ->
                     {:done, %{state | pulls: next_pulls}}
                 end
               end) do
            {:chunk, chunk} -> Web.ReadableStreamDefaultController.enqueue(controller, chunk)
            :done -> Web.ReadableStreamDefaultController.close(controller)
          end
        end,
        cancel: fn reason ->
          Agent.update(tracker, fn state -> %{state | cancel_reason: reason} end)
        end
      })

    {stream, tracker}
  end

  defp source_pulls(tracker) do
    Agent.get(tracker, & &1.pulls)
  end

  defp stable_source_pulls(tracker, attempts \\ 20)

  defp stable_source_pulls(tracker, attempts) when attempts > 0 do
    current = source_pulls(tracker)
    Process.sleep(5)
    next = source_pulls(tracker)

    if current == next do
      next
    else
      stable_source_pulls(tracker, attempts - 1)
    end
  end

  defp stable_source_pulls(tracker, 0), do: source_pulls(tracker)

  defp source_cancel_reason(tracker) do
    Agent.get(tracker, & &1.cancel_reason)
  end

  defp restore_ambient_signal(key, nil), do: Process.delete(key)
  defp restore_ambient_signal(key, previous), do: Process.put(key, previous)

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0) do
    flunk("condition was not satisfied in time")
  end
end

defmodule Web.FormDataEdgeTest do
  use ExUnit.Case, async: false

  alias Web.ReadableStream

  test "caller death tears down the live coordinator tree" do
    parent = self()
    boundary = "caller-death-boundary"
    file_body = String.duplicate("x", 256)

    caller =
      spawn(fn ->
        {stream, _tracker} =
          boundary
          |> multipart_payload([
            %{name: "upload", filename: "x.txt", content_type: "text/plain", value: file_body},
            %{name: "after", value: "ok"}
          ])
          |> chunk_binary([64])
          |> tracked_source()

        form = Web.FormData.parse(stream, boundary)
        file = Web.FormData.get(form, "upload")
        child_stream = Web.File.stream(file)

        send(parent, {:live_form, self(), form.coordinator, child_stream.controller_pid})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:live_form, ^caller, coordinator, child_pid}
    assert Process.alive?(coordinator)
    assert Process.alive?(child_pid)

    Process.exit(caller, :kill)

    assert_eventually(fn -> not Process.alive?(coordinator) end)
    assert_eventually(fn -> not Process.alive?(child_pid) end)
  end

  test "field-only forms complete and remain enumerable" do
    boundary = "terminal-snapshot-boundary"

    form =
      multipart_payload(boundary, [
        %{name: "a", value: "1"},
        %{name: "b", value: "2"}
      ])
      |> Web.FormData.parse(boundary)

    # Coordinator stays alive - no auto-stop
    assert Process.alive?(form.coordinator)
    assert Enum.to_list(Web.FormData.entries(form)) == [["a", "1"], ["b", "2"]]
    assert Web.FormData.get(form, "a") == "1"

    # Enumerable iteration yields [name, value] pairs
    assert Enum.to_list(form) == [["a", "1"], ["b", "2"]]

    # Coordinator still alive after iteration
    assert Process.alive?(form.coordinator)

    # Mutation on a live form drains the coordinator internally
    appended = Web.FormData.append(form, "c", "3")
    assert Enum.to_list(Web.FormData.entries(appended)) == [["a", "1"], ["b", "2"], ["c", "3"]]

    # Internal drain stops the coordinator
    assert_eventually(fn -> not Process.alive?(form.coordinator) end)
  end

  @tag timeout: 120_000
  test "Enum.to_list over large unread file discards body and collects all entries" do
    boundary = "materialize-drain-boundary"
    file_size = 10 * 1024 * 1024
    file_body = String.duplicate("z", file_size)

    {stream, _tracker} =
      boundary
      |> multipart_payload([
        %{
          name: "upload",
          filename: "large.bin",
          content_type: "application/octet-stream",
          value: file_body
        },
        %{name: "after", value: "done"}
      ])
      |> chunk_binary([65_536])
      |> tracked_source()

    form = Web.FormData.parse(stream, boundary)

    assert Process.alive?(form.coordinator)

    # Enum.to_list auto-discards the unread file body when advancing to the next entry
    entries =
      Task.async(fn -> Enum.to_list(form) end)
      |> Task.await(30_000)

    assert [["upload", %Web.File{filename: "large.bin"}], ["after", "done"]] = entries

    # Coordinator is still alive after iteration; cancel to free resources
    Web.FormData.cancel(form)
    assert_eventually(fn -> not Process.alive?(form.coordinator) end)
  end

  test "cancel releases the upstream lock" do
    boundary = "materialize-release-lock-boundary"

    {stream, _tracker} =
      boundary
      |> multipart_payload([
        %{
          name: "upload",
          filename: "x.txt",
          content_type: "text/plain",
          value: String.duplicate("y", 4096)
        },
        %{name: "after", value: "done"}
      ])
      |> chunk_binary([128])
      |> tracked_source()

    form = Web.FormData.parse(stream, boundary)
    _file = Web.FormData.get(form, "upload")

    assert ReadableStream.locked?(stream)

    Web.FormData.cancel(form, :done)

    assert_eventually(fn -> not Process.alive?(form.coordinator) end)
    assert_eventually(fn -> ReadableStream.locked?(stream) == false end)
  end

  @tag timeout: 120_000
  test "1,000 Enum.to_list + cancel calls terminate all coordinator pids" do
    boundary = "coordinator-leak-boundary"
    payload = multipart_payload(boundary, [%{name: "field", value: "ok"}])

    coordinators =
      for _ <- 1..1000 do
        form = Web.FormData.parse(payload, boundary)
        _ = Enum.to_list(form)
        Web.FormData.cancel(form)
        form.coordinator
      end

    assert_eventually(
      fn ->
        live_pids = MapSet.new(Process.list())
        Enum.all?(coordinators, fn pid -> not MapSet.member?(live_pids, pid) end)
      end,
      200
    )
  end

  test "Enum.to_list with two file parts discards both and returns all entries" do
    boundary = "two-file-materialize-boundary"
    content1 = String.duplicate("a", 256)
    content2 = String.duplicate("b", 128)

    payload =
      multipart_payload(boundary, [
        %{
          name: "file1",
          filename: "first.bin",
          content_type: "application/octet-stream",
          value: content1
        },
        %{
          name: "file2",
          filename: "second.bin",
          content_type: "application/octet-stream",
          value: content2
        },
        %{name: "tail", value: "end"}
      ])

    form = Web.FormData.parse(payload, boundary)
    entries = Enum.to_list(form)

    assert [
             ["file1", %Web.File{filename: "first.bin"}],
             ["file2", %Web.File{filename: "second.bin"}],
             ["tail", "end"]
           ] = entries

    Web.FormData.cancel(form)
    assert_eventually(fn -> not Process.alive?(form.coordinator) end)
  end

  test "Enum.to_list propagates upstream errors during file discard" do
    boundary = "materialize-error-drain-boundary"

    # Truncated payload: file headers are complete (so await_ready succeeds),
    # but the body has no closing boundary (so discard hits EOF).
    truncated_payload =
      "--#{boundary}\r\n" <>
        ~s(Content-Disposition: form-data; name="upload"; filename="error.bin"\r\n) <>
        "Content-Type: application/octet-stream\r\n\r\n" <>
        String.duplicate("e", 64)

    form = Web.FormData.parse(truncated_payload, boundary)
    assert Process.alive?(form.coordinator)

    # Calling next_entry(1) triggers auto-discard which hits the truncated EOF
    assert_raise Web.TypeError, ~r/missing closing boundary/, fn ->
      Enum.to_list(form)
    end
  end

  test "byte-by-byte feed through Enum.to_list returns correct entries" do
    boundary = "byte-by-byte-materialize-boundary"
    field_value = "hello world"
    file_content = String.duplicate("x", 512)

    payload =
      multipart_payload(boundary, [
        %{name: "field", value: field_value},
        %{
          name: "upload",
          filename: "big.bin",
          content_type: "application/octet-stream",
          value: file_content
        },
        %{name: "tail", value: "end"}
      ])

    form = Web.FormData.parse(ReadableStream.from(byte_chunks(payload)), boundary)
    entries = Enum.to_list(form)

    assert [["field", ^field_value], ["upload", %Web.File{filename: "big.bin"}], ["tail", "end"]] =
             entries

    Web.FormData.cancel(form)
    assert_eventually(fn -> not Process.alive?(form.coordinator) end)
  end

  test "Enum.to_list not blocked by active file stream reader" do
    boundary = "deadlock-blocked-boundary"
    file_body = String.duplicate("q", 128)

    payload =
      multipart_payload(boundary, [
        %{name: "upload", filename: "blocked.txt", content_type: "text/plain", value: file_body},
        %{name: "after", value: "done"}
      ])

    {stream, _} = tracked_source(byte_chunks(payload))
    form = Web.FormData.parse(stream, boundary)
    file = Web.FormData.get(form, "upload")

    # Start a reader task that will block partway through the file stream
    reader_task =
      Task.async(fn ->
        try do
          {:ok, Enum.join(Web.File.stream(file), "")}
        catch
          :exit, reason -> {:exit, reason}
        end
      end)

    Process.sleep(20)

    # Enum.to_list must not deadlock even with the blocked reader:
    # advancing to the next entry auto-discards the file stream,
    # which unblocks and cancels the reader task.
    entries =
      Task.async(fn -> Enum.to_list(form) end)
      |> Task.await(5_000)

    assert [[_, %Web.File{filename: "blocked.txt"}], ["after", "done"]] = entries

    Web.FormData.cancel(form)

    # The blocked reader is interrupted by the discard
    Task.await(reader_task, 2_000)
  end

  defp multipart_payload(boundary, parts) do
    body =
      Enum.map(parts, fn part ->
        disposition =
          case part do
            %{disposition: disposition} ->
              "Content-Disposition: #{disposition}\r\n"

            %{filename: filename} ->
              "Content-Disposition: form-data; name=\"#{part.name}\"; filename=\"#{filename}\"\r\n"

            _ ->
              "Content-Disposition: form-data; name=\"#{part.name}\"\r\n"
          end

        type_line =
          case part do
            %{content_type: type} -> "Content-Type: #{type}\r\n"
            _ -> ""
          end

        "--#{boundary}\r\n" <> disposition <> type_line <> "\r\n" <> part.value <> "\r\n"
      end)
      |> IO.iodata_to_binary()

    body <> "--#{boundary}--\r\n"
  end

  defp chunk_binary(binary, sizes) do
    do_chunk_binary(binary, sizes, sizes, [])
  end

  defp do_chunk_binary(<<>>, _sizes, _original_sizes, acc), do: Enum.reverse(acc)

  defp do_chunk_binary(binary, [], original_sizes, acc) do
    do_chunk_binary(binary, original_sizes, original_sizes, acc)
  end

  defp do_chunk_binary(binary, [size | rest_sizes], original_sizes, acc) do
    current_size = min(size, byte_size(binary))
    <<chunk::binary-size(current_size), rest::binary>> = binary
    do_chunk_binary(rest, rest_sizes, original_sizes, [chunk | acc])
  end

  defp byte_chunks(binary) do
    for <<byte <- binary>>, do: <<byte>>
  end

  defp tracked_source(chunks) do
    {:ok, tracker} =
      Agent.start_link(fn ->
        %{chunks: chunks, pulls: 0, cancel_reason: nil}
      end)

    stream =
      ReadableStream.new(%{
        pull: fn controller ->
          case Agent.get_and_update(tracker, fn %{chunks: queued, pulls: pulls} = state ->
                 next_pulls = pulls + 1

                 case queued do
                   [chunk | rest] ->
                     {{:chunk, chunk}, %{state | chunks: rest, pulls: next_pulls}}

                   [] ->
                     {:done, %{state | pulls: next_pulls}}
                 end
               end) do
            {:chunk, chunk} -> Web.ReadableStreamDefaultController.enqueue(controller, chunk)
            :done -> Web.ReadableStreamDefaultController.close(controller)
          end
        end,
        cancel: fn reason ->
          Agent.update(tracker, fn state -> %{state | cancel_reason: reason} end)
        end
      })

    {stream, tracker}
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0) do
    flunk("condition was not satisfied in time")
  end
end
