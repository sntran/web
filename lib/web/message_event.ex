defmodule Web.MessageEvent do
  @moduledoc """
  Minimal WHATWG-style message event payload.
  """

  defstruct type: "message",
            data: nil,
            origin: nil,
            source: nil,
            target: nil,
            current_target: nil,
            last_event_id: "",
            ports: []

  @type t :: %__MODULE__{
          type: String.t(),
          data: term(),
          origin: String.t() | nil,
          source: term(),
          target: term(),
          current_target: term(),
          last_event_id: String.t(),
          ports: list()
        }

  @spec new(String.t() | atom(), keyword()) :: t()
  def new(type \\ "message", opts \\ []) do
    target = Keyword.get(opts, :target)

    %__MODULE__{
      type: to_string(type),
      data: Keyword.get(opts, :data),
      origin: Keyword.get(opts, :origin),
      source: Keyword.get(opts, :source),
      target: target,
      current_target: Keyword.get(opts, :current_target, target),
      last_event_id: Keyword.get(opts, :last_event_id, ""),
      ports: Keyword.get(opts, :ports, [])
    }
  end
end
