defmodule Web.ReadableStream do
  @moduledoc """
  A strictly spec-compliant ReadableStream implementation.
  """
  defstruct [:controller_pid]

  alias Web.ReadableStream.Controller
  alias Web.ReadableStreamDefaultReader
  alias Web.TypeError

  @doc """
  Locks the stream and returned a reader.
  """
  def get_reader(%__MODULE__{controller_pid: pid}) do
    case Controller.get_reader(pid) do
      :ok -> %ReadableStreamDefaultReader{controller_pid: pid}
      {:error, :already_locked} ->
        raise TypeError, "ReadableStream is already locked"
    end
  end
end

defimpl Enumerable, for: Web.ReadableStream do
  alias Web.ReadableStreamDefaultReader

  def reduce(stream, acc, fun) do
    reader = Web.ReadableStream.get_reader(stream)
    do_reduce(reader, acc, fun)
  end

  defp do_reduce(reader, {:halt, acc}, _fun) do
    try do
      ReadableStreamDefaultReader.release_lock(reader)
    rescue
      _ -> :ok
    end
    {:halted, acc}
  end

  defp do_reduce(reader, {:suspend, acc}, fun) do
    {:suspended, acc, &do_reduce(reader, &1, fun)}
  end

  defp do_reduce(reader, {:cont, acc}, fun) do
    case ReadableStreamDefaultReader.read(reader) do
      :done ->
        try do
          ReadableStreamDefaultReader.release_lock(reader)
        rescue
          _ -> :ok
        end
        {:done, acc}

      chunk ->
        try do
          do_reduce(reader, fun.(chunk, acc), fun)
        rescue
          e ->
            try do
              ReadableStreamDefaultReader.release_lock(reader)
            rescue
              _ -> :ok
            end
            reraise e, __STACKTRACE__
        end
    end
  end

  def count(_stream), do: {:error, __MODULE__}
  def member?(_stream, _element), do: {:error, __MODULE__}
  def slice(_stream), do: {:error, __MODULE__}
end
