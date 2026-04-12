defmodule Web.CustomEvent do
  @moduledoc """
  Minimal custom event payload.
  """

  defstruct type: nil, detail: nil, bubbles: false, cancelable: false

  @type t :: %__MODULE__{
          type: String.t(),
          detail: term(),
          bubbles: boolean(),
          cancelable: boolean()
        }

  @spec new(String.t() | atom(), keyword()) :: t()
  def new(type, opts \\ []) do
    %__MODULE__{
      type: to_string(type),
      detail: Keyword.get(opts, :detail),
      bubbles: Keyword.get(opts, :bubbles, false),
      cancelable: Keyword.get(opts, :cancelable, false)
    }
  end
end
