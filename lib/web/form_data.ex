defmodule Web.FormData do
  @moduledoc """
  WHATWG-style FormData container.

  Programmatically constructed instances store entries eagerly. Multipart-parsed
  instances are live-backed by a coordinator process that discovers entries lazily.

  ## Social Contract

  - Live iteration: `Web.FormData` is an `Enumerable` collection of
    `[name, value]` pairs so `Enum` traversal matches browser
    `FormData.entries()` semantics.
  - Automatic discard for skipped files: when traversal advances past a file part
    that has not been consumed, the coordinator drains that file body
    automatically before moving forward. This keeps memory usage flat at
    $O(1)$ relative to payload size and prevents deadlocks on blocked file parts.
  """

  alias __MODULE__.Parser
  alias Web.File

  @type name :: String.t()
  @type value :: String.t() | File.t()
  @type entry :: {name(), value()}
  @type t :: %__MODULE__{
          entries: [entry()],
          boundary: String.t(),
          coordinator: pid() | nil
        }

  defstruct entries: [], boundary: nil, coordinator: nil

  @doc """
  Creates a new FormData container.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    boundary = Keyword.get(opts, :boundary, default_boundary())
    %__MODULE__{entries: [], boundary: normalize_boundary(boundary)}
  end

  @doc """
  Appends a value for a field name.
  """
  @spec append(t(), term(), term(), String.t() | nil) :: t()
  def append(form, name, value, filename \\ nil)

  def append(%__MODULE__{coordinator: pid} = form, name, value, filename) when is_pid(pid) do
    form
    |> drain_live()
    |> append(name, value, filename)
  end

  def append(%__MODULE__{entries: entries} = form, name, value, filename) do
    normalized_name = to_string(name)
    normalized_value = normalize_value(normalized_name, value, filename)
    %{form | entries: entries ++ [{normalized_name, normalized_value}]}
  end

  @doc """
  Sets a single value for a field name, replacing existing entries.
  """
  @spec set(t(), term(), term(), String.t() | nil) :: t()
  def set(form, name, value, filename \\ nil)

  def set(%__MODULE__{coordinator: pid} = form, name, value, filename) when is_pid(pid) do
    form
    |> drain_live()
    |> set(name, value, filename)
  end

  def set(%__MODULE__{} = form, name, value, filename) do
    normalized_name = to_string(name)

    form
    |> delete(normalized_name)
    |> append(normalized_name, value, filename)
  end

  @doc """
  Deletes all values for the given field name.
  """
  @spec delete(t(), term()) :: t()
  def delete(form, name)

  def delete(%__MODULE__{coordinator: pid} = form, name) when is_pid(pid) do
    form
    |> drain_live()
    |> delete(name)
  end

  def delete(%__MODULE__{entries: entries} = form, name) do
    normalized_name = to_string(name)

    %{
      form
      | entries:
          Enum.reject(entries, fn {entry_name, _value} -> entry_name == normalized_name end)
    }
  end

  @doc """
  Returns the first value for a field name.
  """
  @spec get(t(), term()) :: value() | nil
  def get(%__MODULE__{coordinator: pid}, name) when is_pid(pid) do
    normalized_name = to_string(name)
    Parser.get(pid, normalized_name)
  end

  def get(%__MODULE__{entries: entries}, name) do
    normalized_name = to_string(name)

    entries
    |> Enum.find(fn {entry_name, _value} -> entry_name == normalized_name end)
    |> case do
      nil -> nil
      {_name, value} -> value
    end
  end

  @doc """
  Returns all values for a field name.
  """
  @spec get_all(t(), term()) :: [value()]
  def get_all(%__MODULE__{coordinator: pid}, name) when is_pid(pid) do
    normalized_name = to_string(name)
    Parser.get_all(pid, normalized_name)
  end

  def get_all(%__MODULE__{entries: entries}, name) do
    normalized_name = to_string(name)

    entries
    |> Enum.filter(fn {entry_name, _value} -> entry_name == normalized_name end)
    |> Enum.map(&elem(&1, 1))
  end

  @doc """
  Returns whether the field name exists.
  """
  @spec has?(t(), term()) :: boolean()
  def has?(%__MODULE__{coordinator: pid}, name) when is_pid(pid) do
    normalized_name = to_string(name)
    Parser.has?(pid, normalized_name)
  end

  def has?(%__MODULE__{} = form, name) do
    not is_nil(get(form, name))
  end

  @doc """
  Returns ordered entries.
  """
  @spec entries(t()) :: Enumerable.t()
  def entries(%__MODULE__{} = form) do
    form
  end

  @doc """
  Parses a multipart/form-data body into a live-backed FormData container.
  """
  @spec parse(Web.ReadableStream.t() | binary() | iodata(), String.t(), keyword()) :: t()
  def parse(stream_or_binary, boundary, opts \\ []) do
    normalized_boundary = normalize_boundary(boundary)
    source = Web.ReadableStream.from(stream_or_binary)

    case Parser.start_link(source, normalized_boundary, opts) do
      {:ok, pid} ->
        :ok = Parser.await_ready(pid)
        %__MODULE__{boundary: normalized_boundary, coordinator: pid}

      {:error, %Web.TypeError{} = reason} ->
        raise(reason)

      {:error, {:shutdown, reason}} ->
        exit(reason)

      {:error, reason} ->
        exit(reason)
    end
  end

  @doc """
  Cancels a live-backed FormData coordinator and all open child streams.
  """
  @spec cancel(t(), term()) :: :ok
  def cancel(form, reason \\ :cancelled)

  def cancel(%__MODULE__{coordinator: pid}, reason) when is_pid(pid) do
    Parser.cancel(pid, reason)
  end

  def cancel(%__MODULE__{}, _reason), do: :ok

  @doc """
  Returns the multipart Content-Type header value for this form.
  """
  @spec content_type(t()) :: String.t()
  def content_type(%__MODULE__{boundary: boundary}) do
    "multipart/form-data; boundary=" <> boundary
  end

  defp normalize_value(_name, %File{} = file, filename) when is_binary(filename) do
    %{file | filename: filename}
  end

  defp normalize_value(_name, %File{} = file, _filename), do: file

  defp normalize_value(name, %Web.Blob{} = blob, filename) do
    File.new(blob.parts,
      name: name,
      filename: filename || "blob",
      type: blob.type
    )
  end

  defp normalize_value(_name, value, _filename), do: to_string(value)

  # Drains a live coordinator to a static entries list, stopping the coordinator
  # process. Used internally by mutation operations (append/set/delete) on live forms.
  defp drain_live(%__MODULE__{coordinator: pid} = form) when is_pid(pid) do
    entries = Parser.materialize(pid)
    %{form | entries: entries, coordinator: nil}
  end

  defp normalize_boundary(boundary) do
    boundary
    |> to_string()
    |> String.trim()
  end

  defp default_boundary do
    suffix =
      16
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    "----web-" <> suffix
  end

  defmodule Parser do
    @moduledoc false
    @behaviour :gen_statem

    alias Web.File
    alias Web.ReadableStream
    alias Web.ReadableStreamDefaultController
    alias Web.TypeError

    @header_separator "\r\n\r\n"

    def start_link(source, boundary, opts \\ []) do
      caller = self()
      owner = Keyword.get(opts, :owner, self())
      reply_ref = make_ref()

      {_owner_pid, owner_ref} =
        spawn_monitor(fn ->
          start_link_owner(caller, owner, reply_ref, source, boundary, opts)
        end)

      receive do
        {^reply_ref, result} ->
          Process.demonitor(owner_ref, [:flush])
          result
      end
    end

    def await_ready(pid) do
      pid
      |> call(:await_ready)
      |> then(&unwrap!(:await_ready, &1))
    end

    def get(pid, name) do
      pid
      |> call({:get, name})
      |> then(&unwrap!(:value, &1))
    end

    def get_all(pid, name) do
      pid
      |> call({:get_all, name})
      |> then(&unwrap!(:value, &1))
    end

    def has?(pid, name) do
      pid
      |> call({:has, name})
      |> then(&unwrap!(:value, &1))
    end

    def entries(pid) do
      pid
      |> call(:entries)
      |> then(&unwrap!(:value, &1))
    end

    def materialize(pid) do
      pid
      |> call(:materialize)
      |> then(&unwrap!(:value, &1))
    end

    def cancel(pid, reason) do
      _ = call(pid, {:cancel, reason})
      :ok
    end

    def child_pull(pid, part_id, controller) do
      case call(pid, {:pull_file, part_id, controller}) do
        {:error, _reason} -> close_pull_controller(controller)
        _ -> :ok
      end

      :ok
    end

    def child_cancel(pid, part_id, reason) do
      _ = call(pid, {:cancel_file, part_id, reason})
      :ok
    end

    def next_entry(pid, index) do
      pid
      |> call({:next_entry, index})
      |> then(&unwrap!(:next_entry, &1))
    end

    defp start_link_owner(caller, owner, reply_ref, source, boundary, opts) do
      Process.flag(:trap_exit, true)
      owner_ref = Process.monitor(owner)

      case :gen_statem.start_link(__MODULE__, {source, boundary, opts}, []) do
        {:ok, pid} = result ->
          send(caller, {reply_ref, result})
          owner_loop(pid, owner, owner_ref)

        {:error, reason} = result ->
          send(caller, {reply_ref, result})
          exit(reason)
      end
    end

    defp owner_loop(pid, owner, owner_ref) do
      receive do
        {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
          if Process.alive?(pid) do
            Process.exit(pid, :shutdown)
          end

          receive do
            {:EXIT, ^pid, _exit_reason} -> :ok
          after
            0 -> :ok
          end

        {:EXIT, ^pid, _reason} ->
          :ok
      end
    end

    @impl true
    def callback_mode, do: :handle_event_function

    @impl true
    def init({%ReadableStream{controller_pid: source_pid}, boundary, opts}) do
      Process.flag(:message_queue_data, :off_heap)

      subscription = subscribe_signal(Keyword.get(opts, :signal))

      if match?(%{aborted: true}, subscription) do
        {:stop, {:shutdown, subscription.reason}}
      else
        data = %{
          source_pid: source_pid,
          source_lock_released?: false,
          signal_subscription: subscription,
          boundary: boundary,
          opening_boundary: "--" <> boundary,
          delimiter_prefix: "\r\n--" <> boundary,
          retain_bytes: byte_size("\r\n--" <> boundary) + 1,
          buffer: "",
          phase: :opening,
          ready?: false,
          entries: [],
          current_field: nil,
          current_file: nil,
          next_part_id: 1,
          pending: [],
          materializing?: false
        }

        case ReadableStream.get_reader(source_pid) do
          :ok ->
            {:ok, :running, data}

          {:error, :already_locked} ->
            {:stop, TypeError.exception("ReadableStream is already locked")}
        end
      end
    end

    @impl true
    def handle_event({:call, from}, :await_ready, :running, data) do
      serve_query(from, :await_ready, data)
    end

    def handle_event({:call, from}, {:get, name}, :running, data) do
      serve_query(from, {:get, name}, data)
    end

    def handle_event({:call, from}, {:get_all, name}, :running, data) do
      serve_query(from, {:get_all, name}, data)
    end

    def handle_event({:call, from}, {:has, name}, :running, data) do
      serve_query(from, {:has, name}, data)
    end

    def handle_event({:call, from}, :entries, :running, data) do
      serve_query(from, :entries, begin_materialization(data))
    end

    def handle_event({:call, from}, :materialize, :running, data) do
      case ensure_answer(:materialize, begin_materialization(data)) do
        {:reply, entries, done_data} ->
          {:stop_and_reply, :normal, [{:reply, from, {:ok, entries}}], done_data}

        {:error, reason, next_data} ->
          abort_later(reason, next_data, [{:reply, from, {:error, reason}}])
      end
    end

    def handle_event({:call, from}, {:next_entry, index}, :running, data) do
      data = maybe_discard_before_index(data, index)
      serve_query(from, {:next_entry, index}, data)
    end

    def handle_event({:call, from}, {:cancel, reason}, :running, data) do
      abort_later(reason, data, [{:reply, from, :ok}])
    end

    def handle_event({:call, from}, {:cancel_file, part_id, _reason}, :running, data) do
      data = maybe_mark_file_discard(data, part_id)

      case resolve_pending(data) do
        {:ok, next_data, actions} ->
          reply_or_stop(next_data, [{:reply, from, :ok} | actions])

        {:error, reason, next_data, actions} ->
          abort_later(reason, next_data, [{:reply, from, :ok} | actions])
      end
    end

    def handle_event({:call, from}, {:pull_file, part_id, controller}, :running, data) do
      case serve_file_pull(data, part_id, controller) do
        {:ok, next_data} ->
          case resolve_pending(next_data) do
            {:ok, resolved_data, actions} ->
              reply_or_stop(resolved_data, [{:reply, from, :ok} | actions])

            {:error, reason, resolved_data, actions} ->
              error_child_stream(controller.pid, reason)
              abort_later(reason, resolved_data, [{:reply, from, :ok} | actions])
          end

        {:error, reason, next_data} ->
          error_child_stream(controller.pid, reason)
          abort_later(reason, next_data, [{:reply, from, :ok}])
      end
    end

    def handle_event(:internal, {:abort, reason}, :running, data) do
      {:stop, {:shutdown, reason}, data}
    end

    def handle_event(:info, message, :running, data) do
      case abort_reason_from_message(message, data.signal_subscription) do
        {:ok, reason} ->
          abort_later(reason, data)

        :ignore ->
          {:keep_state_and_data, hibernate_actions()}
      end
    end

    defp serve_query(from, request, data) do
      case maybe_reply(request, data) do
        {:reply, reply} ->
          reply_or_stop(data, [{:reply, from, {:ok, reply}}])

        :need_more ->
          case ensure_answer(request, data) do
            {:reply, reply, next_data} ->
              reply_or_stop(next_data, [{:reply, from, {:ok, reply}}])

            {:blocked, next_data} ->
              waiter = %{from: from, request: request}

              {:keep_state, %{next_data | pending: next_data.pending ++ [waiter]},
               hibernate_actions()}

            {:error, reason, next_data} ->
              abort_later(reason, next_data, [{:reply, from, {:error, reason}}])
          end
      end
    end

    defp ensure_answer(request, data) do
      case maybe_reply(request, data) do
        {:reply, reply} ->
          {:reply, reply, data}

        :need_more ->
          data
          |> advance()
          |> ensure_answer_after_advance(request)
      end
    end

    defp ensure_answer_after_advance({:ok, next_data}, request),
      do: ensure_answer(request, next_data)

    defp ensure_answer_after_advance({:blocked, next_data}, request) do
      case maybe_reply(request, next_data) do
        {:reply, reply} -> {:reply, reply, next_data}
        :need_more -> {:blocked, next_data}
      end
    end

    defp ensure_answer_after_advance({:error, reason, next_data}, _request),
      do: {:error, reason, next_data}

    defp resolve_pending(%{pending: []} = data), do: {:ok, data, []}

    defp resolve_pending(data) do
      do_resolve_pending(data, data.pending, [])
    end

    defp do_resolve_pending(data, [], actions) do
      {:ok, %{data | pending: []}, Enum.reverse(actions)}
    end

    defp do_resolve_pending(data, [waiter | rest], actions) do
      case maybe_reply(waiter.request, data) do
        {:reply, reply} ->
          do_resolve_pending(data, rest, [{:reply, waiter.from, {:ok, reply}} | actions])

        :need_more ->
          waiter.request
          |> ensure_answer(data)
          |> resolve_pending_after_ensure(waiter, rest, actions)
      end
    end

    defp resolve_pending_after_ensure({:reply, reply, next_data}, waiter, rest, actions) do
      do_resolve_pending(next_data, rest, [{:reply, waiter.from, {:ok, reply}} | actions])
    end

    defp resolve_pending_after_ensure({:blocked, next_data}, waiter, rest, actions) do
      {:ok, %{next_data | pending: [waiter | rest]}, Enum.reverse(actions)}
    end

    defp resolve_pending_after_ensure({:error, reason, next_data}, waiter, rest, actions) do
      error_actions =
        Enum.map([waiter | rest], fn pending_waiter ->
          {:reply, pending_waiter.from, {:error, reason}}
        end)

      {:error, reason, %{next_data | pending: []}, Enum.reverse(actions) ++ error_actions}
    end

    defp reply_or_stop(data, reply_actions) do
      {:keep_state, data, reply_actions ++ hibernate_actions()}
    end

    defp maybe_reply({:next_entry, index}, data) do
      cond do
        index < length(data.entries) -> {:reply, {:found, Enum.at(data.entries, index)}}
        data.phase == :done -> {:reply, :done}
        true -> :need_more
      end
    end

    defp maybe_reply(:await_ready, %{ready?: true}), do: {:reply, :ok}

    defp maybe_reply({:get, name}, data) do
      case Enum.find(data.entries, fn {entry_name, _value} -> entry_name == name end) do
        nil when data.phase == :done -> {:reply, nil}
        nil -> :need_more
        {_name, value} -> {:reply, value}
      end
    end

    defp maybe_reply({:has, name}, data) do
      case maybe_reply({:get, name}, data) do
        {:reply, nil} -> {:reply, false}
        {:reply, _value} -> {:reply, true}
        :need_more -> :need_more
      end
    end

    defp maybe_reply({:get_all, name}, %{phase: :done, entries: entries}) do
      values =
        entries
        |> Enum.filter(fn {entry_name, _value} -> entry_name == name end)
        |> Enum.map(&elem(&1, 1))

      {:reply, values}
    end

    defp maybe_reply(:entries, %{phase: :done, entries: entries}), do: {:reply, entries}
    defp maybe_reply(:materialize, %{phase: :done, entries: entries}), do: {:reply, entries}
    defp maybe_reply(_request, _data), do: :need_more

    defp advance(%{phase: :done} = data), do: {:ok, data}

    defp advance(%{phase: :opening} = data) do
      case consume_opening_boundary(data) do
        {:ok, next_data} -> advance(next_data)
        {:error, reason, next_data} -> {:error, reason, next_data}
      end
    end

    defp advance(%{phase: :headers} = data) do
      case consume_headers(data) do
        {:ok, %{phase: :file, current_file: %{mode: :discard}} = next_data} -> advance(next_data)
        {:ok, %{phase: :file} = next_data} -> {:blocked, next_data}
        {:ok, next_data} -> advance(next_data)
        {:error, reason, next_data} -> {:error, reason, next_data}
      end
    end

    defp advance(%{phase: :field} = data) do
      case consume_field_body(data) do
        {:ok, next_data} -> advance(next_data)
        {:error, reason, next_data} -> {:error, reason, next_data}
      end
    end

    defp advance(%{phase: :file, current_file: %{mode: :await_pull}} = data), do: {:blocked, data}

    defp advance(%{phase: :file, current_file: %{mode: :discard}} = data) do
      case discard_file_body(data) do
        {:ok, next_data} -> advance(next_data)
        {:error, reason, next_data} -> {:error, reason, next_data}
      end
    end

    defp consume_opening_boundary(data) do
      needed = byte_size(data.opening_boundary) + 2

      case byte_size(data.buffer) < needed do
        true -> read_opening_boundary(data)
        false -> parse_opening_boundary(data)
      end
    end

    defp consume_headers(data) do
      case :binary.match(data.buffer, @header_separator) do
        {header_end, header_len} ->
          headers_binary = binary_part(data.buffer, 0, header_end)
          rest_offset = header_end + header_len
          rest = binary_part(data.buffer, rest_offset, byte_size(data.buffer) - rest_offset)

          case parse_part_headers(headers_binary) do
            {:ok, part_info} -> consume_part_headers(data, rest, part_info)
            {:error, reason} -> {:error, reason, data}
          end

        :nomatch ->
          continue_after_read(
            data,
            &consume_headers/1,
            "Malformed multipart body: part headers are incomplete"
          )
      end
    end

    defp consume_field_body(%{current_field: current_field} = data) do
      case scan_body(data.buffer, data.delimiter_prefix, data.retain_bytes) do
        {:data, emit, rest} ->
          updated_field = %{current_field | chunks: [current_field.chunks | [emit]]}

          continue_after_read(
            %{data | buffer: rest, current_field: updated_field},
            &consume_field_body/1,
            "Malformed multipart body: missing closing boundary"
          )

        {:boundary, emit, rest, transition} ->
          value = IO.iodata_to_binary([current_field.chunks, emit])

          next_data =
            data
            |> Map.put(:entries, data.entries ++ [{current_field.name, value}])
            |> Map.put(:current_field, nil)
            |> Map.put(:ready?, true)
            |> transition_after_boundary(rest, transition)

          {:ok, next_data}

        :need_more ->
          continue_after_read(
            data,
            &consume_field_body/1,
            "Malformed multipart body: missing closing boundary"
          )
      end
    end

    defp serve_file_pull(
           %{phase: :file, current_file: %{id: part_id, mode: :await_pull}} = data,
           part_id,
           controller
         ) do
      produce_file_chunk(data, controller)
    end

    defp serve_file_pull(
           %{current_file: %{id: part_id, mode: :discard}} = data,
           part_id,
           controller
         ) do
      close_pull_controller(controller)
      {:ok, data}
    end

    defp serve_file_pull(data, _part_id, controller) do
      close_pull_controller(controller)
      {:ok, data}
    end

    defp produce_file_chunk(data, controller) do
      case scan_body(data.buffer, data.delimiter_prefix, data.retain_bytes) do
        {:data, emit, rest} ->
          ReadableStreamDefaultController.enqueue(controller, emit)
          {:ok, bump_file_size(%{data | buffer: rest}, byte_size(emit))}

        {:boundary, emit, rest, transition} ->
          next_data = bump_file_size(data, byte_size(emit))

          if emit != "" do
            ReadableStreamDefaultController.enqueue(controller, emit)
          end

          ReadableStreamDefaultController.close(controller)
          {:ok, finalize_file_part(next_data, rest, transition)}

        :need_more ->
          continue_after_read(
            data,
            &produce_file_chunk(&1, controller),
            "Malformed multipart body: missing closing boundary"
          )
      end
    end

    defp discard_file_body(data) do
      case scan_body(data.buffer, data.delimiter_prefix, data.retain_bytes) do
        {:data, emit, rest} ->
          next_data = bump_file_size(%{data | buffer: rest}, byte_size(emit))

          continue_after_read(
            next_data,
            &discard_file_body/1,
            "Malformed multipart body: missing closing boundary"
          )

        {:boundary, emit, rest, transition} ->
          next_data =
            data |> bump_file_size(byte_size(emit)) |> finalize_file_part(rest, transition)

          {:ok, next_data}

        :need_more ->
          continue_after_read(
            data,
            &discard_file_body/1,
            "Malformed multipart body: missing closing boundary"
          )
      end
    end

    defp finalize_file_part(%{current_file: current_file} = data, rest, transition) do
      finished_file = %{current_file.file | size: current_file.size}
      {field_name, _old_value} = Enum.at(data.entries, current_file.entry_index)

      updated_entries =
        List.replace_at(data.entries, current_file.entry_index, {field_name, finished_file})

      data
      |> Map.put(:entries, updated_entries)
      |> Map.put(:current_file, nil)
      |> transition_after_boundary(rest, transition)
    end

    defp transition_after_boundary(data, _rest, :final) do
      data
      |> Map.put(:buffer, "")
      |> mark_done()
    end

    defp transition_after_boundary(data, rest, :part) do
      %{data | buffer: rest, phase: :headers}
    end

    defp mark_done(data) do
      data
      |> release_source_lock()
      |> Map.put(:entries, freeze_entries(data.entries, data.materializing?))
      |> Map.put(:phase, :done)
      |> Map.put(:ready?, true)
      |> Map.put(:materializing?, false)
    end

    defp bump_file_size(%{current_file: current_file} = data, increment) do
      %{data | current_file: %{current_file | size: current_file.size + increment}}
    end

    defp maybe_mark_file_discard(%{current_file: %{id: part_id} = current_file} = data, part_id) do
      %{data | current_file: %{current_file | mode: :discard}}
    end

    defp maybe_mark_file_discard(data, _part_id), do: data

    # When iterating via next_entry, auto-discard any file whose body blocks
    # progress toward the requested index so advance never returns {:blocked, _}.
    defp maybe_discard_before_index(
           %{phase: :file, current_file: %{entry_index: ei, mode: :await_pull} = cf} = data,
           index
         )
         when ei < index do
      discard_child_stream(cf.stream_pid, :skipped)
      %{data | current_file: %{cf | mode: :discard}}
    end

    defp maybe_discard_before_index(data, _index), do: data

    defp begin_materialization(%{materializing?: true} = data), do: data

    defp begin_materialization(%{current_file: %{mode: :await_pull} = current_file} = data) do
      discard_child_stream(current_file.stream_pid, :materialized)
      %{data | materializing?: true, current_file: %{current_file | mode: :discard}}
    end

    defp begin_materialization(data), do: %{data | materializing?: true}

    defp scan_body(buffer, delimiter_prefix, retain_bytes),
      do:
        scan_body_match(
          :binary.match(buffer, delimiter_prefix),
          buffer,
          delimiter_prefix,
          retain_bytes
        )

    defp scan_body_match(:nomatch, buffer, _delimiter_prefix, retain_bytes),
      do: emit_without_boundary(buffer, retain_bytes)

    defp scan_body_match(
           {match_start, _length},
           buffer,
           delimiter_prefix,
           _retain_bytes
         ) do
      prefix_size = byte_size(delimiter_prefix)
      after_prefix_start = match_start + prefix_size
      after_prefix_bytes = byte_size(buffer) - after_prefix_start

      case after_prefix_bytes do
        bytes when bytes < 2 and match_start > 0 -> emit_before_match(buffer, match_start)
        bytes when bytes < 2 -> :need_more
        _bytes -> classify_boundary_match(buffer, match_start, after_prefix_start)
      end
    end

    defp parse_part_headers(headers_binary) do
      headers =
        headers_binary
        |> String.split("\r\n", trim: true)
        |> Enum.reduce_while(%{}, fn line, acc ->
          case String.split(line, ":", parts: 2) do
            [name, value] ->
              {:cont, Map.put(acc, String.downcase(String.trim(name)), String.trim(value))}

            _ ->
              {:halt,
               {:error, TypeError.exception("Malformed multipart body: invalid header line")}}
          end
        end)

      case headers do
        {:error, %TypeError{} = reason} ->
          {:error, reason}

        headers when is_map(headers) ->
          with disposition when is_binary(disposition) <-
                 Map.get(headers, "content-disposition") ||
                   {:error,
                    TypeError.exception("Malformed multipart body: missing content-disposition")},
               {:ok, %{name: name, filename: filename}} <- parse_content_disposition(disposition) do
            {:ok, build_part_info(name, filename, Map.get(headers, "content-type", ""))}
          else
            {:error, %TypeError{} = reason} -> {:error, reason}
          end
      end
    end

    defp parse_content_disposition(value) do
      [type | _] = String.split(value, ";", parts: 2)

      case String.downcase(String.trim(type)) do
        "form-data" ->
          parse_form_data_disposition(value)

        _other ->
          {:error, TypeError.exception("Malformed multipart body: missing form-data disposition")}
      end
    end

    defp parse_disposition_params(value) do
      ~r/;\s*([!#$%&'*+\-.^_`|~0-9A-Za-z]+\*?)\s*=\s*("(?:\\.|[^"])*"|[^;]*)/u
      |> Regex.scan(value, capture: :all_but_first)
      |> Enum.reduce(%{}, fn [name, raw_value], acc ->
        decoded_value =
          if String.ends_with?(name, "*") do
            decode_extended_param(raw_value)
          else
            decode_regular_param(raw_value)
          end

        Map.put(acc, String.downcase(name), decoded_value)
      end)
    end

    defp decode_regular_param(raw_value) do
      value = String.trim(raw_value)

      if String.starts_with?(value, "\"") and String.ends_with?(value, "\"") and
           byte_size(value) >= 2 do
        value
        |> binary_part(1, byte_size(value) - 2)
        |> String.replace(~r/\\(.)/u, "\\1")
      else
        value
      end
    end

    defp decode_extended_param(raw_value) do
      value = String.trim(raw_value)

      case Regex.run(~r/\A([^']*)'([^']*)'(.*)\z/u, value, capture: :all_but_first) do
        [charset, _language, encoded] ->
          decode_rfc5987_value(charset, encoded)

        _ ->
          decode_regular_param(value)
      end
    end

    defp decode_rfc5987_value(charset, encoded) do
      decoded = percent_decode(encoded)

      case String.downcase(String.trim(charset)) do
        current when current in ["utf-8", "utf8", ""] -> decoded
        "iso-8859-1" -> :unicode.characters_to_binary(decoded, :latin1, :utf8)
        _ -> decoded
      end
    end

    defp percent_decode(binary) do
      percent_decode(binary, [])
      |> Enum.reverse()
      |> IO.iodata_to_binary()
    end

    defp percent_decode(<<>>, acc), do: acc

    defp percent_decode(<<"%", hi, lo, rest::binary>>, acc) do
      case Integer.parse(<<hi, lo>>, 16) do
        {value, ""} -> percent_decode(rest, [<<value>> | acc])
        _ -> percent_decode(rest, [<<"%", hi, lo>> | acc])
      end
    end

    defp percent_decode(<<char, rest::binary>>, acc), do: percent_decode(rest, [<<char>> | acc])

    defp read_more(data) do
      case ReadableStream.read(data.source_pid) do
        {:ok, chunk} ->
          case normalize_chunk(chunk) do
            {:ok, binary} -> {:ok, %{data | buffer: data.buffer <> binary}}
            {:error, reason} -> {:error, reason, data}
          end

        :done ->
          {:done, data}

        {:error, {:errored, reason}} ->
          {:error, reason, data}

        {:error, reason} ->
          {:error, reason, data}
      end
    end

    defp normalize_chunk(chunk) when is_binary(chunk), do: {:ok, chunk}
    defp normalize_chunk(%Web.Uint8Array{} = chunk), do: {:ok, Web.Uint8Array.to_binary(chunk)}
    defp normalize_chunk(chunk) when is_list(chunk), do: {:ok, IO.iodata_to_binary(chunk)}

    defp normalize_chunk(_chunk) do
      {:error,
       TypeError.exception("Multipart stream chunk must be binary, Uint8Array, or iodata")}
    end

    defp malformed(message, data), do: {:error, TypeError.exception(message), data}

    defp continue_after_read(data, continue_fun, eof_message) do
      case read_more(data) do
        {:ok, next_data} -> continue_fun.(next_data)
        {:done, next_data} -> malformed(eof_message, next_data)
        {:error, reason, next_data} -> {:error, reason, next_data}
      end
    end

    defp close_pull_controller(controller) do
      ReadableStreamDefaultController.close(controller)
    end

    defp freeze_entries(entries, materialized?) do
      Enum.map(entries, fn
        {name, %File{} = file} -> {name, freeze_file(file, materialized?)}
        entry -> entry
      end)
    end

    defp freeze_file(%File{} = file, true) do
      %{file | parts: [], stream: nil}
    end

    defp freeze_file(%File{} = file, false) do
      %{file | parts: []}
    end

    defp subscribe_signal(nil), do: nil

    defp subscribe_signal(signal) do
      case Web.AbortSignal.subscribe(signal) do
        {:ok, subscription} ->
          subscription

        {:error, :aborted} ->
          %{
            type: :token,
            token: make_ref(),
            aborted: true,
            reason: Web.AbortSignal.reason(signal) || :aborted
          }
      end
    end

    defp unsubscribe_signal(nil), do: :ok
    defp unsubscribe_signal(subscription), do: Web.AbortSignal.unsubscribe(subscription)

    defp abort_reason_from_message(_message, nil), do: :ignore

    defp abort_reason_from_message({:abort, ref, reason}, %{type: :abort_signal, ref: ref}),
      do: {:ok, reason}

    defp abort_reason_from_message(
           {:DOWN, monitor_ref, :process, pid, {:shutdown, {:aborted, reason}}},
           %{type: :abort_signal, monitor_ref: monitor_ref, pid: pid}
         ),
         do: {:ok, reason}

    defp abort_reason_from_message(
           {:DOWN, monitor_ref, :process, pid, reason},
           %{type: :abort_signal, monitor_ref: monitor_ref, pid: pid}
         ),
         do: {:ok, reason}

    defp abort_reason_from_message(
           {:DOWN, monitor_ref, :process, pid, reason},
           %{type: :pid, monitor_ref: monitor_ref, pid: pid}
         ),
         do: {:ok, reason}

    defp abort_reason_from_message({:abort, token, reason}, %{type: :token, token: token}),
      do: {:ok, reason}

    defp abort_reason_from_message({:abort, token}, %{type: :token, token: token}),
      do: {:ok, :aborted}

    defp abort_reason_from_message(_message, _subscription), do: :ignore

    defp release_source_lock(%{source_lock_released?: true} = data), do: data

    defp release_source_lock(%{source_pid: source_pid} = data) do
      if Process.alive?(source_pid) do
        _ = safe_call(fn -> ReadableStream.release_lock(source_pid) end)
      end

      %{data | source_lock_released?: true}
    end

    defp maybe_cancel_source(%{source_lock_released?: true}, _reason), do: :ok
    defp maybe_cancel_source(_data, :normal), do: :ok
    defp maybe_cancel_source(_data, nil), do: :ok

    defp maybe_cancel_source(%{source_pid: source_pid}, reason) do
      if Process.alive?(source_pid) do
        _ =
          safe_call(fn -> Web.Stream.control_call(source_pid, {:terminate, :cancel, reason}) end)
      end

      :ok
    end

    defp error_child_stream(nil, _reason), do: :ok

    defp error_child_stream(stream_pid, %TypeError{} = reason) when is_pid(stream_pid) do
      if Process.alive?(stream_pid) do
        ReadableStream.error(stream_pid, reason)
      end

      :ok
    end

    defp error_child_stream(_stream_pid, nil), do: :ok

    defp error_child_stream(stream_pid, reason) when is_pid(stream_pid) do
      if Process.alive?(stream_pid) do
        Web.Stream.control_cast(stream_pid, {:terminate, :cancel, reason})
      end

      :ok
    end

    defp discard_child_stream(stream_pid, reason) when is_pid(stream_pid) do
      error_child_stream(stream_pid, reason)

      if Process.alive?(stream_pid) do
        Process.unlink(stream_pid)
        Process.exit(stream_pid, :shutdown)
      end

      :ok
    end

    @impl true
    def terminate(reason, _state, data) do
      normalized_reason = normalize_stop_reason(reason)

      unsubscribe_signal(data.signal_subscription)
      error_child_stream(data.current_file && data.current_file.stream_pid, normalized_reason)
      maybe_cancel_source(data, normalized_reason)
      _ = release_source_lock(data)

      :ok
    end

    defp abort_later(reason, data, actions \\ []) do
      error_child_stream(data.current_file && data.current_file.stream_pid, reason)

      pending_actions =
        Enum.map(data.pending, fn waiter -> {:reply, waiter.from, {:error, reason}} end)

      next_data = %{data | pending: []}

      {:keep_state, next_data,
       actions ++ pending_actions ++ [{:next_event, :internal, {:abort, reason}}]}
    end

    defp call(pid, request) do
      :gen_statem.call(pid, request, :infinity)
    catch
      :exit, reason ->
        {:error, normalize_call_exit(reason)}
    end

    defp read_opening_boundary(data) do
      case read_more(data) do
        {:ok, next_data} ->
          consume_opening_boundary(next_data)

        {:done, next_data} ->
          malformed("Malformed multipart body: missing opening boundary", next_data)

        {:error, reason, next_data} ->
          {:error, reason, next_data}
      end
    end

    defp parse_opening_boundary(data) do
      opening_size = byte_size(data.opening_boundary)

      case data.buffer do
        <<opening::binary-size(opening_size), rest::binary>>
        when opening == data.opening_boundary ->
          parse_opening_boundary_rest(data, rest)

        _other ->
          malformed("Malformed multipart body: missing opening boundary", data)
      end
    end

    defp parse_opening_boundary_rest(data, <<"\r\n", tail::binary>>),
      do: {:ok, %{data | buffer: tail, phase: :headers}}

    defp parse_opening_boundary_rest(data, <<"--", _epilogue::binary>>),
      do: {:ok, mark_done(data)}

    defp parse_opening_boundary_rest(data, _rest),
      do: malformed("Malformed multipart body: invalid opening boundary", data)

    defp consume_part_headers(data, rest, {:field, %{name: name}}) do
      {:ok,
       %{
         data
         | buffer: rest,
           phase: :field,
           current_field: %{name: name, chunks: []}
       }}
    end

    defp consume_part_headers(data, rest, {:file, file_info}) do
      part_id = data.next_part_id
      entry_index = length(data.entries)
      {file, current_file} = build_file_entry(data, file_info, part_id, entry_index)

      {:ok,
       %{
         data
         | buffer: rest,
           phase: :file,
           ready?: true,
           entries: data.entries ++ [{file_info.name, file}],
           current_file: current_file,
           next_part_id: part_id + 1
       }}
    end

    defp build_file_entry(
           data,
           %{name: name, filename: filename, type: type},
           part_id,
           entry_index
         ) do
      case data.materializing? do
        true -> build_materialized_file_entry(name, filename, type, part_id, entry_index)
        false -> build_live_file_entry(name, filename, type, part_id, entry_index)
      end
    end

    defp build_materialized_file_entry(name, filename, type, part_id, entry_index) do
      file = File.new([], name: name, filename: filename, type: type, size: nil, stream: nil)

      current_file = %{
        id: part_id,
        file: file,
        entry_index: entry_index,
        stream_pid: nil,
        mode: :discard,
        size: 0
      }

      {file, current_file}
    end

    defp build_live_file_entry(name, filename, type, part_id, entry_index) do
      coordinator_pid = self()

      stream =
        ReadableStream.new(%{
          pull: fn controller -> child_pull(coordinator_pid, part_id, controller) end,
          cancel: fn reason -> child_cancel(coordinator_pid, part_id, reason) end
        })

      file = File.new([], name: name, filename: filename, type: type, size: nil, stream: stream)

      current_file = %{
        id: part_id,
        file: file,
        entry_index: entry_index,
        stream_pid: stream.controller_pid,
        mode: :await_pull,
        size: 0
      }

      {file, current_file}
    end

    defp emit_without_boundary(buffer, retain_bytes) do
      case byte_size(buffer) > retain_bytes do
        true ->
          emit_size = byte_size(buffer) - retain_bytes
          emit_chunk(buffer, emit_size)

        false ->
          :need_more
      end
    end

    defp emit_before_match(buffer, match_start), do: emit_chunk(buffer, match_start)

    defp classify_boundary_match(buffer, match_start, after_prefix_start) do
      case binary_part(buffer, after_prefix_start, 2) do
        "--" -> emit_boundary(buffer, match_start, after_prefix_start, :final)
        "\r\n" -> emit_boundary(buffer, match_start, after_prefix_start, :part)
        _other -> emit_chunk(buffer, match_start + 1)
      end
    end

    defp emit_boundary(buffer, match_start, after_prefix_start, transition) do
      emit = binary_part(buffer, 0, match_start)
      rest_start = after_prefix_start + 2
      rest = binary_part(buffer, rest_start, byte_size(buffer) - rest_start)
      {:boundary, emit, rest, transition}
    end

    defp emit_chunk(buffer, emit_size) do
      emit = binary_part(buffer, 0, emit_size)
      rest = binary_part(buffer, emit_size, byte_size(buffer) - emit_size)
      {:data, emit, rest}
    end

    defp build_part_info(name, nil, _content_type), do: {:field, %{name: name}}

    defp build_part_info(name, filename, content_type) do
      {:file, %{name: name, filename: filename, type: content_type}}
    end

    defp parse_form_data_disposition(value) do
      params = parse_disposition_params(value)
      name = Map.get(params, "name")
      filename = Map.get(params, "filename*") || Map.get(params, "filename")

      case name do
        nil ->
          {:error, TypeError.exception("Malformed multipart body: missing disposition name")}

        "" ->
          {:error, TypeError.exception("Malformed multipart body: missing disposition name")}

        _name ->
          {:ok, %{name: name, filename: filename}}
      end
    end

    defp unwrap!(:await_ready, {:ok, :ok}), do: :ok
    defp unwrap!(:value, {:ok, value}), do: value
    defp unwrap!(:next_entry, {:ok, {:found, entry}}), do: {:ok, entry}
    defp unwrap!(:next_entry, {:ok, :done}), do: :done
    defp unwrap!(_kind, {:error, %TypeError{} = reason}), do: raise(reason)
    defp unwrap!(_kind, {:error, reason}), do: exit(reason)

    defp safe_call(fun) do
      fun.()
    catch
      :exit, _ -> :ok
    end

    defp normalize_call_exit(reason) do
      if is_tuple(reason) and tuple_size(reason) == 2 and is_tuple(elem(reason, 0)) and
           tuple_size(elem(reason, 0)) == 2 and elem(elem(reason, 0), 0) == :shutdown,
         do: elem(elem(reason, 0), 1),
         else: reason
    end

    defp normalize_stop_reason({:shutdown, reason}), do: reason
    defp normalize_stop_reason(:normal), do: nil
    defp normalize_stop_reason(reason), do: reason

    defp hibernate_actions, do: [:hibernate]
  end
end

defimpl Enumerable, for: Web.FormData do
  alias Web.FormData.Parser

  def count(_), do: {:error, __MODULE__}
  def member?(_, _), do: {:error, __MODULE__}
  def slice(_), do: {:error, __MODULE__}

  # Static mode: iterate the in-memory entries list.
  def reduce(%Web.FormData{coordinator: nil, entries: entries}, acc, fun) do
    entries
    |> Enum.map(fn {name, value} -> [name, value] end)
    |> Enumerable.reduce(acc, fun)
  end

  # Live mode: stream entries one-by-one via RPC to the coordinator.
  def reduce(%Web.FormData{coordinator: pid}, {:halt, acc}, _fun) when is_pid(pid) do
    {:halted, acc}
  end

  def reduce(%Web.FormData{coordinator: pid} = form, {:suspend, acc}, fun) when is_pid(pid) do
    {:suspended, acc, &reduce(form, &1, fun)}
  end

  def reduce(%Web.FormData{coordinator: pid}, {:cont, acc}, fun) when is_pid(pid) do
    do_reduce(pid, 0, {:cont, acc}, fun)
  end

  defp do_reduce(_pid, _index, {:halt, acc}, _fun), do: {:halted, acc}

  defp do_reduce(pid, index, {:suspend, acc}, fun),
    do: {:suspended, acc, &do_reduce(pid, index, &1, fun)}

  defp do_reduce(pid, index, {:cont, acc}, fun) do
    case Parser.next_entry(pid, index) do
      {:ok, {name, value}} ->
        do_reduce(pid, index + 1, fun.([name, value], acc), fun)

      :done ->
        {:done, acc}
    end
  end
end

defimpl Collectable, for: Web.FormData do
  alias Web.FormData.Parser

  def into(%Web.FormData{} = original) do
    collector = fn
      form, {:cont, {name, value}} ->
        Web.FormData.append(form, name, value)

      form, {:cont, [name, value]} ->
        Web.FormData.append(form, name, value)

      _form, {:cont, other} ->
        raise ArgumentError,
              "Web.FormData collectable expects {name, value} or [name, value], got: #{inspect(other)}"

      form, :done ->
        freeze_live_form(form)

      _form, :halt ->
        :ok
    end

    {original, collector}
  end

  defp freeze_live_form(%Web.FormData{coordinator: pid} = form) when is_pid(pid) do
    entries = Parser.materialize(pid)
    %{form | entries: entries, coordinator: nil}
  end

  defp freeze_live_form(form), do: form
end
