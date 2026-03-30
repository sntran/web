defmodule Web.ReadableStreamDefaultReader do
  defstruct [:controller_pid]

  alias Web.ReadableStream.Controller
  alias Web.TypeError

  def read(%__MODULE__{controller_pid: pid}) do
    case Controller.read(pid) do
      {:ok, chunk} -> chunk
      :done -> :done
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

  def release_lock(%__MODULE__{controller_pid: pid}) do
    case Controller.release_lock(pid) do
      :ok -> :ok
      {:error, :not_locked_by_reader} ->
        raise TypeError, "This reader is no longer locked."
      {:error, reason} ->
        raise TypeError, "Unknown error: #{inspect(reason)}"
    end
  end

  def cancel(%__MODULE__{controller_pid: pid}) do
    Controller.cancel(pid)
    :ok
  end
end
