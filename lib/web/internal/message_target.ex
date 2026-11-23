defmodule Web.Internal.MessageTarget do
  @moduledoc false

  # The part that a message port and a broadcast channel have in common. A
  # socket uses the handle and the supervisor of this module too.
  #
  # Each port and each channel is three processes:
  #
  #   * the server keeps the state and answers the calls. It never runs the
  #     code of a user, thus it always answers;
  #   * the listener process fires the events of the port or the channel,
  #     one at a time. It is a `Web.Internal.EventTarget.Runner`;
  #   * the store keeps the listeners and the event handlers. It is a
  #     `Web.Internal.EventTarget.Store` that stops with the listener
  #     process.
  #
  # The server sends to the listener process and does not wait. A listener
  # can thus call each function of its port or channel.
  #
  # The listener steps are those of a target of `Web.EventTarget.new/0`:
  # the process that calls `dispatch_event/2` runs the listeners, before
  # the function returns, and the listener process runs them for the events
  # that the port or the channel fires. See
  # `Web.Internal.EventTarget.Dispatch`.
  #
  # A handle has the pid of the server and a token. The server refuses a
  # request that does not have its token, thus only a process that got the
  # handle can use the port or the channel. A request to a server that
  # stopped has no effect: the port or the channel is closed, and it has no
  # listener.

  alias Web.AsyncContext.Snapshot
  alias Web.EventTarget
  alias Web.Internal.EventTarget.Runner
  alias Web.Internal.EventTarget.Store

  defstruct [:listener, :gate, :store, :handle]

  @type t :: %__MODULE__{
          listener: pid(),
          gate: :atomics.atomics_ref(),
          store: pid(),
          handle: struct()
        }

  @type handle :: %{
          required(:address) => pid(),
          required(:token) => reference(),
          optional(atom()) => term()
        }

  @supervisor Web.HandleSupervisor

  # ---------------------------------------------------------------------------
  # Functions for the server
  # ---------------------------------------------------------------------------

  @doc "Starts a server below the supervisor of the application."
  @spec start_server(module(), term()) :: pid()
  def start_server(module, argument) do
    {:ok, pid} = DynamicSupervisor.start_child(@supervisor, {module, argument})
    pid
  end

  @doc """
  Starts the listener process and the store of a handle. The server calls
  this. The events go to `handle`.
  """
  @spec start(struct()) :: t()
  def start(handle) do
    gate = :atomics.new(1, signed: false)
    {:ok, listener} = Runner.start_link(gate)
    store = Store.start(listener, :with_owner)
    %__MODULE__{listener: listener, gate: gate, store: store, handle: handle}
  end

  @doc """
  Stops the events immediately: the listener process drops each event that
  it did not start, and stops after the event that it does now. The store
  stops after it.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{listener: listener, gate: gate}) do
    :atomics.put(gate, 1, 1)
    Runner.stop(listener)
  end

  @doc """
  Does a request that a port and a channel have in common: the store of the
  listeners. Returns `:unknown` for each other request.
  """
  @spec request(t(), term()) :: {:reply, term(), t()} | :unknown
  def request(%__MODULE__{} = target, :store), do: {:reply, {:ok, target.store}, target}
  def request(%__MODULE__{}, _request), do: :unknown

  @doc """
  Gives a task to the listener process. The function of `build` makes the
  event in that process.
  """
  @spec run(t(), {module(), atom(), list()}, Snapshot.t(), {pid(), term()} | nil) :: :ok
  def run(%__MODULE__{} = target, build, snapshot, reply_to \\ nil) do
    task = %{build: build, snapshot: snapshot, target: target.handle, store: target.store}
    task = if reply_to, do: Map.put(task, :reply_to, reply_to), else: task
    Runner.run_task(target.listener, task)
  end

  # ---------------------------------------------------------------------------
  # Functions for the process that has a handle
  # ---------------------------------------------------------------------------

  @doc """
  Sends a request to the server of a handle, and returns its answer.

  Returns `{:error, :closed}` when the server stopped, and
  `{:error, :detached}` when the handle does not have the token of the
  server.
  """
  @spec call(handle(), term()) :: term()
  def call(%{address: pid, token: token}, request) when is_pid(pid) and is_reference(token) do
    GenServer.call(pid, {token, request}, :infinity)
  catch
    :exit, _reason -> {:error, :closed}
  end

  def call(_handle, _request), do: {:error, :detached}

  # The store of the listeners, or `nil` when the port or the channel is
  # closed or detached.
  defp store(handle) do
    case call(handle, :store) do
      {:ok, store} -> store
      {:error, _reason} -> nil
    end
  end

  @spec get_handler(handle(), String.t()) :: EventTarget.callback() | nil
  def get_handler(handle, type) do
    case store(handle) do
      nil -> nil
      store -> Store.request(store, {:get_handler, type}, nil)
    end
  end

  @spec set_handler(handle(), String.t(), EventTarget.callback() | nil) :: :ok
  def set_handler(handle, type, callback) do
    with store when store != nil <- store(handle) do
      _ok = Store.request(store, {:set_handler, type, callback}, :ok)
    end

    :ok
  end

  @spec add_event_listener(handle(), String.t() | atom(), function(), map()) :: :ok
  def add_event_listener(handle, type, callback, options),
    do: EventTarget.__add__(store(handle), type, callback, options)

  @spec remove_event_listener(handle(), String.t() | atom(), function(), boolean()) :: :ok
  def remove_event_listener(handle, type, callback, capture),
    do: EventTarget.__remove__(store(handle), type, callback, capture)

  # The steps of `dispatchEvent(event)`, in the calling process.
  @spec dispatch_event(handle(), Web.Event.event()) :: boolean()
  def dispatch_event(handle, event), do: EventTarget.__dispatch__(handle, store(handle), event)
end
