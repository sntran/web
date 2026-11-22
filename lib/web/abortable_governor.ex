defmodule Web.AbortableGovernor do
  @moduledoc """
  The function of a governor that can abort an acquisition, as
  `AbortableGovernor` of the TC39 proposal "concurrency control".

  ## Examples

      iex> governor = Web.CountingGovernor.new(0)
      iex> %{abort: abort, promise: promise} = Web.AbortableGovernor.acquire_abortable(governor)
      iex> abort.()
      iex> catch_exit(Web.await(promise)).name
      "AbortError"
  """

  @type abortable_acquisition :: %{
          abort: (-> :ok),
          promise: Web.Promise.t()
        }

  @doc """
  Starts an acquisition, as `acquireAbortable()`. Returns the function
  `abort` and the promise of the token. A call of `abort` before the
  acquisition has its token rejects the promise with a `Web.DOMException`
  with the name `AbortError`.
  """
  @spec acquire_abortable(struct()) :: abortable_acquisition()
  def acquire_abortable(%module{} = governor) do
    module.acquire_abortable(governor)
  end
end
