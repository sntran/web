defmodule Web.Internal.PerformanceTimeline do
  @moduledoc false

  # The performance timeline of one global object, and the steps of the
  # Performance Timeline Standard for its observers. The specification is
  # `tla/PerformanceObserver.tla`.
  #
  # ## The global object
  #
  # The Standards give each global object a performance entry buffer and a
  # list of registered performance observers. In the library a process is a
  # global object. A process with no observer keeps its buffer in its
  # process dictionary: a mark then costs no message.
  #
  # The callback of an observer runs with the relevant global object of the
  # observer: a mark of the callback is an entry of that global object, and
  # its observers get the entry. The callback runs in a different process,
  # and a process cannot change the process dictionary of a different
  # process. Thus the first observer of a global object moves the buffer of
  # the global object to an ETS table of a server, the timeline server. From
  # then on, each process that acts for the global object writes its
  # entries to the table: the process of the global object, and the
  # callback process.
  #
  # ## The table and the reads
  #
  # The table is an `ordered_set`: a row is `{key, entry, writer}`. The key
  # comes from `:erlang.unique_integer([:monotonic])`, thus the rows are in
  # the sequence in which the processes made the entries. A process writes
  # the table itself, and no read or write waits for a message.
  #
  #   * The process of the global object also keeps its buffer in its
  #     process dictionary, as a process with no observer does. Its reads
  #     use that copy. A write of a different process to the table adds one
  #     to a counter (`:atomics`). The process reads the table again when
  #     the counter is not the counter of its copy: it reads the counter
  #     first, then the table.
  #   * A different process that acts for the global object reads the
  #     table.
  #
  # Thus a read sees each earlier write of the same process.
  #
  # ## The server
  #
  # The server owns the table. It keeps the list of registered performance
  # observers, and the state of each observer of the global object: its
  # callback, its observer buffer, its observer type, and its flag
  # "requires dropped entries". It never runs the code of a user, thus it
  # always answers.
  #
  # A process that adds an entry to the table sends it to the server, and
  # does not wait. The server does the observer part of "queue a
  # PerformanceEntry": the interested observers get the entry. The server
  # keeps the key of the last entry that it got from each process: an entry
  # of a process with a larger key is on its way. A buffered
  # `observe(options)` copies only the entries that the server got. Thus an
  # entry gets to an observer one time: from the buffer, or from the queue,
  # not from the two. The messages from one process arrive in their
  # sequence: a call of the observer (for example `take_records/1`) comes
  # after the earlier entries of the same process.
  #
  # ## The task
  #
  # The global object has one flag "performance observer task queued", and
  # one callback process. The callback process runs one task at a time: it
  # is a `Web.Internal.EventTarget.Runner`. The server sends a task when the
  # flag goes up and the callback process has no task. The task sets the
  # flag down when it starts (step 1 of the task), then takes the observer
  # buffer of each registered observer, one after the other, and invokes
  # the callbacks. At its end it tells the server. A flag that went up
  # during the task gives the next task then. Thus the mailbox of the
  # callback process has no task while a callback runs: a process that
  # examines the processes at rest, as the runner of WPT does, sees the
  # callback process at rest while a callback waits.
  #
  # ## The lifetime
  #
  # The server monitors its global object, and stops when it stops. The
  # table goes away with the server: a later read gives no entry, and a
  # later write has no effect. The callback process then drops the task that
  # it did not start. A callback that runs completes, but its calls of the
  # server have no effect.

  use GenServer, restart: :temporary

  require Logger

  alias Web.AsyncContext.Snapshot
  alias Web.Internal.EventTarget.Runner
  alias Web.PerformanceObserver
  alias Web.PerformanceObserverEntryList

  # The frozen array of supported entry types: the types of the entries
  # that the library makes, in alphabetical order.
  @supported_entry_types ["mark", "measure"]

  # The timeline of the global object for which the process acts, and the
  # role of the process: `:own` for the process of the global object,
  # `:other` for a different process.
  @server_key {__MODULE__, :server}
  # The performance entry buffer of a process with no server, or the copy
  # of the process of the global object, with the last entry first.
  @entries_key {__MODULE__, :entries}
  # The counter of the writes of the other processes when the process of
  # the global object made its copy.
  @version_key {__MODULE__, :version}

  @type entry :: Web.Performance.entry()

  @typedoc """
  The server, the table, and the counter of the writes of the other
  processes, of a global object with an observer.
  """
  @type timeline :: {pid(), :ets.table(), :atomics.atomics_ref()}

  @spec supported_entry_types() :: [String.t()]
  def supported_entry_types, do: @supported_entry_types

  # ---------------------------------------------------------------------------
  # The buffer of the global object of the calling process
  # ---------------------------------------------------------------------------

  @doc """
  The steps "queue a PerformanceEntry", and "add entry to the performance
  entry buffer". The registry gives "mark" and "measure" no buffer limit:
  each entry goes to the buffer. A global object with no server has no
  observer.
  """
  @spec put(entry()) :: :ok
  def put(entry) do
    case Process.get(@server_key) do
      nil ->
        push(entry)

      {timeline, :own} ->
        write(timeline, entry)
        push(entry)

      {timeline, :other} ->
        write(timeline, entry)
        changed(timeline)
    end
  end

  @doc "The performance entry buffer, in the sequence in which the entries came."
  @spec entries() :: [entry()]
  def entries do
    case Process.get(@server_key) do
      nil -> @entries_key |> Process.get([]) |> Enum.reverse()
      {timeline, :own} -> timeline |> own_copy() |> Enum.reverse()
      {{_server, table, _counter}, :other} -> select(table, [{{:_, :"$1", :_}, [], [:"$1"]}])
    end
  end

  @doc """
  Removes the entries of the type, and with the name when it is not `nil`:
  the steps of `clearMarks()` and `clearMeasures()`.
  """
  @spec clear(String.t(), String.t() | nil) :: :ok
  def clear(type, name) do
    case Process.get(@server_key) do
      nil ->
        remove_own(type, name)

      {{_server, table, _counter}, :own} ->
        delete(table, type, name)
        remove_own(type, name)

      {{_server, table, _counter} = timeline, :other} ->
        delete(table, type, name)
        changed(timeline)
    end
  end

  @doc """
  The start time of the mark that the global object made last with the
  name, or `nil`: the steps "convert a mark to a timestamp".
  """
  @spec last_mark(String.t()) :: float() | nil
  def last_mark(name) do
    case Process.get(@server_key) do
      nil -> find_mark(Process.get(@entries_key, []), name)
      {timeline, :own} -> timeline |> own_copy() |> find_mark(name)
      {{_server, table, _counter}, :other} -> last_mark_in(table, name)
    end
  end

  defp push(entry) do
    _previous = Process.put(@entries_key, [entry | Process.get(@entries_key, [])])
    :ok
  end

  defp remove_own(type, name) do
    _previous = Process.put(@entries_key, remove(Process.get(@entries_key, []), type, name))
    :ok
  end

  # The copy of the process of the global object. A write of a different
  # process changed the counter: the process reads the counter, then the
  # table. A later write then changes the counter again.
  defp own_copy({_server, table, counter}) do
    version = :atomics.get(counter, 1)

    if Process.get(@version_key) == version do
      Process.get(@entries_key, [])
    else
      entries = table |> select([{{:_, :"$1", :_}, [], [:"$1"]}]) |> Enum.reverse()
      _previous = Process.put(@entries_key, entries)
      _previous = Process.put(@version_key, version)
      entries
    end
  end

  # The entry goes to the table, then to the server, which does the steps
  # for the observers.
  defp write({server, table, _counter}, entry) do
    key = :erlang.unique_integer([:monotonic])
    true = :ets.insert(table, {key, entry, self()})
    GenServer.cast(server, {:queue, self(), key, entry})
  rescue
    # The table went away with its server.
    ArgumentError -> :ok
  end

  # A different process changed the table.
  defp changed({_server, _table, counter}), do: :atomics.add(counter, 1, 1)

  defp select(table, spec) do
    :ets.select(table, spec)
  rescue
    ArgumentError -> []
  end

  defp delete(table, type, name) do
    pattern = if name == nil, do: %{entry_type: type}, else: %{entry_type: type, name: name}
    _count = :ets.select_delete(table, [{{:_, pattern, :_}, [], [true]}])
    :ok
  rescue
    ArgumentError -> :ok
  end

  # The table is in the sequence of the entries: the search starts at the
  # end.
  defp last_mark_in(table, name) do
    previous_mark(table, :ets.last(table), name)
  rescue
    ArgumentError -> nil
  end

  defp previous_mark(_table, :"$end_of_table", _name), do: nil

  defp previous_mark(table, key, name) do
    case :ets.lookup(table, key) do
      [{_key, %Web.Performance.Mark{name: ^name, start_time: start_time}, _writer}] -> start_time
      _other -> previous_mark(table, :ets.prev(table, key), name)
    end
  end

  # The list has the last entry first.
  defp find_mark(entries, name) do
    Enum.find_value(entries, fn
      %Web.Performance.Mark{name: ^name, start_time: start_time} -> start_time
      _other -> nil
    end)
  end

  defp remove(entries, type, name) do
    Enum.reject(entries, &(&1.entry_type == type and (name == nil or &1.name == name)))
  end

  # ---------------------------------------------------------------------------
  # The global object
  # ---------------------------------------------------------------------------

  @doc """
  The timeline of the global object of the calling process. The function
  starts the server when the global object has none: the buffer of the
  process goes to the table of the server, and stays as the copy of the
  process.
  """
  @spec share() :: timeline()
  def share do
    case Process.get(@server_key) do
      nil ->
        # The buffer of the process stays as its copy.
        entries = Process.get(@entries_key, [])
        {:ok, server} = GenServer.start(__MODULE__, {self(), Enum.reverse(entries)})
        timeline = GenServer.call(server, :timeline)
        _previous = Process.put(@version_key, 0)
        _previous = Process.put(@server_key, {timeline, :own})
        timeline

      {timeline, _role} ->
        timeline
    end
  end

  @doc """
  The calling process acts for the global object of `timeline` from now on:
  the callback process of the global object, or a process of a test that
  plays the role of one page of JavaScript.
  """
  @spec enter(timeline()) :: :ok
  def enter({server, _table, _counter} = timeline) when is_pid(server) do
    _previous = Process.put(@server_key, {timeline, :other})
    :ok
  end

  @doc """
  Makes an observer of the global object of the calling process, as the
  constructor `new PerformanceObserver(callback)`. The observer stops with
  the global object.
  """
  @spec new_observer(PerformanceObserver.callback()) :: PerformanceObserver.t()
  def new_observer(callback) do
    {server, _table, _counter} = share()
    token = make_ref()
    _reply = call(server, {:new_observer, token, callback}, :closed)
    %PerformanceObserver{address: server, token: token}
  end

  # A call of a server that stopped gives `default`.
  defp call(server, request, default) do
    GenServer.call(server, request, :infinity)
  catch
    :exit, _reason -> default
  end

  # ---------------------------------------------------------------------------
  # The task, in the callback process
  # ---------------------------------------------------------------------------

  @doc false
  # The task of "queue the PerformanceObserver task", in the callback
  # process. The task gives no event to the runner.
  def run_task({server, _table, _counter} = timeline) do
    :ok = enter(timeline)

    # Steps 1 and 2: the server sets the flag down, and gives a copy of the
    # list of registered performance observers.
    for {token, callback} <- call(server, :begin_task, []) do
      notify(server, token, callback)
    end

    nil
  after
    # The end of the task is a call: when the callback process takes its
    # next message, the server has sent the next task.
    _reply = call(server, :task_done, :ok)
  end

  # Step 3, for one registered observer. With no entries, the steps go to
  # the next observer: the text of the Standard says "return", but an empty
  # buffer of one observer does not stop the callbacks of the others.
  defp notify(server, token, callback) do
    case call(server, {:take_buffer, token}, :empty) do
      {:ok, entries, options} ->
        observer = %PerformanceObserver{address: server, token: token}
        list = %PerformanceObserverEntryList{entries: entries}
        invoke(callback, [list, observer, options])

      :empty ->
        :ok
    end
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

  @impl true
  def init({global, entries}) do
    Process.flag(:message_queue_data, :off_heap)
    gate = :atomics.new(1, signed: false)
    {:ok, runner} = Runner.start_link(gate)

    # The performance entry buffer. The earlier entries of the process had
    # their steps "queue a PerformanceEntry": they have no writer.
    table = :ets.new(__MODULE__, [:ordered_set, :public])

    for entry <- entries,
        do: :ets.insert(table, {:erlang.unique_integer([:monotonic]), entry, nil})

    {:ok,
     %{
       global: global,
       monitor: Process.monitor(global),
       table: table,
       counter: :atomics.new(1, signed: false),
       # The key of the last entry that the server got from each process.
       queued: %{},
       # The state of each observer, by its token.
       observers: %{},
       # The list of registered performance observers: the token and the
       # options list of each, in the sequence of their registration.
       registered: [],
       # The flag "performance observer task queued" of the global object.
       task_queued: false,
       # The callback process has a task.
       task_running: false,
       runner: runner,
       gate: gate
     }}
  end

  @impl true
  def handle_cast({:queue, writer, key, entry}, state) do
    state = queue_entry(state, entry)
    {:noreply, %{state | queued: Map.put(state.queued, writer, key)}}
  end

  @impl true
  def handle_call(:timeline, _from, state), do: {:reply, timeline(state), state}

  def handle_call({:new_observer, token, callback}, _from, state) do
    observer = %{
      callback: callback,
      # The observer buffer, with the last entry first.
      buffer: [],
      observer_type: :undefined,
      requires_dropped_entries: false
    }

    {:reply, :ok, %{state | observers: Map.put(state.observers, token, observer)}}
  end

  def handle_call(:begin_task, _from, state) do
    notify_list =
      for {token, _options} <- state.registered, do: {token, state.observers[token].callback}

    {:reply, notify_list, %{state | task_queued: false}}
  end

  def handle_call({:take_buffer, token}, _from, state), do: take_buffer(state, token)

  def handle_call(:task_done, _from, state) do
    {:reply, :ok, send_task(%{state | task_running: false})}
  end

  def handle_call({token, request}, _from, state) when is_reference(token) do
    case state.observers do
      %{^token => observer} -> request(request, token, observer, state)
      _unknown -> {:reply, {:error, :detached}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state) do
    {:stop, :normal, state}
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
  # The steps of the Standard
  # ---------------------------------------------------------------------------

  # The steps "queue a PerformanceEntry" for the observers: each registered
  # observer whose options list has the type of the entry gets it. The
  # entry is in the table already. The steps "should add entry" return true
  # for a mark and a measure. A task with no entry in a buffer does
  # nothing, thus only an interested observer queues the task.
  defp queue_entry(state, entry) do
    interested =
      for {token, options} <- state.registered,
          Enum.any?(options, &observes?(&1, entry.entry_type)),
          do: token

    observers =
      Enum.reduce(interested, state.observers, fn token, observers ->
        Map.update!(observers, token, &%{&1 | buffer: [entry | &1.buffer]})
      end)

    state = %{state | observers: observers}
    if interested == [], do: state, else: queue_task(state)
  end

  defp observes?(%{entry_types: types}, type), do: type in types
  defp observes?(%{type: observed}, type), do: observed == type

  # The steps "queue the PerformanceObserver task".
  defp queue_task(%{task_queued: true} = state), do: state
  defp queue_task(state), do: send_task(%{state | task_queued: true})

  # The task goes to the callback process when it has no task. It runs in
  # the empty context, as the AsyncContext proposal specifies for the
  # callbacks of an observer.
  defp send_task(%{task_queued: true, task_running: false} = state) do
    Runner.run_task(state.runner, %{
      build: {__MODULE__, :run_task, [timeline(state)]},
      snapshot: %Snapshot{},
      target: nil,
      store: nil
    })

    %{state | task_running: true}
  end

  defp send_task(state), do: state

  # Step 3 of the task, for one observer: a copy of its observer buffer,
  # and the options of the callback. The registry gives "mark" and
  # "measure" an infinite maxBufferSize: no entry is dropped, thus the
  # dropped entries count is 0.
  defp take_buffer(state, token) do
    case state.observers do
      %{^token => %{buffer: [_ | _] = buffer} = observer} ->
        options =
          if observer.requires_dropped_entries, do: %{dropped_entries_count: 0}, else: %{}

        observer = %{observer | buffer: [], requires_dropped_entries: false}
        state = %{state | observers: Map.put(state.observers, token, observer)}
        {:reply, {:ok, Enum.reverse(buffer), options}, state}

      _empty ->
        {:reply, :empty, state}
    end
  end

  # The steps 4 to 7 of `observe(options)`.
  defp request({:observe, request}, token, observer, state) do
    case observer_type(observer.observer_type, request) do
      {:ok, observer_type} ->
        observer = %{observer | observer_type: observer_type, requires_dropped_entries: true}
        state = %{state | observers: Map.put(state.observers, token, observer)}
        register(state, token, request)

      :error ->
        {:reply, :invalid_modification, state}
    end
  end

  # The steps of `disconnect()`: the observer leaves the list of registered
  # performance observers, and its buffer and its options list are empty.
  defp request(:disconnect, token, observer, state) do
    {:reply, :ok,
     %{
       state
       | registered: List.keydelete(state.registered, token, 0),
         observers: Map.put(state.observers, token, %{observer | buffer: []})
     }}
  end

  # The steps of `takeRecords()`.
  defp request(:take_records, token, observer, state) do
    observers = Map.put(state.observers, token, %{observer | buffer: []})
    {:reply, {:ok, Enum.reverse(observer.buffer)}, %{state | observers: observers}}
  end

  # Step 4: update or check the observer type.
  defp observer_type(:undefined, {:multiple, _types}), do: {:ok, :multiple}
  defp observer_type(:undefined, {:single, _type, _buffered}), do: {:ok, :single}
  defp observer_type(:multiple, {:multiple, _types}), do: {:ok, :multiple}
  defp observer_type(:single, {:single, _type, _buffered}), do: {:ok, :single}
  defp observer_type(_observer_type, _request), do: :error

  # Step 6: the observer type is "multiple". The options list has only the
  # options of this call. An unsupported type is ignored, and with no type
  # left the steps abort.
  defp register(state, token, {:multiple, types}) do
    {supported, ignored} = Enum.split_with(types, &(&1 in @supported_entry_types))

    if supported == [] do
      {:reply, {:aborted, ignored}, state}
    else
      state = put_options(state, token, fn _options -> [%{entry_types: supported}] end)
      {:reply, {:registered, ignored}, state}
    end
  end

  # Step 7: the observer type is "single". The options with the same type
  # take the place of the old options. Other options are added.
  defp register(state, _token, {:single, type, _buffered})
       when type not in @supported_entry_types do
    {:reply, {:aborted, [type]}, state}
  end

  defp register(state, token, {:single, type, buffered}) do
    state =
      put_options(state, token, fn options ->
        item = %{type: type, buffered: buffered}

        case Enum.find_index(options, &(Map.get(&1, :type) == type)) do
          nil -> options ++ [item]
          index -> List.replace_at(options, index, item)
        end
      end)

    {:reply, {:registered, []}, if(buffered, do: add_buffered(state, token, type), else: state)}
  end

  # Step 7.4: the entries of the type in the performance entry buffer go
  # to the observer buffer, in their sequence, and the task is queued. The
  # steps "should add entry" return true for a mark and a measure. An entry
  # that the server did not get yet gets to the observer from its queue
  # step.
  defp add_buffered(state, token, type) do
    buffered =
      for {key, entry, writer} <- :ets.tab2list(state.table),
          entry.entry_type == type,
          queued?(state, writer, key),
          do: entry

    buffered = Enum.reverse(buffered)

    observers =
      Map.update!(state.observers, token, &%{&1 | buffer: buffered ++ &1.buffer})

    queue_task(%{state | observers: observers})
  end

  defp timeline(state), do: {self(), state.table, state.counter}

  # The server got the entry, or the entry came before the first observer.
  # The keys of one process grow, and its messages arrive in their
  # sequence.
  defp queued?(_state, nil, _key), do: true

  defp queued?(state, writer, key) do
    case state.queued do
      %{^writer => last} -> key <= last
      _none -> false
    end
  end

  # The registered performance observer of the observer: a new one goes to
  # the end of the list.
  defp put_options(state, token, update) do
    registered =
      case List.keyfind(state.registered, token, 0) do
        {^token, options} ->
          List.keyreplace(state.registered, token, 0, {token, update.(options)})

        nil ->
          state.registered ++ [{token, update.([])}]
      end

    %{state | registered: registered}
  end
end
