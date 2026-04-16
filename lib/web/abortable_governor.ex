defmodule Web.AbortableGovernor do
  @moduledoc """
  Optional TC39 proposal-aligned governor API for abortable acquisition.
  """

  @type abortable_acquisition :: %{
          abort: (-> :ok),
          promise: Web.Promise.t()
        }

  @doc """
  Starts an abortable governor acquisition.
  """
  @spec acquire_abortable(struct()) :: abortable_acquisition()
  def acquire_abortable(%module{} = governor) do
    module.acquire_abortable(governor)
  end
end
