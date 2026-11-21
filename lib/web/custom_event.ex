defmodule Web.CustomEvent do
  @moduledoc """
  An event with data, as `CustomEvent` of the DOM Standard.

  The event has the fields of `Web.Event`, and `detail`. The functions of
  `Web.Event` accept it, for example `Web.Event.prevent_default/1`.

  ## Examples

      iex> event = Web.CustomEvent.new("tick", detail: 1, cancelable: true)
      iex> {event.type, event.detail, event.cancelable}
      {"tick", 1, true}
  """

  defstruct type: nil,
            detail: nil,
            target: nil,
            current_target: nil,
            bubbles: false,
            cancelable: false,
            composed: false,
            is_trusted: false,
            time_stamp: 0.0,
            flags: nil

  @type t :: %__MODULE__{
          type: String.t(),
          detail: term(),
          target: term(),
          current_target: term(),
          bubbles: boolean(),
          cancelable: boolean(),
          composed: boolean(),
          is_trusted: boolean(),
          time_stamp: float(),
          flags: :atomics.atomics_ref() | nil
        }

  @doc """
  Makes an event, as the constructor `new CustomEvent(type, eventInitDict)`.

  The options are the options of `Web.Event.new/2`, and `:detail`.
  """
  @spec new(String.t() | atom(), keyword()) :: t()
  def new(type, opts \\ []) do
    event = Web.Event.new(type, opts)

    %__MODULE__{
      type: event.type,
      detail: Keyword.get(opts, :detail),
      target: event.target,
      current_target: event.current_target,
      bubbles: event.bubbles,
      cancelable: event.cancelable,
      composed: event.composed,
      time_stamp: event.time_stamp,
      flags: event.flags
    }
  end

  @doc """
  Initializes the event again, as the legacy `initCustomEvent(type,
  bubbles, cancelable, detail)`. During a dispatch, the event does not
  change.
  """
  @spec init_custom_event(t(), String.t() | atom(), boolean(), boolean(), term()) :: t()
  def init_custom_event(
        %__MODULE__{} = event,
        type,
        bubbles \\ false,
        cancelable \\ false,
        detail \\ nil
      ) do
    if Web.Event.__flag__(event, :dispatch) do
      event
    else
      %{Web.Event.init_event(event, type, bubbles, cancelable) | detail: detail}
    end
  end
end
