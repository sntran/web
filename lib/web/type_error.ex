defmodule Web.TypeError do
  @moduledoc """
  An exception struct for spec violations.
  """
  defexception [:message]

  @impl true
  def exception(message) do
    %__MODULE__{message: message}
  end
end
