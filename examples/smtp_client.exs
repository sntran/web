defmodule SMTPClientExample do
  @moduledoc """
  Demonstrates an SMTP `STARTTLS` login sequence using `Web.connect/2`.

  Usage:
    SMTP_HOST=smtp.example.com \
    SMTP_PORT=587 \
    SMTP_USERNAME=user@example.com \
    SMTP_PASSWORD=secret \
    SMTP_VERIFY=none \
    mix run examples/smtp_client.exs
  """

  use Web

  alias Web.ReadableStreamDefaultReader
  alias Web.WritableStreamDefaultWriter

  def run do
    config = load_config()
    socket = Web.connect(%{hostname: config.host, port: config.port}, secureTransport: "starttls")
    await(socket.opened)

    reader = ReadableStream.get_reader(socket.readable)
    writer = WritableStream.get_writer(socket.writable)

    banner = recv_line(reader)
    IO.puts("S: #{banner}")

    send_line(writer, "EHLO #{config.client_name}")
    ehlo_lines = recv_reply_lines(reader, "250")
    print_lines("S", ehlo_lines)

    send_line(writer, "STARTTLS")
    starttls_reply = recv_line(reader)
    IO.puts("S: #{starttls_reply}")

    unless String.starts_with?(starttls_reply, "220") do
      raise "server rejected STARTTLS: #{starttls_reply}"
    end

    ReadableStreamDefaultReader.release_lock(reader)
    WritableStreamDefaultWriter.release_lock(writer)

    socket = await(Socket.start_tls(socket, tls_options(config.verify)))
    await(socket.opened)

    reader = ReadableStream.get_reader(socket.readable)
    writer = WritableStream.get_writer(socket.writable)

    send_line(writer, "EHLO #{config.client_name}")
    secure_ehlo_lines = recv_reply_lines(reader, "250")
    print_lines("S", secure_ehlo_lines)

    send_line(writer, "AUTH LOGIN")
    assert_code!(recv_line(reader), "334")

    send_line(writer, Base.encode64(config.username))
    assert_code!(recv_line(reader), "334")

    send_line(writer, Base.encode64(config.password))
    auth_reply = recv_line(reader)
    IO.puts("S: #{auth_reply}")

    unless String.starts_with?(auth_reply, "235") do
      raise "authentication failed: #{auth_reply}"
    end

    send_line(writer, "QUIT")
    quit_reply = recv_line(reader)
    IO.puts("S: #{quit_reply}")

    WritableStreamDefaultWriter.release_lock(writer)
    ReadableStreamDefaultReader.release_lock(reader)
    await(Socket.close(socket))
  end

  defp load_config do
    %{
      host: required_env!("SMTP_HOST"),
      port: parse_port(required_env!("SMTP_PORT", "587")),
      username: required_env!("SMTP_USERNAME"),
      password: required_env!("SMTP_PASSWORD"),
      client_name: System.get_env("SMTP_CLIENT_NAME", "localhost"),
      verify: System.get_env("SMTP_VERIFY", "none")
    }
  end

  defp required_env!(name, default \\ nil) do
    case System.get_env(name, default) do
      nil -> raise "missing required environment variable #{name}"
      value -> value
    end
  end

  defp parse_port(value) do
    String.to_integer(value)
  rescue
    _error -> raise "invalid SMTP_PORT: #{inspect(value)}"
  end

  defp tls_options("none"), do: [verify: :verify_none]
  defp tls_options(_mode), do: []

  defp send_line(writer, line) do
    IO.puts("C: #{line}")
    await(WritableStreamDefaultWriter.write(writer, line <> "\r\n"))
  end

  defp recv_reply_lines(reader, code) do
    do_recv_reply_lines(reader, code, [])
  end

  defp do_recv_reply_lines(reader, code, acc) do
    line = recv_line(reader)

    if String.starts_with?(line, code <> "-") do
      do_recv_reply_lines(reader, code, [line | acc])
    else
      Enum.reverse([line | acc])
    end
  end

  defp recv_line(reader, buffer \\ "") do
    case String.split(buffer, "\r\n", parts: 2) do
      [line, rest] when rest != buffer ->
        if rest == "" do
          line
        else
          Process.put({__MODULE__, :smtp_buffer}, rest)
          line
        end

      _ ->
        buffer = buffer <> flush_buffer()

        case String.split(buffer, "\r\n", parts: 2) do
          [line, rest] when rest != buffer ->
            Process.put({__MODULE__, :smtp_buffer}, rest)
            line

          _ ->
            case await(ReadableStreamDefaultReader.read(reader)) do
              %{done: false, value: chunk} -> recv_line(reader, buffer <> chunk)
              %{done: true} -> raise "socket closed while waiting for an SMTP line"
            end
        end
    end
  end

  defp flush_buffer do
    case Process.get({__MODULE__, :smtp_buffer}, "") do
      "" ->
        ""

      buffer ->
        Process.delete({__MODULE__, :smtp_buffer})
        buffer
    end
  end

  defp assert_code!(line, code) do
    IO.puts("S: #{line}")

    unless String.starts_with?(line, code) do
      raise "expected SMTP reply #{code}, got: #{line}"
    end

    line
  end

  defp print_lines(prefix, lines) do
    Enum.each(lines, &IO.puts("#{prefix}: #{&1}"))
  end
end

SMTPClientExample.run()
