defmodule Web.Internal.MessageTarget do
  @moduledoc false

  # The part that a message port and a broadcast channel have in common. A
  # socket uses the handle and the supervisor of this module too.
  #
  # Each port and each channel is two processes:
  #
  #   * the server keeps the state and answers the calls. It never runs the
  #     code of a user, thus it always answers;
  #   * the listener process keeps the listeners and runs them, one event at
  #     a time. It is a `Web.Internal.EventTarget.Server`.
  #
  # The server sends to the listener process and does not wait. A listener
  # can thus call each function of its port or channel.
  #
  # A handle has the pid of the server and a token. The server refuses a
  # request that does not have its token, thus only a process that got the
  # handle can use the port or the channel. A request to a server that
  # stopped has no effect: the port or the channel is closed.

  alias Web.AsyncContext.Snapshot
  alias Web.Internal.EventTarget.Server, as: Listener

  defstruct [:listener, :gate, handlers: %{}]

  @type t :: %__MODULE__{
          listener: pid(),
          gate: :atomics.atomics_ref(),
          handlers: %{optional(String.t()) => Web.EventTarget.callback()}
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

  @doc "Starts the listener process of a handle. The server calls this."
  @spec start(struct()) :: t()
  def start(handle) do
    gate = :atomics.new(1, signed: false)
    {:ok, listener} = Listener.start_link(target: handle, callback_module: nil, gate: gate)
    %__MODULE__{listener: listener, gate: gate}
  end

  @doc """
  Stops the events immediately: the listener process drops each event that
  it did not start, and stops after the event that it does now.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{listener: listener, gate: gate}) do
    :atomics.put(gate, 1, 1)
    Listener.stop(listener)
  end

  @doc """
  Does a request that a port and a channel have in common. Returns
  `:unknown` for each other request.
  """
  @spec request(t(), term()) :: {:reply, term(), t()} | :unknown
  def request(%__MODULE__{} = target, {:set_handler, type, callback}) do
    Listener.set_handler(target.listener, type, callback)

    handlers =
      if callback do
        Map.put(target.handlers, type, callback)
      else
        Map.delete(target.handlers, type)
      end

    {:reply, :ok, %{target | handlers: handlers}}
  end

  def request(%__MODULE__{} = target, {:get_handler, type}) do
    {:reply, Map.get(target.handlers, type), target}
  end

  def request(%__MODULE__{} = target, {:add_listener, type, callback, options}) do
    GenServer.cast(target.listener, {:add_event_listener, type, callback, options})
    {:reply, :ok, target}
  end

  def request(%__MODULE__{} = target, {:remove_listener, type, callback}) do
    GenServer.cast(target.listener, {:remove_event_listener, type, callback})
    {:reply, :ok, target}
  end

  def request(%__MODULE__{} = target, {:dispatch, event, snapshot}) do
    GenServer.cast(target.listener, {:dispatch_event, event, snapshot})
    {:reply, :ok, target}
  end

  def request(%__MODULE__{}, _request), do: :unknown

  @doc """
  Gives a task to the listener process. The function of `build` makes the
  event in that process.
  """
  @spec run(t(), {module(), atom(), list()}, Snapshot.t(), {pid(), term()} | nil) :: :ok
  def run(%__MODULE__{listener: listener}, build, snapshot, reply_to \\ nil) do
    task = %{build: build, snapshot: snapshot}
    task = if reply_to, do: Map.put(task, :reply_to, reply_to), else: task
    Listener.run_task(listener, task)
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

  @spec get_handler(handle(), String.t()) :: Web.EventTarget.callback() | nil
  def get_handler(handle, type) do
    case call(handle, {:get_handler, type}) do
      {:error, _reason} -> nil
      callback -> callback
    end
  end

  @spec set_handler(handle(), String.t(), Web.EventTarget.callback() | nil) :: :ok
  def set_handler(handle, type, callback) do
    _reply = call(handle, {:set_handler, type, callback})
    :ok
  end

  @spec add_event_listener(handle(), String.t() | atom(), function(), keyword() | map()) :: :ok
  def add_event_listener(handle, type, callback, options) do
    _reply = call(handle, {:add_listener, type, callback, options})
    :ok
  end

  @spec remove_event_listener(handle(), String.t() | atom(), function()) :: :ok
  def remove_event_listener(handle, type, callback) do
    _reply = call(handle, {:remove_listener, type, callback})
    :ok
  end

  # The steps of `dispatchEvent(event)`: the event is not trusted. The
  # listener process does the dispatch at a later time, thus the caller
  # cannot see the end of a dispatch: the function does not refuse an event
  # that is in a dispatch.
  @spec dispatch_event(handle(), Web.EventTarget.event()) :: boolean()
  def dispatch_event(handle, event) do
    event = if Map.has_key?(event, :is_trusted), do: %{event | is_trusted: false}, else: event
    _reply = call(handle, {:dispatch, event, Snapshot.new()})
    true
  end
end
