defmodule Web.Event do
  @moduledoc """
  An event with no data, as `Event` of the DOM Standard.

  A `Web.MessagePort` uses it for the event `close`.

  ## Examples

      iex> event = Web.Event.new("close")
      iex> {event.type, event.bubbles, event.cancelable}
      {"close", false, false}
  """

  defstruct type: nil, target: nil, current_target: nil, bubbles: false, cancelable: false

  @type t :: %__MODULE__{
          type: String.t(),
          target: term(),
          current_target: term(),
          bubbles: boolean(),
          cancelable: boolean()
        }

  @doc """
  Makes an event.

  ## Options

    * `:target` - the object that gets the event;
    * `:current_target` - the default is the target;
    * `:bubbles` and `:cancelable` - the default is `false`.
  """
  @spec new(String.t() | atom(), keyword()) :: t()
  def new(type, opts \\ []) do
    target = Keyword.get(opts, :target)

    %__MODULE__{
      type: to_string(type),
      target: target,
      current_target: Keyword.get(opts, :current_target, target),
      bubbles: Keyword.get(opts, :bubbles, false),
      cancelable: Keyword.get(opts, :cancelable, false)
    }
  end
end
