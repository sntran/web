defmodule Web.FetchFormDataTest do
  # A `FormData` body of `fetch`, with a server whose `multipart/form-data`
  # parser is a different implementation (the package `plug`).
  use ExUnit.Case, async: true
  use Web

  defmodule Server do
    @moduledoc false
    use Plug.Builder

    plug(Plug.Parsers, parsers: [:multipart], length: 20_000_000)
    plug(:respond)

    # A redirect that keeps the method and the body.
    def respond(%{request_path: "/redirect"} = conn, _options) do
      conn |> put_resp_header("location", "/upload") |> send_resp(307, "")
    end

    # Gives the fields and the files that the server got, as JSON.
    def respond(conn, _options) do
      parts =
        Map.new(conn.body_params, fn
          {name, %Plug.Upload{} = upload} ->
            {name,
             %{
               "filename" => upload.filename,
               "type" => upload.content_type,
               "bytes" => Base.encode64(Elixir.File.read!(upload.path))
             }}

          {name, value} ->
            {name, value}
        end)

      body =
        JSON.encode!(%{"length" => get_req_header(conn, "content-length"), "parts" => parts})

      send_resp(conn, 200, body)
    end
  end

  setup_all do
    {:ok, server} = Bandit.start_link(plug: Server, scheme: :http, port: 0, startup_log: false)
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    %{base: "http://localhost:#{port}"}
  end

  @bytes :binary.list_to_bin(Enum.to_list(0..255)) <> "\r\n--not-a-boundary\r\n"

  defp form do
    FormData.new()
    |> FormData.append("title", "A form")
    |> FormData.append("text", "line one\nline two")
    |> FormData.append("empty", "")
    |> FormData.append(
      "upload",
      Web.File.new([@bytes], "data.bin", type: "application/x-test")
    )
    |> FormData.append("blob", Web.Blob.new(["blob ", "bytes"]))
  end

  defp expected_parts do
    %{
      "title" => "A form",
      "text" => "line one\r\nline two",
      "empty" => "",
      "upload" => %{
        "filename" => "data.bin",
        "type" => "application/x-test",
        "bytes" => Base.encode64(@bytes)
      },
      "blob" => %{
        "filename" => "blob",
        "type" => "application/octet-stream",
        "bytes" => Base.encode64("blob bytes")
      }
    }
  end

  test "sends a form that the server parses, with a content length", %{base: base} do
    response = await(fetch(base <> "/upload", method: "POST", body: form()))
    assert response.status == 200

    assert %{"length" => [length], "parts" => parts} = await(Response.json(response))
    assert parts == expected_parts()
    assert String.to_integer(length) > byte_size(@bytes)
  end

  test "sends a form from memory again after a redirect that keeps the body", %{base: base} do
    response = await(fetch(base <> "/redirect", method: "POST", body: form()))

    assert response.redirected
    assert response.url == base <> "/upload"
    assert %{"parts" => parts} = await(Response.json(response))
    assert parts == expected_parts()
  end

  test "sends a form with a file from a stream, chunk by chunk", %{base: base} do
    chunks = for index <- 1..50, do: String.duplicate(<<rem(index, 256)>>, 1_000)

    file = %{Web.File.new([], "stream.bin") | stream: ReadableStream.from(chunks), size: nil}

    form = FormData.new() |> FormData.append("field", "value") |> FormData.append("upload", file)

    response = await(fetch(base <> "/upload", method: "POST", body: form))

    assert %{"length" => [], "parts" => parts} = await(Response.json(response))
    assert parts["field"] == "value"
    assert parts["upload"]["filename"] == "stream.bin"
    assert Base.decode64!(parts["upload"]["bytes"]) == Enum.join(chunks)
  end

  test "rejects a redirect that needs a form with a file stream again", %{base: base} do
    file = %{Web.File.new([], "s.bin") | stream: ReadableStream.from(["x"]), size: nil}
    form = FormData.append(FormData.new(), "upload", file)

    assert %TypeError{} =
             catch_exit(await(fetch(base <> "/redirect", method: "POST", body: form)))
  end
end
