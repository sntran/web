defmodule Web.MessageEvent do
  @moduledoc """
  The event of a message, as `MessageEvent` of the HTML Standard.

  A `Web.MessagePort` and a `Web.BroadcastChannel` give this event to the
  listeners of `message` and `messageerror`.

  A `MessageEvent` is an `Event`: the event has the fields of `Web.Event`,
  and the functions of `Web.Event` accept it, for example
  `Web.Event.current_target/1`. The other fields are the attributes of
  `MessageEvent`:

    * `data` - the message;
    * `origin` - the origin of the sender. It is `""` for a message port;
    * `last_event_id` - the default is `""`;
    * `source` - the default is `nil`;
    * `ports` - the message ports that came with the message, in the
      sequence of the transfer list;
    * `target` - the port or the channel that got the message. Use it to
      answer.

  An event that a port or a channel fires has `is_trusted: true`.
  """

  defstruct type: "message",
            data: nil,
            origin: "",
            source: nil,
            last_event_id: "",
            ports: [],
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
          data: term(),
          origin: String.t(),
          source: term(),
          last_event_id: String.t(),
          ports: list(),
          target: term(),
          current_target: term(),
          bubbles: boolean(),
          cancelable: boolean(),
          composed: boolean(),
          is_trusted: boolean(),
          time_stamp: float(),
          flags: :atomics.atomics_ref() | nil
        }

  @members [:data, :origin, :last_event_id, :source, :ports]

  @doc """
  Makes an event, as the constructor `new MessageEvent(type,
  eventInitDict)`.

  ## Options

  The members of `MessageEventInit`:

    * `:bubbles`, `:cancelable`, and `:composed` - the members of
      `EventInit`. The default is `false`;
    * `:data` - the message. The default is `nil`;
    * `:origin` and `:last_event_id` - the default is `""`;
    * `:source` - the default is `nil`;
    * `:ports` - a list of `Web.MessagePort`. The default is `[]`.

  ## Examples

      iex> event = Web.MessageEvent.new("message", data: [1, 2], cancelable: true)
      iex> {event.type, event.data, event.origin, event.ports, event.cancelable}
      {"message", [1, 2], "", [], true}
  """
  @spec new(String.t() | atom(), keyword()) :: t()
  def new(type, opts \\ []) do
    __new__(type, Keyword.take(opts, [:bubbles, :cancelable, :composed | @members]))
  end

  @doc false
  # An event with the fields of a dispatch: the options of `new/2`, and
  # `:target` and `:current_target` (the default is the target).
  @spec __new__(String.t() | atom(), keyword()) :: t()
  def __new__(type, opts) do
    event = Web.Event.__new__(type, opts)

    %__MODULE__{
      type: event.type,
      data: Keyword.get(opts, :data),
      origin: Keyword.get(opts, :origin, ""),
      source: Keyword.get(opts, :source),
      last_event_id: Keyword.get(opts, :last_event_id, ""),
      ports: Keyword.get(opts, :ports, []),
      target: event.target,
      current_target: event.current_target,
      bubbles: event.bubbles,
      cancelable: event.cancelable,
      composed: event.composed,
      time_stamp: event.time_stamp,
      flags: event.flags
    }
  end

  @doc false
  # An event that a port or a channel fires, as "fire an event" of the DOM
  # Standard: `isTrusted` is true.
  @spec __create__(String.t() | atom(), keyword()) :: t()
  def __create__(type, opts), do: %{__new__(type, opts) | is_trusted: true}

  @doc """
  Initializes the event again, as the legacy `initMessageEvent(type,
  bubbles, cancelable, data, origin, lastEventId, source, ports)`. Returns
  the new event. During a dispatch, the event does not change.
  """
  @spec init_message_event(
          t(),
          String.t() | atom(),
          boolean(),
          boolean(),
          term(),
          String.t(),
          String.t(),
          term(),
          list()
        ) :: t()
  # The arguments are the arguments of the method of the Standard.
  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  def init_message_event(
        %__MODULE__{} = event,
        type,
        bubbles \\ false,
        cancelable \\ false,
        data \\ nil,
        origin \\ "",
        last_event_id \\ "",
        source \\ nil,
        ports \\ []
      ) do
    if Web.Event.__flag__(event, :dispatch) do
      event
    else
      %{
        Web.Event.init_event(event, type, bubbles, cancelable)
        | data: data,
          origin: origin,
          last_event_id: last_event_id,
          source: source,
          ports: ports
      }
    end
  end
end
