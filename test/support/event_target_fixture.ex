defmodule Web.TestSupport.EventTargetFixture do
  @moduledoc false

  alias Web.Internal.EventTarget.Server

  use Web.EventTarget

  defstruct [:event_target_pid, :parent]

  def new(parent \\ self()) do
    target = %__MODULE__{event_target_pid: nil, parent: parent}

    {:ok, event_target_pid} =
      Server.start_link(
        target: target,
        callback_module: __MODULE__
      )

    %{target | event_target_pid: event_target_pid}
  end

  @impl Web.EventTarget
  def handle_add_listener(%__MODULE__{parent: parent} = target, type, _callback, _options) do
    send(parent, {:handle_add_listener, to_string(type)})
    {:ok, target}
  end

  @impl Web.EventTarget
  def handle_dispatch(%__MODULE__{parent: parent} = target, event) do
    send(parent, {:handle_dispatch, event.type})
    {:ok, target}
  end
end
