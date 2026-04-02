defmodule Web.ReadableStreamDefaultReader do
  @moduledoc """
  A reader that allows exclusive access to a ReadableStream's data.
  """
  defstruct [:controller_pid]

  alias Web.ReadableStream
  alias Web.TypeError

  @doc """
  Reads a chunk from the stream.

  Returns the chunk or `:done` if the stream is closed.

  ## Examples

      iex> stream = Web.ReadableStream.new(%{
      ...>   start: fn c ->
      ...>     Web.ReadableStreamDefaultController.enqueue(c, "a")
      ...>     Web.ReadableStreamDefaultController.close(c)
      ...>   end
      ...> })
      iex> reader = Web.ReadableStream.get_reader(stream)
      iex> Web.ReadableStreamDefaultReader.read(reader)
      "a"
      iex> Web.ReadableStreamDefaultReader.read(reader)
      :done
  """
  def read(%__MODULE__{controller_pid: pid}) do
    case ReadableStream.read(pid) do
      {:ok, chunk} ->
        chunk

      :done ->
        :done

      {:error, :not_locked_by_reader} ->
        raise TypeError, "This reader is no longer locked."

      {:error, :errored} ->
        raise TypeError, "The stream is errored."

      {:error, {:errored, _reason}} ->
        raise TypeError, "The stream is errored."

      {:error, reason} ->
        raise TypeError, "Unknown error: #{inspect(reason)}"
    end
  end

  @doc """
  Releases the reader's lock on the stream.
  """
  def release_lock(%__MODULE__{controller_pid: pid}) do
    case ReadableStream.release_lock(pid) do
      :ok ->
        :ok

      {:error, :not_locked_by_reader} ->
        raise TypeError, "This reader is no longer locked."

      {:error, reason} ->
        raise TypeError, "Unknown error: #{inspect(reason)}"
    end
  end

  @doc """
  Cancels the stream.
  """
  def cancel(%__MODULE__{controller_pid: pid}) do
    ReadableStream.cancel(pid)
    :ok
  end
end
