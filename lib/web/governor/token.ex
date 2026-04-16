defmodule Web.Governor.Token do
  @moduledoc """
  A capability returned by a governor acquisition.
  """

  defstruct [:governor, :ref]

  @type t :: %__MODULE__{
          governor: struct(),
          ref: reference()
        }

  @doc """
  Releases the token back to its governor.
  """
  @spec release(t()) :: :ok
  def release(%__MODULE__{governor: %module{} = governor, ref: ref}) do
    module.release_token(governor, ref)
  end
end
