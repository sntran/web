defmodule Web.ReadableStreamBYOBReader do
  @moduledoc """
  A BYOB reader for byte-oriented readable streams.
  """

  defstruct [:controller_pid]

  alias Web.Promise
  alias Web.ReadableStream
  alias Web.TypeError
  alias Web.Uint8Array

  @type t :: %__MODULE__{controller_pid: pid()}

  @spec read(t(), Uint8Array.t()) :: Promise.t()
  def read(%__MODULE__{controller_pid: pid}, %Uint8Array{} = view) do
    case ReadableStream.byob_read(pid, view) do
      {:ok, %Uint8Array{} = chunk_view} ->
        Promise.resolve(%{value: chunk_view, done: false})

      :done ->
        Promise.resolve(%{value: view, done: true})

      {:error, :not_locked_by_reader} ->
        Promise.reject(%TypeError{message: "This BYOB reader is no longer locked."})

      {:error, :invalid_byob_view} ->
        Promise.reject(%TypeError{message: "BYOB reads require a Uint8Array view."})

      {:error, {:errored, reason}} ->
        Promise.reject(reason)

      {:error, reason} ->
        Promise.reject(reason)
    end
  end

  def read(%__MODULE__{}, _view) do
    Promise.reject(%TypeError{message: "BYOB reads require a Uint8Array view."})
  end

  @spec release_lock(t()) :: :ok
  def release_lock(%__MODULE__{controller_pid: pid}) do
    case ReadableStream.release_lock(pid) do
      :ok ->
        :ok

      {:error, :not_locked_by_reader} ->
        raise TypeError, "This BYOB reader is no longer locked."

      {:error, reason} ->
        raise TypeError, "Unknown error: #{inspect(reason)}"
    end
  end

  @spec cancel(t(), term()) :: Promise.t()
  def cancel(%__MODULE__{controller_pid: pid}, reason \\ :cancelled) do
    ReadableStream.cancel(pid, reason)
  end
end
