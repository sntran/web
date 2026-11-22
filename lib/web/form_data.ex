defmodule Web.FormData do
  @moduledoc """
  WHATWG-style FormData container.

  Programmatically constructed instances store entries eagerly. Multipart-parsed
  instances are live-backed by a coordinator process that discovers entries lazily.

  ## A form as a body

  A form is a body of a `Web.Request` or a `Web.Response`. The body is
  encoded as `multipart/form-data`, as the HTML Standard specifies, and the
  header `content-type` gets the boundary of the form:

      iex> form = Web.FormData.new() |> Web.FormData.append("name", "value")
      iex> response = Web.Response.new(form)
      iex> headers = response.headers
      iex> "multipart/form-data; boundary=" <> boundary = Web.Headers.get(headers, "content-type")
      iex> text = Web.await(Web.Response.text(response))
      iex> String.split(text, "\\r\\n") -- ["--" <> boundary, "--" <> boundary <> "--"]
      [~s(Content-Disposition: form-data; name="name"), "", "value", ""]

  The bytes of a file are read from its stream chunk by chunk. A form with
  all its data in memory has a content length, and `Web.fetch/2` can send it
  again after a redirect.

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
  Creates a new FormData with no entries, as `new FormData()` of the
  XMLHttpRequest Standard. A server runtime has no form element, thus the
  constructor has no arguments.

  The form gets a new random boundary for its `multipart/form-data`
  encoding.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{entries: [], boundary: default_boundary()}

  @doc """
  Appends a value for a field name.

  A value that is a `Web.Blob` or a `Web.File` becomes a `Web.File`, as
  the steps "create an entry" of the XMLHttpRequest Standard specify. The
  name of the file is `filename`. When `filename` is `nil`, a file keeps
  its name, and a blob gets the name `"blob"`.

  ## Examples

      iex> blob = Web.Blob.new(["bytes"], type: "text/plain")
      iex> form = Web.FormData.new() |> Web.FormData.append("upload", blob, "notes.txt")
      iex> %Web.File{name: name, type: type} = Web.FormData.get(form, "upload")
      iex> {name, type}
      {"notes.txt", "text/plain"}
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
    normalized_value = normalize_value(value, filename)
    %{form | entries: entries ++ [{normalized_name, normalized_value}]}
  end

  @doc """
  Sets a single value for a field name, replacing existing entries.

  A blob or a file becomes a `Web.File` with the rules of `append/4`.
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
  Returns `true` if an entry has the name, as `has()` of the
  XMLHttpRequest Standard.
  """
  @spec has(t(), term()) :: boolean()
  def has(%__MODULE__{coordinator: pid}, name) when is_pid(pid) do
    normalized_name = to_string(name)
    Parser.has?(pid, normalized_name)
  end

  def has(%__MODULE__{} = form, name) do
    not is_nil(get(form, name))
  end

  @doc """
  Returns ordered entries.
  """
  @spec entries(t()) :: Enumerable.t()
  def entries(%__MODULE__{} = form) do
    form
  end

  @doc false
  # Parses a `multipart/form-data` body into a form that a coordinator
  # process backs: the step of `formData()` of the Fetch Standard for a
  # multipart body. See `Web.Request.form_data/1`.
  @spec parse(Web.ReadableStream.t() | binary() | iodata(), String.t(), keyword()) :: t()
  def parse(stream_or_binary, boundary, opts \\ []) do
    normalized_boundary = normalize_boundary(boundary)
    # The parser takes the lock of the stream process in its start.
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

  @doc false
  # Returns `true` if the form can be encoded more than one time: its
  # entries are in memory, and no file has a stream that can be read only
  # one time. A request with such a body can follow a redirect that sends
  # the body again.
  @spec static?(t()) :: boolean()
  def static?(%__MODULE__{coordinator: nil, entries: entries}) do
    Enum.all?(entries, fn
      {_name, %File{stream: stream}} -> is_nil(stream)
      {_name, _value} -> true
    end)
  end

  def static?(%__MODULE__{}), do: false

  @doc false
  # The value of the header `content-type` for the body of the form.
  @spec content_type(t()) :: String.t()
  def content_type(%__MODULE__{boundary: boundary}) do
    "multipart/form-data; boundary=" <> boundary
  end

  # The steps "create an entry" of the XMLHttpRequest Standard. A blob that
  # is not a file becomes a new File object with the same bytes and the name
  # "blob". A file name that the caller gives makes a new File object with
  # the same bytes and that name. The new file keeps the type and the time
  # of the last change.
  defp normalize_value(%File{} = file, nil), do: file

  defp normalize_value(%File{} = file, filename),
    do: %{file | id: make_ref(), name: to_string(filename)}

  defp normalize_value(%Web.Blob{} = blob, filename),
    do: File.new(blob.parts, to_string(filename || "blob"), type: blob.type)

  defp normalize_value(value, _filename), do: to_string(value)

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

    alias Web.AbortSignal
    alias Web.AsyncContext.Snapshot
    alias Web.File
    alias Web.FormData.Encoder
    alias Web.Internal.Bytes
    alias Web.ReadableStream
    alias Web.TypeError

    @header_separator "\r\n\r\n"

    def start_link(source, boundary, opts \\ []) do
      caller = self()
      owner = Keyword.get(opts, :owner, self())
      reply_ref = make_ref()
      snapshot = Snapshot.new()

      {_owner_pid, owner_ref} =
        spawn_monitor(fn ->
          start_link_owner(caller, owner, reply_ref, source, boundary, opts, snapshot)
        end)

      receive do
        {^reply_ref, result} ->
          Process.demonitor(owner_ref, [:flush])
          result

        {:DOWN, ^owner_ref, :process, _pid, reason} ->
          {:error, normalize_call_exit(reason)}
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

    # A parser that stopped cannot give the rest of the file part: the
    # stream gets an error, not an end.
    def child_pull(pid, part_id, controller) do
      case call(pid, {:pull_file, part_id, controller}) do
        {:error, reason} -> ReadableStream.error(controller.pid, file_error(reason))
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

    defp start_link_owner(caller, owner, reply_ref, source, boundary, opts, snapshot) do
      Process.flag(:trap_exit, true)
      owner_ref = Process.monitor(owner)
      Snapshot.restore(snapshot)

      case :gen_statem.start_link(__MODULE__, {source, boundary, opts, snapshot, self()}, []) do
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
        # The owner of the form stopped, thus the parser stops. The parser
        # traps exits: it does its terminate, which ends its file stream.
        {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
          Process.exit(pid, :shutdown)
          :ok

        {:EXIT, ^pid, _reason} ->
          :ok
      end
    end

    @impl true
    def callback_mode, do: :handle_event_function

    @impl true
    def init({%ReadableStream{} = source, boundary, opts, snapshot, parent}) do
      Process.flag(:message_queue_data, :off_heap)
      # The exit of the parent, the process of the owner, comes as a
      # message: the parser then stops with its terminate.
      Process.flag(:trap_exit, true)
      Snapshot.restore(snapshot)

      struct_snapshot = Keyword.get(opts, :struct_snapshot)

      subscription =
        maybe_bind_ambient_signal(Keyword.get(opts, :signal), snapshot, struct_snapshot)

      case aborted_reason(subscription) do
        nil ->
          data = %{
            parent: parent,
            source_pid: nil,
            source_lock_released?: false,
            signal_subscription: subscription,
            async_context: snapshot,
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

          case lock_source(source) do
            {:ok, source_pid} ->
              {:ok, :running, %{data | source_pid: source_pid}}

            {:error, :already_locked} ->
              {:stop, TypeError.exception("ReadableStream is already locked")}

            {:error, reason} ->
              {:stop, reason}
          end

        reason ->
          {:stop, {:shutdown, reason}}
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
        # The parse is complete: each call that waits gets its answer.
        {:reply, entries, done_data} ->
          {:ok, done_data, actions} = resolve_pending(done_data)
          {:stop_and_reply, :normal, [{:reply, from, {:ok, entries}} | actions], done_data}

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
      data
      |> maybe_mark_file_discard(part_id)
      |> answer_pending([{:reply, from, :ok}])
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
          answer_pending(data, [{:reply, from, {:ok, reply}}])

        :need_more ->
          case ensure_answer(request, data) do
            {:reply, reply, next_data} ->
              answer_pending(next_data, [{:reply, from, {:ok, reply}}])

            # The query waits after the calls that waited before it.
            {:blocked, next_data} ->
              waiter = %{from: from, request: request}
              answer_pending(%{next_data | pending: next_data.pending ++ [waiter]}, [])

            {:error, reason, next_data} ->
              abort_later(reason, next_data, [{:reply, from, {:error, reason}}])
          end
      end
    end

    # A query can read more of the body, or discard a file part: a call that
    # waits can have its answer now. Thus each call that waits gets its
    # answer, also when no pull of a file stream comes after the query. See
    # `tla/FormDataParser.tla`.
    defp answer_pending(data, actions) do
      case resolve_pending(data) do
        {:ok, next_data, pending_actions} ->
          reply_or_stop(next_data, actions ++ pending_actions)

        {:error, reason, next_data, pending_actions} ->
          abort_later(reason, next_data, actions ++ pending_actions)
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
          ReadableStream.enqueue(controller.pid, Web.Uint8Array.from(emit))
          {:ok, bump_file_size(%{data | buffer: rest}, byte_size(emit))}

        {:boundary, emit, rest, transition} ->
          next_data = bump_file_size(data, byte_size(emit))

          if emit != "" do
            ReadableStream.enqueue(controller.pid, Web.Uint8Array.from(emit))
          end

          ReadableStream.close(controller.pid)
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
      discard_child_stream(cf.stream_pid, discard_error())
      %{data | current_file: %{cf | mode: :discard}}
    end

    defp maybe_discard_before_index(data, _index), do: data

    defp discard_error do
      TypeError.exception("The file part is not complete: a read of its form went past it.")
    end

    defp begin_materialization(%{materializing?: true} = data), do: data

    defp begin_materialization(%{current_file: %{mode: :await_pull} = current_file} = data) do
      discard_child_stream(current_file.stream_pid, discard_error())
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

        # The steps of `formData()` of the Fetch Standard: the type of a
        # file is the value of the header `Content-Type` of the part, or
        # `text/plain` when the part has no such header.
        headers when is_map(headers) ->
          with disposition when is_binary(disposition) <-
                 Map.get(headers, "content-disposition") ||
                   {:error,
                    TypeError.exception("Malformed multipart body: missing content-disposition")},
               {:ok, %{name: name, filename: filename}} <- parse_content_disposition(disposition) do
            {:ok, build_part_info(name, filename, Map.get(headers, "content-type", "text/plain"))}
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

    # The value of a parameter is a token, or text in quotation marks.
    #
    # A browser does not escape a backslash in such text: the HTML Standard
    # escapes only a line feed, a carriage return, and a quotation mark, with
    # a percent sign. Thus a backslash stays as it is, and a file name such
    # as `C:\dir\file.txt` is not changed. Some other clients escape a
    # quotation mark with a backslash. Thus a quotation mark after a
    # backslash is part of the text, unless the parameter ends there.
    defp parse_disposition_params(value) do
      ~r/;\s*([!#$%&'*+\-.^_`|~0-9A-Za-z]+\*?)\s*=\s*("(?:[^"]|(?<=\\)"(?!\s*(?:;|\z)))*"|[^;]*)/u
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
        |> String.replace("\\\"", "\"")
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

    # A read of the source. The parser waits for the source, and it takes a
    # cancel of the form, an abort of its signal, and the stop of its owner
    # while it waits: a source that stalls does not keep them. See
    # `tla/FormDataParser.tla`.
    defp read_more(data) do
      source = data.source_pid
      monitor = Process.monitor(source)
      send(source, {:"$gen_call", {self(), monitor}, {:read, self()}})

      case await_read(data, monitor) do
        {:reply, reply} ->
          Process.demonitor(monitor, [:flush])
          read_reply(reply, data)

        {:stop, reason} ->
          Process.demonitor(monitor, [:flush])
          {:error, reason, data}
      end
    end

    defp await_read(data, monitor) do
      receive do
        {^monitor, reply} ->
          {:reply, reply}

        # A source that stopped gives the reply of `Web.Stream.call/3` for a
        # stream that is gone.
        {:DOWN, ^monitor, :process, _pid, _reason} ->
          {:reply, {:error, :not_locked_by_reader}}

        {:"$gen_call", from, {:cancel, reason}} ->
          :gen_statem.reply(from, :ok)
          {:stop, reason}

        {:EXIT, parent, _reason} when parent == data.parent ->
          {:stop, gone_error()}

        message when elem(message, 0) in [:abort, :DOWN] ->
          case abort_reason_from_message(message, data.signal_subscription) do
            {:ok, reason} -> {:stop, reason}
            :ignore -> await_read(data, monitor)
          end
      end
    end

    defp read_reply(reply, data) do
      case reply do
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

    # The error of a call to a parser that stopped, and of the stop of its
    # owner.
    defp gone_error do
      TypeError.exception(
        "The form data is not available. Its body ended, or its parser stopped."
      )
    end

    defp normalize_chunk(chunk) do
      case Bytes.to_binary(chunk) do
        {:ok, binary} ->
          {:ok, binary}

        :error ->
          {:error,
           TypeError.exception("Multipart stream chunk must be binary, Uint8Array, or iodata")}
      end
    end

    defp malformed(message, data), do: {:error, TypeError.exception(message), data}

    defp continue_after_read(data, continue_fun, eof_message) do
      case read_more(data) do
        {:ok, next_data} -> continue_fun.(next_data)
        {:done, next_data} -> malformed(eof_message, next_data)
        {:error, reason, next_data} -> {:error, reason, next_data}
      end
    end

    # The parser is a process that runs at the same time as a cancel of the
    # file stream. Thus it uses the functions with no check: a chunk or a
    # close for a stream that is closed has no effect.
    defp close_pull_controller(controller) do
      ReadableStream.close(controller.pid)
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

    defp subscribe_signal(signal) do
      case AbortSignal.subscribe(signal) do
        {:ok, subscription} ->
          subscription

        {:error, :aborted} ->
          %{
            type: :token,
            token: make_ref(),
            aborted: true,
            reason: AbortSignal.reason(signal) || AbortSignal.default_reason()
          }
      end
    end

    defp maybe_bind_ambient_signal(explicit, site_snapshot, struct_snapshot) do
      struct_ambient = struct_snapshot && struct_snapshot.ambient_signal

      # Collect all distinct non-nil signals so either can trigger abort.
      signals =
        [explicit, struct_ambient, site_snapshot.ambient_signal]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      case signals do
        [] -> nil
        [single] -> subscribe_signal(single)
        multiple -> Enum.map(multiple, &subscribe_signal/1)
      end
    end

    defp aborted_reason(nil), do: nil

    defp aborted_reason(subscriptions) when is_list(subscriptions) do
      Enum.find_value(subscriptions, fn
        %{aborted: true, reason: reason} -> reason
        _ -> nil
      end)
    end

    defp aborted_reason(%{aborted: true, reason: reason}), do: reason
    defp aborted_reason(_), do: nil

    defp unsubscribe_signal(nil), do: :ok

    defp unsubscribe_signal(subscriptions) when is_list(subscriptions) do
      Enum.each(subscriptions, &unsubscribe_signal/1)
    end

    defp unsubscribe_signal(subscription), do: AbortSignal.unsubscribe(subscription)

    defp abort_reason_from_message(_message, nil), do: :ignore

    defp abort_reason_from_message(_message, []), do: :ignore

    defp abort_reason_from_message(message, [sub | rest]) do
      case abort_reason_from_message(message, sub) do
        :ignore -> abort_reason_from_message(message, rest)
        result -> result
      end
    end

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

    # The two functions below have no effect on a source that stopped.
    defp release_source_lock(%{source_pid: source_pid} = data) do
      _ = ReadableStream.release_lock(source_pid)
      %{data | source_lock_released?: true}
    end

    defp maybe_cancel_source(%{source_lock_released?: true}, _reason), do: :ok
    defp maybe_cancel_source(_data, :normal), do: :ok
    defp maybe_cancel_source(_data, nil), do: :ok

    defp maybe_cancel_source(%{source_pid: source_pid}, reason) do
      _outcome = Web.Promise.wait(ReadableStream.cancel(source_pid, reason))
      :ok
    end

    # The parser cannot give the rest of the file part: the file stream gets
    # an error, thus its reader does not take a short file as complete. A
    # cancel would close the stream as at the end of the file.
    defp error_child_stream(nil, _reason), do: :ok

    defp error_child_stream(stream_pid, reason) when is_pid(stream_pid) do
      if Process.alive?(stream_pid) do
        ReadableStream.error(stream_pid, file_error(reason))
      end

      :ok
    end

    # A stop with no reason, or the stop of the owner, gives a TypeError.
    # An abort gives its reason, as the body stream of the Fetch Standard.
    defp file_error(reason) when reason in [nil, :normal, :shutdown] do
      TypeError.exception("The file part is not complete: its form stopped.")
    end

    defp file_error(reason), do: reason

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

    # The lock step of a reader: see `ReadableStream.__lock__/2`. A stream
    # that cannot have a process raises a `TypeError`.
    defp lock_source(source) do
      ReadableStream.__lock__(source, &safe_get_reader/1)
    rescue
      error in TypeError -> {:error, error}
    end

    defp safe_get_reader(pid) do
      with :ok <- ReadableStream.get_reader(pid), do: {:ok, pid}
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
        <<opening::binary-size(^opening_size), rest::binary>>
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

    # The steps of the multipart/form-data parser of the Fetch Standard: a
    # part with a file name is a new File object with that name and the
    # type of the part. The name of the field is the name of the entry. The
    # bytes come later, from the body.
    defp build_file_entry(data, %{filename: filename, type: type}, part_id, entry_index) do
      file = File.new([], filename, type: type)

      case data.materializing? do
        true ->
          build_materialized_file_entry(file, part_id, entry_index)

        false ->
          build_live_file_entry(file, part_id, entry_index, data.async_context)
      end
    end

    defp build_materialized_file_entry(file, part_id, entry_index) do
      file = %{file | size: nil}

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

    defp build_live_file_entry(file, part_id, entry_index, %Snapshot{} = snapshot) do
      coordinator_pid = self()

      stream =
        Snapshot.run(snapshot, fn ->
          ReadableStream.new(%{
            pull: fn controller -> child_pull(coordinator_pid, part_id, controller) end,
            cancel: fn reason -> child_cancel(coordinator_pid, part_id, reason) end
          })
        end)

      file = %{file | size: nil, stream: stream}

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

    # A name in quotation marks has escapes for a line feed, a carriage
    # return, and a quotation mark, as the HTML Standard specifies for the
    # encoding of a form. The parameter `filename*` has its own encoding.
    defp parse_form_data_disposition(value) do
      params = parse_disposition_params(value)
      name = unescape(Map.get(params, "name"))
      filename = Map.get(params, "filename*") || unescape(Map.get(params, "filename"))

      case name do
        nil ->
          {:error, TypeError.exception("Malformed multipart body: missing disposition name")}

        "" ->
          {:error, TypeError.exception("Malformed multipart body: missing disposition name")}

        _name ->
          {:ok, %{name: name, filename: filename}}
      end
    end

    defp unescape(nil), do: nil
    defp unescape(text), do: Encoder.unescape(text)

    defp unwrap!(:await_ready, {:ok, :ok}), do: :ok
    defp unwrap!(:value, {:ok, value}), do: value
    defp unwrap!(:next_entry, {:ok, {:found, entry}}), do: {:ok, entry}
    defp unwrap!(:next_entry, {:ok, :done}), do: :done
    defp unwrap!(_kind, {:error, %TypeError{} = reason}), do: raise(reason)
    defp unwrap!(_kind, {:error, reason}), do: exit(reason)

    # The parser stopped before the call: its form is not available, as a
    # stream that is gone (see `Web.Stream.call/3`). A body that fails is a
    # `TypeError` in the Fetch Standard.
    defp normalize_call_exit({reason, {:gen_statem, :call, _args}})
         when reason in [:noproc, :normal, :shutdown, :killed] do
      gone_error()
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
