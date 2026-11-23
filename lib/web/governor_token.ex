defmodule Web.GovernorToken do
  @moduledoc """
  The token of an acquisition, as `GovernorToken` of the TC39 proposal
  "concurrency control".

  `Web.Governor.acquire/1` gives a token. The work holds the token until
  `release/1`. A token is disposable: `Web.using/2` releases it at the end
  of its block, as `[Symbol.dispose]()`.

  ## Examples

      iex> governor = Web.CountingGovernor.new(1)
      iex> token = Web.await(Web.Governor.acquire(governor))
      iex> Web.GovernorToken.release(token)
      :ok
  """

  defstruct [:governor, :ref]

  @typedoc "A token. The fields are private."
  @type t :: %__MODULE__{
          governor: struct(),
          ref: reference()
        }

  @doc """
  Gives the token back to its governor, as `release()`. A second call has
  no effect.
  """
  @spec release(t()) :: :ok
  def release(%__MODULE__{governor: %module{} = governor, ref: ref}) do
    module.release_token(governor, ref)
  end
end
