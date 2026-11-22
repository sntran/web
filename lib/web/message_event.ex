defmodule Web.MessageEvent do
  @moduledoc """
  The event of a message, as `MessageEvent` of the HTML Standard.

  A `Web.MessagePort` and a `Web.BroadcastChannel` give this event to the
  listeners of `message` and `messageerror`.

    * `data` - the message;
    * `origin` - the origin of the sender. It is `""` for a message port;
    * `ports` - the message ports that came with the message, in the
      sequence of the transfer list;
    * `target` - the port or the channel that got the message. Use it to
      answer.
  """

  defstruct type: "message",
            data: nil,
            origin: "",
            source: nil,
            target: nil,
            current_target: nil,
            last_event_id: "",
            ports: []

  @type t :: %__MODULE__{
          type: String.t(),
          data: term(),
          origin: String.t(),
          source: term(),
          target: term(),
          current_target: term(),
          last_event_id: String.t(),
          ports: list()
        }

  @doc """
  Makes an event, as the constructor `new MessageEvent(type,
  eventInitDict)`.

  ## Options

  The members of `MessageEventInit`:

    * `:data` - the message. The default is `nil`;
    * `:origin` and `:last_event_id` - the default is `""`;
    * `:source` - the default is `nil`;
    * `:ports` - a list of `Web.MessagePort`. The default is `[]`.

  ## Examples

      iex> event = Web.MessageEvent.new("message", data: [1, 2])
      iex> {event.type, event.data, event.origin, event.ports}
      {"message", [1, 2], "", []}
  """
  @spec new(String.t() | atom(), keyword()) :: t()
  def new(type, opts \\ []) do
    __new__(type, Keyword.take(opts, [:data, :origin, :last_event_id, :source, :ports]))
  end

  @doc false
  # An event with the fields of a dispatch: the options of `new/2`, and
  # `:target` and `:current_target` (the default is the target).
  @spec __new__(String.t() | atom(), keyword()) :: t()
  def __new__(type, opts) do
    target = Keyword.get(opts, :target)

    %__MODULE__{
      type: to_string(type),
      data: Keyword.get(opts, :data),
      origin: Keyword.get(opts, :origin, ""),
      source: Keyword.get(opts, :source),
      target: target,
      current_target: Keyword.get(opts, :current_target, target),
      last_event_id: Keyword.get(opts, :last_event_id, ""),
      ports: Keyword.get(opts, :ports, [])
    }
  end
end
