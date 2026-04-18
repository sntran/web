defmodule Web.Internal.Reference do
  @moduledoc false

  @enforce_keys [:id]
  defstruct [:id]

  @type t :: %__MODULE__{id: pos_integer()}
end
