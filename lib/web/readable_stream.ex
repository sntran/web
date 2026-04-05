defmodule Web.ReadableStream do
  @moduledoc """
  An Elixir implementation of the WHATWG ReadableStream standard.

  Provides a way to represent a stream of data that can be consumed or multicasted (teed).
  The implementation follows the Web API concepts, including:

  - **Backpressure**: The stream respects the consumption speed of its readers.
  - **Locking**: A stream can be locked to a single reader using `get_reader/1`.
  - **Teeing**: A stream can be split into two branches via `tee/1`.

  ## Technical Implementation Notes

  ### [[disturbed]] slot
  In the WHATWG spec, a stream is "disturbed" once data has been requested from it or it
  has been cancelled. In this implementation, the `[[disturbed]]` state prevents certain
  operations like `tee/1` if the stream has already been interacted with.

  ### Teeing and Backpressure
  The `tee/1` implementation uses a "multicast" strategy. The original stream's backpressure
  signal (the `desired_size`) is calculated as `max(branch_a.desired_size, branch_b.desired_size)`.
  This ensures that the source continues to pull data as long as at least one branch has capacity.

  ### Buffer Bloat Warning
  When using `tee/1`, be aware that a significantly slower consumer on one branch will NOT
  stop the other branch from receiving data. This can lead to "Buffer Bloat" (unbounded memory usage)
  on the slower branch's internal queue. If consumers have vastly different speeds, consider
  implementing custom branch-level backpressure or using a different distribution strategy.
  """

  use Web.Stream

  defstruct [:controller_pid]

  alias Web.ArrayBuffer
  alias Web.Blob
  alias Web.Uint8Array
  alias Web.TypeError
  alias Web.URLSearchParams

  # ---------------------------------------------------------------------------
  # Web.Stream behavior callbacks
  # ---------------------------------------------------------------------------

  @impl Web.Stream
  def start(pid, opts) do
    source = Keyword.get(opts, :source)
    state = %{source: source, pid: pid, started: false}

    if is_map(source) and is_function(source[:start], 1) do
      ctrl = %Web.ReadableStreamDefaultController{pid: pid}
      fun = source.start

      {:producer, state,
       [{:next_event, :internal, {:start_task, fn -> fun.(ctrl) end}}]}
    else
      {:producer, state}
    end
  end

  @impl Web.Stream
  def pull(_ctrl, %{source: source, pid: pid} = state) do
    case source do
      %{pull: pull} when is_function(pull, 1) ->
        ctrl = %Web.ReadableStreamDefaultController{pid: pid}
        pull.(ctrl)
        {:ok, %{state | started: true}}

      src when is_pid(src) ->
        send(src, {:pull, pid})
        {:ok, %{state | started: true}, :pause}

      {m, f, a} ->
        ctrl = %Web.ReadableStreamDefaultController{pid: pid}
        apply(m, f, a ++ [ctrl])
        {:ok, %{state | started: true}}

      fun when is_function(fun, 1) ->
        ctrl = %Web.ReadableStreamDefaultController{pid: pid}
        fun.(ctrl)
        {:ok, %{state | started: true}}

      _ ->
        # No pull source — pause to avoid a busy-loop
        {:ok, state, :pause}
    end
  end

  @impl Web.Stream
  def terminate(reason, %{source: source}) do
    case source do
      %{cancel: cancel} when is_function(cancel, 1) ->
        cancel.(reason)

      src when is_pid(src) ->
        send(src, {:web_stream_cancel, self(), reason})

      {m, f, a} ->
        apply(m, f, a ++ [reason])

      fun when is_function(fun, 1) ->
        fun.(reason)

      _ ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new ReadableStream with the given underlying source.

  ## Examples

      iex> source = %{
      ...>   start: fn controller ->
      ...>     Web.ReadableStreamDefaultController.enqueue(controller, "hello")
      ...>     Web.ReadableStreamDefaultController.close(controller)
      ...>   end
      ...> }
      iex> stream = Web.ReadableStream.new(source)
      iex> Enum.to_list(stream)
      ["hello"]
  """
  def new(underlying_source \\ %{}) do
    {:ok, pid} = start_link(source: underlying_source)
    %__MODULE__{controller_pid: pid}
  end

  @doc """
  Normalizes body-like input into a `ReadableStream`.

  ## Examples

      iex> stream = Web.ReadableStream.from("hello")
      iex> Web.ReadableStream.read_all(stream)
      {:ok, "hello"}

      iex> stream = Web.ReadableStream.from(nil)
      iex> Web.ReadableStream.read_all(stream)
      {:ok, ""}

      iex> existing = Web.ReadableStream.new()
      iex> Web.ReadableStream.from(existing) == existing
      true
  """
  def from(nil) do
    new(%{start: &Web.ReadableStreamDefaultController.close/1})
  end

  def from(%URLSearchParams{} = params) do
    from(URLSearchParams.to_string(params))
  end

  def from(%Blob{parts: parts}) do
    blob_parts_pid = start_blob_parts_queue(parts)

    new(%{
      pull: fn controller ->
        case ask_blob_parts_queue(blob_parts_pid) do
          :done ->
            Web.ReadableStreamDefaultController.close(controller)

          part ->
            Web.ReadableStreamDefaultController.enqueue(controller, part)
        end
      end,
      cancel: fn _reason ->
        if Process.alive?(blob_parts_pid) do
          send(blob_parts_pid, :stop)
        end
      end
    })
  end

  def from(%ArrayBuffer{data: data}) do
    from(data)
  end

  def from(%Uint8Array{} = bytes) do
    from(Uint8Array.to_binary(bytes))
  end

  def from(data) when is_binary(data) do
    new(%{
      start: fn controller ->
        Web.ReadableStreamDefaultController.enqueue(controller, data)
        Web.ReadableStreamDefaultController.close(controller)
      end
    })
  end

  def from(%__MODULE__{} = stream), do: stream

  def from(enumerable) do
    if Enumerable.impl_for(enumerable) do
      enumerator_pid = start_enumerator(enumerable)

      new(%{
        pull: fn controller ->
          next_chunk = ask_enumerator(enumerator_pid)

          case next_chunk do
            :done ->
              Web.ReadableStreamDefaultController.close(controller)

            chunk ->
              Web.ReadableStreamDefaultController.enqueue(controller, chunk)
          end
        end,
        cancel: fn _reason ->
          # coveralls-ignore-start
          if Process.alive?(enumerator_pid) do
            send(enumerator_pid, :stop)
          end

          # coveralls-ignore-stop
        end
      })
    else
      raise ArgumentError, "cannot normalize body from #{inspect(enumerable)}"
    end
  end

  defp start_blob_parts_queue(parts) do
    spawn(fn -> blob_parts_queue_loop(parts) end)
  end

  defp blob_parts_queue_loop(parts) do
    receive do
      {:next, from, ref} ->
        case next_blob_part(parts) do
          {:ok, part, rest} ->
            send(from, {ref, part})
            blob_parts_queue_loop(rest)

          :done ->
            send(from, {ref, :done})
            :ok
        end

      :stop ->
        :ok
    end
  end

  defp next_blob_part([part | rest]) when is_binary(part), do: {:ok, part, rest}

  defp next_blob_part([%Blob{parts: nested_parts} | rest]),
    do: next_blob_part(nested_parts ++ rest)

  defp next_blob_part([]), do: :done

  defp ask_blob_parts_queue(pid) do
    ref = make_ref()
    send(pid, {:next, self(), ref})

    receive do
      {^ref, result} -> result
    end
  end

  defp next_enumerable_chunk(enumerable) when is_function(enumerable, 1) do
    case enumerable.({:cont, nil}) do
      {:suspended, chunk, continuation} -> {chunk, {:continuation, continuation}}
      {:done, nil} -> {:done, :done}
      # coveralls-ignore-next-line
      {:halted, nil} -> {:done, :done}
    end
  end

  defp next_enumerable_chunk(enumerable) do
    reducer = fn chunk, _acc -> {:suspend, chunk} end

    case Enumerable.reduce(enumerable, {:cont, nil}, reducer) do
      {:suspended, chunk, continuation} -> {chunk, {:continuation, continuation}}
      {:done, nil} -> {:done, :done}
      # coveralls-ignore-next-line
      {:halted, nil} -> {:done, :done}
    end
  end

  defp start_enumerator(enumerable) do
    spawn(fn -> enumerator_loop({:initial, enumerable}) end)
  end

  defp enumerator_loop(state) do
    receive do
      {:next, from, ref} ->
        case state do
          :done ->
            # coveralls-ignore-start
            send(from, {ref, :done})
            :ok

          # coveralls-ignore-stop

          {:initial, current_enumerable} ->
            case next_enumerable_chunk(current_enumerable) do
              {:done, :done} ->
                # coveralls-ignore-start
                send(from, {ref, :done})
                :ok

                # coveralls-ignore-stop

              {chunk, next_state} ->
                send(from, {ref, chunk})
                enumerator_loop(next_state)
            end

          {:continuation, continuation} ->
            case next_enumerable_chunk(continuation) do
              {:done, :done} ->
                # coveralls-ignore-start
                send(from, {ref, :done})
                :ok

                # coveralls-ignore-stop

              {chunk, next_state} ->
                send(from, {ref, chunk})
                enumerator_loop(next_state)
            end
        end

      # coveralls-ignore-next-line
      :stop ->
        :ok
    end
  end

  defp ask_enumerator(pid) do
    ref = make_ref()
    send(pid, {:next, self(), ref})

    receive do
      {^ref, result} -> result
    end
  end

  @doc """
  Returns whether the stream's `[[disturbed]]` slot has been set.
  """
  def disturbed?(nil), do: false
  def disturbed?(body) when is_binary(body) or is_list(body), do: false

  def disturbed?(%__MODULE__{controller_pid: pid}) do
    disturbed?(pid)
  end

  def disturbed?(pid) when is_pid(pid) do
    :gen_statem.call(pid, :disturbed?)
  end

  def disturbed?(_body), do: false

  @doc """
  Returns `true` when the stream currently has an active reader lock.
  """
  def locked?(nil), do: false
  def locked?(body) when is_binary(body) or is_list(body), do: false

  def locked?(%__MODULE__{controller_pid: pid}) do
    locked?(pid)
  end

  def locked?(pid) when is_pid(pid) do
    :gen_statem.call(pid, :locked?)
  end

  def locked?(_body), do: false

  @doc """
  Reads a body to completion and returns the concatenated binary.
  """
  def read_all(nil), do: {:ok, ""}
  def read_all(body) when is_binary(body), do: {:ok, body}
  def read_all(body) when is_list(body), do: {:ok, IO.iodata_to_binary(body)}

  def read_all(%__MODULE__{} = stream) do
    case get_reader(stream.controller_pid) do
      :ok ->
        do_read_all(stream.controller_pid, [])

      {:error, :already_locked} ->
        {:error, TypeError.exception("ReadableStream is already locked")}
    end
  end

  def read_all(pid) when is_pid(pid) do
    read_all(%__MODULE__{controller_pid: pid})
  end

  def read_all(body) do
    if Enumerable.impl_for(body) do
      {:ok,
       body
       |> Enum.reduce([], fn chunk, acc -> [IO.iodata_to_binary(chunk) | acc] end)
       |> Enum.reverse()
       |> IO.iodata_to_binary()}
    else
      {:error, TypeError.exception("body is not readable")}
    end
  end

  @doc """
  Locks the stream and returns a reader.

  ## Examples

      iex> stream = Web.ReadableStream.new()
      iex> reader = Web.ReadableStream.get_reader(stream)
      iex> is_struct(reader, Web.ReadableStreamDefaultReader)
      true
  """
  def get_reader(pid) when is_pid(pid) do
    case :gen_statem.call(pid, {:get_reader, self()}) do
      {:ok, _ref} -> :ok
      {:error, :already_locked} -> {:error, :already_locked}
    end
  end

  def get_reader(%__MODULE__{controller_pid: pid}) do
    case get_reader(pid) do
      :ok ->
        %Web.ReadableStreamDefaultReader{controller_pid: pid}

      {:error, :already_locked} ->
        raise TypeError, "ReadableStream is already locked"
    end
  end

  def read(pid) do
    :gen_statem.call(pid, {:read, self()})
  end

  def force_unknown_error(pid) do
    :gen_statem.call(pid, :force_unknown_error)
  end

  def release_lock(pid) do
    :gen_statem.call(pid, {:release_lock, self()})
  end

  def get_desired_size(pid) do
    :gen_statem.call(pid, :get_desired_size)
  end

  def enqueue(pid, chunk) do
    :gen_statem.cast(pid, {:enqueue, chunk})
  end

  def close(pid) do
    :gen_statem.cast(pid, :close)
  end

  @impl Web.Stream
  def error(_reason, %{source: _} = state) do
    {:ok, state}
  end

  def error(pid, reason) when is_pid(pid) do
    :gen_statem.cast(pid, {:error, reason})
  end

  def cancel(pid, reason \\ :cancelled) do
    :gen_statem.cast(pid, {:cancel, reason})
  end

  def get_slots(pid) do
    :gen_statem.call(pid, :get_slots)
  end

  def tee(pid) when is_pid(pid) do
    :gen_statem.call(pid, :tee)
  end

  @doc """
  Tees the current readable stream, returning two new readable stream branches.

  ## Examples

      iex> stream = Web.ReadableStream.new(%{
      ...>   start: fn c ->
      ...>     Web.ReadableStreamDefaultController.enqueue(c, "a")
      ...>     Web.ReadableStreamDefaultController.close(c)
      ...>   end
      ...> })
      iex> {s1, s2} = Web.ReadableStream.tee(stream)
      iex> Enum.to_list(s1)
      ["a"]
      iex> Enum.to_list(s2)
      ["a"]
  """
  def tee(%__MODULE__{controller_pid: pid}) do
    case tee(pid) do
      {:ok, {s1, s2}} ->
        {s1, s2}

      {:error, :already_locked} ->
        raise TypeError, "ReadableStream is already locked"
    end
  end

  # coveralls-ignore-start
  def branch_cancelled(pid, child_pid) do
    :gen_statem.cast(pid, {:branch_cancelled, child_pid})
  end

  def report_desired_size(pid, child_pid, size) do
    :gen_statem.cast(pid, {:branch_desired_size, child_pid, size})
  end
  # coveralls-ignore-stop

  # ---------------------------------------------------------------------------
  # Private read_all helpers
  # ---------------------------------------------------------------------------

  defp do_read_all(pid, chunks) do
    case read(pid) do
      {:ok, chunk} ->
        do_read_all(pid, [chunk | chunks])

      :done ->
        release_lock(pid)
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:error, reason} ->
        release_lock(pid)
        {:error, reason}
    end
  end
end

defimpl Enumerable, for: Web.ReadableStream do
  alias Web.ReadableStreamDefaultReader

  def reduce(stream, acc, fun) do
    reader = Web.ReadableStream.get_reader(stream)
    do_reduce(reader, acc, fun)
  end

  defp do_reduce(reader, {:halt, acc}, _fun) do
    try do
      ReadableStreamDefaultReader.release_lock(reader)
    rescue
      # coveralls-ignore-next-line
      _ -> :ok
    end

    {:halted, acc}
  end

  defp do_reduce(reader, {:suspend, acc}, fun) do
    {:suspended, acc, &do_reduce(reader, &1, fun)}
  end

  defp do_reduce(reader, {:cont, acc}, fun) do
    case ReadableStreamDefaultReader.read(reader) do
      :done ->
        try do
          ReadableStreamDefaultReader.release_lock(reader)
        rescue
          # coveralls-ignore-next-line
          _ -> :ok
        end

        {:done, acc}

      chunk ->
        try do
          do_reduce(reader, fun.(chunk, acc), fun)
        rescue
          e ->
            try do
              ReadableStreamDefaultReader.release_lock(reader)
            rescue
              # coveralls-ignore-next-line
              _ -> :ok
            end

            reraise e, __STACKTRACE__
        end
    end
  end

  def count(_stream), do: {:error, __MODULE__}
  def member?(_stream, _element), do: {:error, __MODULE__}
  def slice(_stream), do: {:error, __MODULE__}
end
