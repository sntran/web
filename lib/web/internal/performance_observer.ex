defmodule Web.Internal.PerformanceObserver do
  @moduledoc false

  # The server of one `Web.PerformanceObserver`, and the steps of the
  # Performance Timeline Standard that run in the observed process. The
  # specification is `tla/PerformanceObserver.tla`.
  #
  # ## The processes
  #
  # The Standard has one event loop for a global object. Here the global
  # object is a process: the entries of `Web.Performance` are the state of
  # the process that makes them. Each observer is two processes:
  #
  #   * the server keeps the state of the observer: the observer buffer,
  #     the observer type, the flag "requires dropped entries", and the
  #     registered performance observer of each observed process. It never
  #     runs the code of a user, thus it always answers;
  #   * the callback process runs the callback, one task at a time. It is a
  #     `Web.Internal.EventTarget.Runner`, as the listener process of a
  #     message port.
  #
  # ## The observed process
  #
  # The process that calls `observe/2` is the observed process. Its process
  # dictionary has the list of the observers that it sends its entries to.
  # The step "queue a PerformanceEntry" sends the entry to each of them, and
  # does not wait. The server keeps the options of each observed process,
  # and adds an entry to the observer buffer only when the options of its
  # process have the type of the entry. Thus a disconnect from a different
  # process stops the entries, although the list of the observed process
  # still has the observer.
  #
  # The messages from one process arrive in their sequence. Thus an entry
  # comes to the server before each later call of the process that made
  # it, for example `take_records/1` or `disconnect/1`.
  #
  # ## The task
  #
  # The steps "queue the PerformanceObserver task" send one task to the
  # callback process, and set the flag "task queued". The task takes the
  # observer buffer from the server when it runs, not when the server sends
  # it. Thus `take_records/1` and `disconnect/1` take the entries that a
  # task did not take, as in the Standard. The flag goes down when the task
  # takes the buffer, thus the mailbox of the callback process has one task
  # or none.
  #
  # ## The lifetime
  #
  # The owner is the process that made the observer. The server stops when
  # the owner stops. The callback process then drops each task that it did
  # not start. The server monitors each observed process, and removes its
  # options when it stops. The entries of that process in the buffer stay.

  use GenServer, restart: :temporary

  require Logger

  alias Web.AsyncContext.Snapshot
  alias Web.DOMException
  alias Web.Internal.EventTarget.Runner
  alias Web.Internal.MessageTarget
  alias Web.PerformanceObserver
  alias Web.PerformanceObserverEntryList

  # The frozen array of supported entry types: the types of the entries
  # that the library makes, in alphabetical order.
  @supported_entry_types ["mark", "measure"]

  @observers_key {__MODULE__, :observers}

  @spec supported_entry_types() :: [String.t()]
  def supported_entry_types, do: @supported_entry_types

  # ---------------------------------------------------------------------------
  # Functions for the process that has a handle
  # ---------------------------------------------------------------------------

  @doc "Starts the server of a new observer. `owner` keeps it alive."
  @spec start(PerformanceObserver.callback(), pid()) :: PerformanceObserver.t()
  def start(callback, owner) when is_pid(owner) do
    token = make_ref()
    pid = MessageTarget.start_server(__MODULE__, {owner, token, callback})
    %PerformanceObserver{address: pid, token: token}
  end

  @doc """
  The steps of `observe(options)`. The calling process is the observed
  process: its entries go to the observer.
  """
  @spec observe(PerformanceObserver.t(), keyword()) :: :ok
  def observe(%PerformanceObserver{} = observer, options) do
    request = options |> init!() |> request()

    case MessageTarget.call(observer, {:observe, self(), request}) do
      {:registered, ignored} ->
        add_observer(observer)
        if ignored != [], do: warn("ignores the entry types #{inspect(ignored)}")
        :ok

      {:aborted, ignored} ->
        warn(
          "does not observe: the options have no supported entry type, got: #{inspect(ignored)}"
        )

      :invalid_modification ->
        raise DOMException,
          name: "InvalidModificationError",
          message:
            "An observer that observes with :entry_types cannot observe with :type, " <>
              "and an observer that observes with :type cannot observe with :entry_types."

      # The observer stopped with its owner: the call has no effect.
      {:error, _reason} ->
        :ok
    end
  end

  @spec disconnect(PerformanceObserver.t()) :: :ok
  def disconnect(%PerformanceObserver{} = observer) do
    _reply = MessageTarget.call(observer, :disconnect)
    :ok
  end

  @spec take_records(PerformanceObserver.t()) :: [Web.Performance.entry()]
  def take_records(%PerformanceObserver{} = observer) do
    case MessageTarget.call(observer, :take_records) do
      {:ok, entries} -> entries
      {:error, _reason} -> []
    end
  end

  # The members of `PerformanceObserverInit`, as Web IDL converts a
  # dictionary. A member with the value `nil` is not present, as a member
  # with the value `undefined`. The function ignores each other option.
  defp init!(options) do
    if not Keyword.keyword?(options) do
      raise Web.TypeError, "The options must be a keyword list, got: #{inspect(options)}"
    end

    %{
      buffered: member(options, :buffered, &(&1 != false)),
      entry_types: member(options, :entry_types, &entry_types!/1),
      type: member(options, :type, &Web.Performance.__text__/1)
    }
  end

  defp member(options, key, convert) do
    case Keyword.get(options, key) do
      nil -> nil
      value -> convert.(value)
    end
  end

  defp entry_types!(types) when is_list(types), do: Enum.map(types, &Web.Performance.__text__/1)

  defp entry_types!(types) do
    raise Web.TypeError, "The option :entry_types must be a list, got: #{inspect(types)}"
  end

  # Steps 2 and 3 of `observe(options)`. The observer does the other steps.
  defp request(%{entry_types: nil, type: nil}) do
    raise Web.TypeError, "The options must have :entry_types or :type."
  end

  defp request(%{entry_types: types, type: nil, buffered: nil}) when is_list(types) do
    {:multiple, types}
  end

  defp request(%{entry_types: types}) when is_list(types) do
    raise Web.TypeError, "The option :entry_types cannot have other options."
  end

  # Step 7.4: the entries of the performance entry buffer, in the sequence
  # in which the process made them. The should add entry steps of the
  # registry return true for a mark and a measure.
  defp request(%{type: type, buffered: true}) do
    {:single, type, Enum.filter(Web.Performance.__entries__(), &(&1.entry_type == type))}
  end

  defp request(%{type: type}), do: {:single, type, nil}

  # The observed process keeps the observer in its list. The function also
  # removes each observer whose server stopped. The server keeps the
  # options of the process: the list only tells where the entries go.
  defp add_observer(%PerformanceObserver{address: pid, token: token}) do
    observers = Enum.filter(Process.get(@observers_key, []), &running?(elem(&1, 0)))

    observers =
      if List.keymember?(observers, pid, 0), do: observers, else: observers ++ [{pid, token}]

    Process.put(@observers_key, observers)
    :ok
  end

  # The VM tells only for a process of this node if it runs. The list
  # keeps the observer of a different node.
  defp running?(pid) when node(pid) == node(), do: Process.alive?(pid)
  defp running?(_pid), do: true

  # The Standard tells the user agent to notify the developer when the
  # observer ignores an entry type, and when the steps abort.
  defp warn(text) do
    Logger.warning(
      "The PerformanceObserver #{text}. The supported entry types are " <>
        "#{inspect(@supported_entry_types)}."
    )
  end

  # ---------------------------------------------------------------------------
  # Functions for the observed process
  # ---------------------------------------------------------------------------

  @doc """
  The steps "queue a PerformanceEntry", in the process that made the entry:
  each observer of the process gets the entry. The function does not wait.
  """
  @spec queue_entry(Web.Performance.entry()) :: :ok
  def queue_entry(entry) do
    Enum.each(Process.get(@observers_key, []), fn {pid, token} ->
      send(pid, {:queue_entry, token, self(), entry})
    end)
  end

  # ---------------------------------------------------------------------------
  # Functions for the callback process
  # ---------------------------------------------------------------------------

  @doc false
  # The task of "queue the PerformanceObserver task", in the callback
  # process. The task gives no event to the runner.
  def run_task(%PerformanceObserver{} = observer, callback) do
    case MessageTarget.call(observer, :take_buffer) do
      {:ok, entries, options} ->
        list = %PerformanceObserverEntryList{entries: entries}
        invoke(callback, [list, observer, options])

      # The buffer was empty, or the observer stopped.
      _no_entries ->
        :ok
    end

    nil
  end

  # The callback gets as many of the arguments as its arity. The steps
  # "invoke" with "report": an exception goes to the log.
  defp invoke(callback, arguments) do
    {:arity, arity} = Function.info(callback, :arity)
    apply(callback, Enum.take(arguments, arity))
  catch
    kind, reason ->
      Logger.error(
        "The callback of a PerformanceObserver failed.\n" <>
          Exception.format(kind, reason, __STACKTRACE__)
      )
  end

  # ---------------------------------------------------------------------------
  # The server
  # ---------------------------------------------------------------------------

  def start_link(argument), do: GenServer.start_link(__MODULE__, argument)

  @impl true
  def init({owner, token, callback}) do
    Process.flag(:message_queue_data, :off_heap)
    gate = :atomics.new(1, signed: false)
    {:ok, runner} = Runner.start_link(gate)

    {:ok,
     %{
       token: token,
       callback: callback,
       owner_monitor: Process.monitor(owner),
       runner: runner,
       gate: gate,
       # The observer buffer, with the last entry first.
       buffer: [],
       observer_type: :undefined,
       requires_dropped_entries: false,
       # The registered performance observer of each observed process: its
       # monitor and its options list.
       registrations: %{},
       task_queued: false
     }}
  end

  @impl true
  def handle_call({token, request}, _from, %{token: token} = state) do
    request(request, state)
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :detached}, state}

  @impl true
  def handle_info({:queue_entry, token, pid, entry}, %{token: token} = state) do
    {:noreply, add_entry(state, pid, entry)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_monitor: ref} = state) do
    {:stop, :normal, state}
  end

  # An observed process stopped. Its entries in the buffer stay.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | registrations: Map.delete(state.registrations, pid)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The callback process drops each task that it did not start. A callback
  # that runs now completes.
  @impl true
  def terminate(_reason, state) do
    :atomics.put(state.gate, 1, 1)
    Runner.stop(state.runner)
  end

  # ---------------------------------------------------------------------------
  # Requests
  # ---------------------------------------------------------------------------

  # The steps 4 to 7 of `observe(options)`.
  defp request({:observe, pid, request}, state) do
    case observer_type(state.observer_type, request) do
      {:ok, observer_type} ->
        state = %{state | observer_type: observer_type, requires_dropped_entries: true}
        register(state, pid, request)

      :error ->
        {:reply, :invalid_modification, state}
    end
  end

  # The steps of `disconnect()`.
  defp request(:disconnect, state) do
    Enum.each(state.registrations, fn {_pid, %{monitor: ref}} ->
      Process.demonitor(ref, [:flush])
    end)

    {:reply, :ok, %{state | registrations: %{}, buffer: []}}
  end

  # The steps of `takeRecords()`.
  defp request(:take_records, state) do
    {:reply, {:ok, Enum.reverse(state.buffer)}, %{state | buffer: []}}
  end

  # The substeps of the task for this observer: the callback process asks
  # for them when the task runs.
  defp request(:take_buffer, %{buffer: []} = state) do
    {:reply, :empty, %{state | task_queued: false}}
  end

  defp request(:take_buffer, state) do
    # The registry gives the types "mark" and "measure" an infinite
    # maxBufferSize: the dropped entries count of each type is 0.
    options =
      if state.requires_dropped_entries, do: %{dropped_entries_count: 0}, else: %{}

    entries = Enum.reverse(state.buffer)
    state = %{state | buffer: [], task_queued: false, requires_dropped_entries: false}
    {:reply, {:ok, entries, options}, state}
  end

  # Step 4: update or check the observer type.
  defp observer_type(:undefined, {:multiple, _types}), do: {:ok, :multiple}
  defp observer_type(:undefined, {:single, _type, _entries}), do: {:ok, :single}
  defp observer_type(:multiple, {:multiple, _types}), do: {:ok, :multiple}
  defp observer_type(:single, {:single, _type, _entries}), do: {:ok, :single}
  defp observer_type(_observer_type, _request), do: :error

  # Step 6: the observer type is "multiple". The options list has only the
  # options of this call. An unsupported type is ignored, and with no type
  # left the steps abort.
  defp register(state, pid, {:multiple, types}) do
    {supported, ignored} = Enum.split_with(types, &(&1 in @supported_entry_types))

    if supported == [] do
      {:reply, {:aborted, ignored}, state}
    else
      state = put_options(state, pid, fn _options -> [%{entry_types: supported}] end)
      {:reply, {:registered, ignored}, state}
    end
  end

  # Step 7: the observer type is "single". The options with the same type
  # take the place of the old options. Other options are added.
  defp register(state, _pid, {:single, type, _entries}) when type not in @supported_entry_types do
    {:reply, {:aborted, [type]}, state}
  end

  defp register(state, pid, {:single, type, buffered}) do
    state =
      put_options(state, pid, fn options ->
        item = %{type: type, buffered: buffered != nil}

        case Enum.find_index(options, &(Map.get(&1, :type) == type)) do
          nil -> options ++ [item]
          index -> List.replace_at(options, index, item)
        end
      end)

    state =
      case buffered do
        nil -> state
        entries -> queue_task(%{state | buffer: Enum.reverse(entries, state.buffer)})
      end

    {:reply, {:registered, []}, state}
  end

  defp put_options(state, pid, update) do
    registration =
      case state.registrations do
        %{^pid => registration} -> registration
        _new -> %{monitor: Process.monitor(pid), options: []}
      end

    registration = %{registration | options: update.(registration.options)}
    %{state | registrations: Map.put(state.registrations, pid, registration)}
  end

  # The steps "queue a PerformanceEntry", in the server: the observer is
  # an interested observer when an options item of the process has the
  # type of the entry.
  defp add_entry(state, pid, entry) do
    case state.registrations do
      %{^pid => %{options: options}} ->
        if Enum.any?(options, &observes?(&1, entry.entry_type)) do
          queue_task(%{state | buffer: [entry | state.buffer]})
        else
          state
        end

      _not_observed ->
        state
    end
  end

  defp observes?(%{entry_types: types}, type), do: type in types
  defp observes?(%{type: observed}, type), do: observed == type

  # The steps "queue the PerformanceObserver task". The task runs in the
  # empty context, as the AsyncContext proposal specifies for the
  # callbacks of an observer.
  defp queue_task(%{task_queued: true} = state), do: state

  defp queue_task(state) do
    observer = %PerformanceObserver{address: self(), token: state.token}

    Runner.run_task(state.runner, %{
      build: {__MODULE__, :run_task, [observer, state.callback]},
      snapshot: %Snapshot{},
      target: observer,
      store: nil
    })

    %{state | task_queued: true}
  end
end
