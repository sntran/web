defmodule Web.Event do
  @moduledoc """
  An event, as `Event` of the DOM Standard.

  A `Web.EventTarget`, a `Web.AbortSignal`, a `Web.MessagePort`, and a
  `Web.BroadcastChannel` dispatch events to their listeners.

  ## Examples

      iex> event = Web.Event.new("close")
      iex> {event.type, event.bubbles, event.cancelable, event.is_trusted}
      {"close", false, false, false}

  ## The state of a dispatch

  The fields of the struct are the attributes that do not change: `type`,
  `bubbles`, `cancelable`, `composed`, `is_trusted`, and `time_stamp`. A
  listener gets the event with the fields `target` and `current_target` of
  the dispatch.

  The flags of the DOM Standard change during a dispatch, and all the
  copies of one event share them: a call of `prevent_default/1` in a
  listener changes the result of the dispatch. Read them with
  `default_prevented?/1`, `event_phase/1`, `cancel_bubble?/1`, and
  `return_value?/1`. Set the legacy attributes with `cancel_bubble/2` and
  `return_value/2`.

  The value of `current_target/1` and of `composed_path/1` is only there
  during a dispatch, as the DOM Standard specifies.

  `new/2` sets the initialized flag of the event. A struct that a caller
  makes with no `new/2`, for example `%Web.Event{type: "x"}`, has no
  initialized flag: a dispatch of it raises an `InvalidStateError`, as for
  an event of `document.createEvent()`. `init_event/4` initializes it.

  ## Constants

  The constants of the interface `Event` are functions with no argument:
  `none/0`, `capturing_phase/0`, `at_target/0`, and `bubbling_phase/0`.
  `event_phase/1` gives one of them.
  """

  @none 0
  @capturing_phase 1
  @at_target 2
  @bubbling_phase 3

  # The slots of the flags of an event, in an `:atomics` array.
  @stop_propagation 1
  @stop_immediate_propagation 2
  @canceled 3
  @in_passive_listener 4
  @dispatch 5
  @phase 6
  @initialized 7
  @slots 7

  defstruct type: nil,
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
          target: term(),
          current_target: term(),
          bubbles: boolean(),
          cancelable: boolean(),
          composed: boolean(),
          is_trusted: boolean(),
          time_stamp: float(),
          flags: :atomics.atomics_ref() | nil
        }

  @typedoc "An event of this module, or of a module that has its fields, such as `Web.CustomEvent`."
  @type event :: %{
          required(:type) => String.t(),
          required(:flags) => term(),
          optional(atom()) => term()
        }

  @doc """
  The constant `Event.NONE` (0): the phase of an event that is not in a
  dispatch.
  """
  @spec none() :: 0
  def none, do: @none

  @doc """
  The constant `Event.CAPTURING_PHASE` (1): the phase of an event at an
  ancestor of its target, before the target.
  """
  @spec capturing_phase() :: 1
  def capturing_phase, do: @capturing_phase

  @doc """
  The constant `Event.AT_TARGET` (2): the phase of an event at its target.
  """
  @spec at_target() :: 2
  def at_target, do: @at_target

  @doc """
  The constant `Event.BUBBLING_PHASE` (3): the phase of an event at an
  ancestor of its target, after the target.
  """
  @spec bubbling_phase() :: 3
  def bubbling_phase, do: @bubbling_phase

  @doc """
  Makes an event, as the constructor `new Event(type, eventInitDict)`.

  ## Options

    * `:bubbles`, `:cancelable`, and `:composed` - the members of
      `EventInit`. The default is `false`.
  """
  @spec new(String.t() | atom(), keyword()) :: t()
  def new(type, opts \\ []),
    do: __new__(type, Keyword.take(opts, [:bubbles, :cancelable, :composed]))

  @doc false
  # An event with the fields of a dispatch: the options of `new/2`, and
  # `:target` and `:current_target` (the default is the target). The
  # steps "inner event creation steps" set the initialized flag.
  @spec __new__(String.t() | atom(), keyword()) :: t()
  def __new__(type, opts) do
    target = Keyword.get(opts, :target)
    flags = :atomics.new(@slots, signed: false)
    :atomics.put(flags, @initialized, 1)

    %__MODULE__{
      type: to_string(type),
      target: target,
      current_target: Keyword.get(opts, :current_target, target),
      bubbles: Keyword.get(opts, :bubbles, false) == true,
      cancelable: Keyword.get(opts, :cancelable, false) == true,
      composed: Keyword.get(opts, :composed, false) == true,
      time_stamp: Web.Performance.now(),
      flags: flags
    }
  end

  @doc false
  # An event that the library makes, as "create an event" of the DOM
  # Standard: `isTrusted` is true.
  @spec __create__(String.t() | atom(), keyword()) :: t()
  def __create__(type, opts \\ []), do: %{__new__(type, opts) | is_trusted: true}

  @doc """
  Returns the target of the event, as the legacy attribute `srcElement`.
  """
  @spec src_element(event()) :: term()
  def src_element(%{target: target}), do: target

  @doc """
  Returns the object whose listener runs now, as the attribute
  `currentTarget`. It is `nil` when no dispatch runs.
  """
  @spec current_target(event()) :: term()
  def current_target(%{current_target: current_target} = event) do
    if event_phase(event) == @none, do: nil, else: current_target
  end

  @doc """
  Returns the objects on the path of the event, as `composedPath()`. An
  event target has no parent: the path is the current target during a
  dispatch, and empty at other times.
  """
  @spec composed_path(event()) :: list()
  def composed_path(event) do
    case current_target(event) do
      nil -> []
      target -> [target]
    end
  end

  @doc """
  Returns the phase of the event, as the attribute `eventPhase`: `none/0`
  when no dispatch runs, and `at_target/0` during a dispatch. An event
  target of this library has no parent, thus the phase is never
  `capturing_phase/0` or `bubbling_phase/0`.

  ## Examples

      iex> Web.Event.event_phase(Web.Event.new("x")) == Web.Event.none()
      true
  """
  @spec event_phase(event()) :: 0 | 1 | 2 | 3
  def event_phase(%{flags: flags}) when flags != nil, do: :atomics.get(flags, @phase)
  def event_phase(_event), do: @none

  @doc """
  Stops the dispatch to other objects, as `stopPropagation()`.
  """
  @spec stop_propagation(event()) :: :ok
  def stop_propagation(event), do: set(event, @stop_propagation)

  @doc """
  Stops the dispatch to the listeners after the listener that runs now, as
  `stopImmediatePropagation()`.
  """
  @spec stop_immediate_propagation(event()) :: :ok
  def stop_immediate_propagation(event) do
    set(event, @stop_propagation)
    set(event, @stop_immediate_propagation)
  end

  @doc """
  Returns `true` after `stop_propagation/1`, as the legacy attribute
  `cancelBubble`.
  """
  @spec cancel_bubble?(event()) :: boolean()
  def cancel_bubble?(event), do: set?(event, @stop_propagation)

  @doc """
  Sets the stop propagation flag when the value is `true`, as the setter of
  the legacy attribute `cancelBubble`.
  """
  @spec cancel_bubble(event(), boolean()) :: :ok
  def cancel_bubble(event, true), do: stop_propagation(event)
  def cancel_bubble(_event, _value), do: :ok

  @doc """
  Cancels the event, as `preventDefault()`. The call has no effect for an
  event that is not cancelable, and in a listener with the option
  `passive: true`.
  """
  @spec prevent_default(event()) :: :ok
  def prevent_default(%{cancelable: true} = event) do
    if set?(event, @in_passive_listener), do: :ok, else: set(event, @canceled)
  end

  def prevent_default(_event), do: :ok

  @doc """
  Returns `true` when a listener canceled the event, as the attribute
  `defaultPrevented`.
  """
  @spec default_prevented?(event()) :: boolean()
  def default_prevented?(event), do: set?(event, @canceled)

  @doc """
  Returns `false` when a listener canceled the event, as the legacy
  attribute `returnValue`.
  """
  @spec return_value?(event()) :: boolean()
  def return_value?(event), do: not default_prevented?(event)

  @doc """
  Cancels the event when the value is `false`, as the setter of the legacy
  attribute `returnValue`.
  """
  @spec return_value(event(), boolean()) :: :ok
  def return_value(event, false), do: prevent_default(event)
  def return_value(_event, _value), do: :ok

  @doc """
  Initializes the event again, as the legacy `initEvent(type, bubbles,
  cancelable)`. Returns the new event. During a dispatch, the event does
  not change.

  The steps "initialize" set the initialized flag. An event with no flags,
  such as `%Web.Event{type: "x"}`, gets its flags.
  """
  @spec init_event(event(), String.t() | atom(), boolean(), boolean()) :: event()
  def init_event(event, type, bubbles \\ false, cancelable \\ false) do
    if set?(event, @dispatch) do
      event
    else
      flags = Map.get(event, :flags) || :atomics.new(@slots, signed: false)
      :atomics.put(flags, @initialized, 1)

      for slot <- [@stop_propagation, @stop_immediate_propagation, @canceled],
          do: :atomics.put(flags, slot, 0)

      %{
        event
        | type: to_string(type),
          bubbles: bubbles == true,
          cancelable: cancelable == true,
          is_trusted: false,
          target: nil,
          flags: flags
      }
    end
  end

  @doc false
  # The steps of a dispatch: see `Web.Internal.EventTarget.Dispatch`.
  @spec __flag__(
          event(),
          :stop_propagation | :stop_immediate | :dispatch | :passive | :initialized
        ) :: boolean()
  def __flag__(event, name), do: set?(event, slot(name))

  @doc false
  @spec __put_flag__(event(), :dispatch | :passive | :stop_propagation | :stop_immediate, 0 | 1) ::
          :ok
  def __put_flag__(%{flags: flags}, name, value), do: :atomics.put(flags, slot(name), value)

  @doc false
  @spec __put_phase__(event(), 0 | 1 | 2 | 3) :: :ok
  def __put_phase__(%{flags: flags}, phase), do: :atomics.put(flags, @phase, phase)

  defp slot(:stop_propagation), do: @stop_propagation
  defp slot(:stop_immediate), do: @stop_immediate_propagation
  defp slot(:dispatch), do: @dispatch
  defp slot(:passive), do: @in_passive_listener
  defp slot(:initialized), do: @initialized

  defp set(%{flags: flags}, slot) when flags != nil, do: :atomics.put(flags, slot, 1)
  defp set(_event, _slot), do: :ok

  defp set?(%{flags: flags}, slot) when flags != nil, do: :atomics.get(flags, slot) == 1
  defp set?(_event, _slot), do: false
end
