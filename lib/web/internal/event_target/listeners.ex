defmodule Web.Internal.EventTarget.Listeners do
  @moduledoc false

  # The event listener list of an event target, as the DOM Standard
  # specifies it, and the event handlers of the HTML Standard. The list is a
  # value: the process of a target keeps it. See
  # `Web.Internal.EventTarget.Store` and `Web.AbortSignal`.
  #
  # Each listener belongs to the process that added it, its owner. The
  # process of the target monitors the owners: when an owner stops, its
  # listeners go away. Thus a target with no owner and no listener has no
  # use, and its process can stop.
  #
  # An event handler, such as `onabort`, is a listener with the callback
  # `:handler`. It has its place in the list from the time when it gets a
  # callback, until it gets `nil`, as the HTML Standard specifies.

  defstruct entries: [], handlers: %{}, next_id: 0

  @type callback :: (term() -> any()) | (-> any())

  @type entry :: %{
          id: non_neg_integer(),
          type: String.t(),
          callback: callback() | :handler,
          capture: boolean(),
          passive: boolean(),
          once: boolean(),
          owner: pid()
        }

  @type t :: %__MODULE__{
          entries: [entry()],
          handlers: %{optional(String.t()) => callback()},
          next_id: non_neg_integer()
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  The steps "add an event listener", from step 5: a listener with the same
  type, callback, and capture is not added again. Returns
  `{:added, id, list}` or `{:exists, list}`.
  """
  @spec add(t(), String.t(), callback(), map(), pid()) ::
          {:added, non_neg_integer(), t()} | {:exists, t()}
  def add(%__MODULE__{} = list, type, callback, options, owner) do
    capture = Map.get(options, :capture, false) == true

    if Enum.any?(list.entries, &same?(&1, type, callback, capture)) do
      {:exists, list}
    else
      entry = %{
        id: list.next_id,
        type: type,
        callback: callback,
        capture: capture,
        passive: Map.get(options, :passive, false) == true,
        once: Map.get(options, :once, false) == true,
        owner: owner
      }

      {:added, entry.id, %{list | entries: list.entries ++ [entry], next_id: list.next_id + 1}}
    end
  end

  @doc "The steps of `removeEventListener`: the listener with this type, callback, and capture."
  @spec remove(t(), String.t(), callback(), boolean()) :: t()
  def remove(%__MODULE__{} = list, type, callback, capture) do
    %{list | entries: Enum.reject(list.entries, &same?(&1, type, callback, capture))}
  end

  @doc "Removes the listener with this id, for example at the abort of its signal."
  @spec remove_id(t(), non_neg_integer()) :: t()
  def remove_id(%__MODULE__{} = list, id) do
    %{list | entries: Enum.reject(list.entries, &(&1.id == id))}
  end

  @doc "Removes the listeners and the event handlers of a process that stopped."
  @spec remove_owner(t(), pid()) :: t()
  def remove_owner(%__MODULE__{} = list, owner) do
    {gone, kept} = Enum.split_with(list.entries, &(&1.owner == owner))
    types = for %{callback: :handler, type: type} <- gone, do: type
    %{list | entries: kept, handlers: Map.drop(list.handlers, types)}
  end

  @doc "The processes that own a listener."
  @spec owners(t()) :: MapSet.t(pid())
  def owners(%__MODULE__{entries: entries}), do: MapSet.new(entries, & &1.owner)

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{entries: entries}), do: entries == []

  @doc """
  The clone of the listeners of a type, for the steps "invoke". Each item
  has the id, the capture, and the passive of a listener.
  """
  @spec clone(t(), String.t()) :: [
          %{id: non_neg_integer(), capture: boolean(), passive: boolean()}
        ]
  def clone(%__MODULE__{entries: entries}, type) do
    for %{type: ^type} = entry <- entries, do: Map.take(entry, [:id, :capture, :passive])
  end

  @doc """
  The start of the call of one listener of a clone, in the steps "inner
  invoke". Returns `:removed` for a listener that was removed after the
  clone. A listener with the option `once` is removed now. Returns
  `{:ok, callback, list}`: the callback of an event handler is its value
  now.
  """
  @spec begin(t(), non_neg_integer()) :: {:ok, callback() | nil, t()} | {:removed, t()}
  def begin(%__MODULE__{} = list, id) do
    case Enum.find(list.entries, &(&1.id == id)) do
      nil ->
        {:removed, list}

      entry ->
        list = if entry.once, do: remove_id(list, id), else: list
        {:ok, callback(list, entry), list}
    end
  end

  @doc """
  Sets the event handler of a type. A callback that is `nil` removes it
  and its place in the list.
  """
  @spec set_handler(t(), String.t(), callback() | nil, pid()) :: t()
  def set_handler(%__MODULE__{} = list, type, nil, _owner) do
    entries = Enum.reject(list.entries, &(&1.type == type and &1.callback == :handler))
    %{list | entries: entries, handlers: Map.delete(list.handlers, type)}
  end

  def set_handler(%__MODULE__{} = list, type, callback, owner) do
    list = %{list | handlers: Map.put(list.handlers, type, callback)}

    case add(list, type, :handler, %{}, owner) do
      {:added, _id, list} -> list
      {:exists, list} -> list
    end
  end

  @spec get_handler(t(), String.t()) :: callback() | nil
  def get_handler(%__MODULE__{handlers: handlers}, type), do: Map.get(handlers, type)

  @doc """
  Does a request of a client of the process of a target. The process
  calls this function with the pid of the client. Returns the answer and
  the new list.
  """
  @spec handle(t(), term(), pid()) :: {term(), t()}
  def handle(list, {:add, type, callback, options}, client) do
    case add(list, type, callback, options, client) do
      {:added, id, list} -> {{:added, id}, list}
      {:exists, list} -> {:exists, list}
    end
  end

  def handle(list, {:remove, type, callback, capture}, _client),
    do: {:ok, remove(list, type, callback, capture)}

  def handle(list, {:remove_id, id}, _client), do: {:ok, remove_id(list, id)}
  def handle(list, {:clone, type}, _client), do: {clone(list, type), list}

  def handle(list, {:begin, id}, _client) do
    case begin(list, id) do
      {:ok, callback, list} -> {{:ok, callback}, list}
      {:removed, list} -> {:removed, list}
    end
  end

  def handle(list, {:set_handler, type, callback}, client),
    do: {:ok, set_handler(list, type, callback, client)}

  def handle(list, {:get_handler, type}, _client), do: {get_handler(list, type), list}

  @doc """
  Monitors each owner of a listener, and stops the monitors of the
  processes that own no listener. `monitors` maps a pid to its monitor.
  """
  @spec monitor_owners(t(), %{optional(pid()) => reference()}) :: %{
          optional(pid()) => reference()
        }
  def monitor_owners(list, monitors) do
    owners = owners(list)

    monitors =
      Enum.reduce(owners, monitors, fn pid, acc ->
        Map.put_new_lazy(acc, pid, fn -> Process.monitor(pid) end)
      end)

    {gone, kept} = Map.split_with(monitors, fn {pid, _ref} -> not MapSet.member?(owners, pid) end)
    Enum.each(gone, fn {_pid, ref} -> Process.demonitor(ref, [:flush]) end)
    kept
  end

  defp callback(list, %{callback: :handler, type: type}), do: get_handler(list, type)
  defp callback(_list, %{callback: callback}), do: callback

  # Two functions are the same callback when they are equal: they come from
  # the same code, and they have the same values of the variables that they
  # use.
  defp same?(entry, type, callback, capture) do
    entry.type == type and entry.callback === callback and entry.capture == capture
  end
end
