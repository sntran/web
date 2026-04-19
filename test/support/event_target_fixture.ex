defmodule Web.TestSupport.EventTargetFixture do
  @moduledoc false

  alias Web.Internal.EventTarget.Server

  use Web.EventTarget

  defstruct [:ref, :parent]

  def new(parent \\ self()) do
    ref = make_ref()
    target = %__MODULE__{ref: ref, parent: parent}

    {:ok, _pid} =
      Server.start_link(
        target: target,
        registry_key: ref,
        callback_module: __MODULE__
      )

    target
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
