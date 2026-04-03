defmodule Web.WritableStreamDefaultController do
  @moduledoc """
  The interface passed to WritableStream user-defined callbacks.
  """
  defstruct [:pid]

  alias Web.WritableStream

  @doc """
  Errors the stream with the given reason.
  """
  def error(%__MODULE__{pid: pid}, reason) do
    WritableStream.error(pid, reason)
  end

  @doc """
  Returns the writable stream desired size.
  """
  def desired_size(%__MODULE__{pid: pid}) do
    WritableStream.desired_size(pid)
  end
end
