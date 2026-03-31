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
  defstruct [:controller_pid]

  alias Web.ReadableStream.Controller
  alias Web.ReadableStreamDefaultReader
  alias Web.TypeError

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
    {:ok, pid} = Controller.start_link(source: underlying_source)
    %__MODULE__{controller_pid: pid}
  end

  @doc """
  Locks the stream and returns a reader.

  ## Examples

      iex> stream = Web.ReadableStream.new()
      iex> reader = Web.ReadableStream.get_reader(stream)
      iex> is_struct(reader, Web.ReadableStreamDefaultReader)
      true
  """
  def get_reader(%__MODULE__{controller_pid: pid}) do
    case Controller.get_reader(pid) do
      :ok ->
        %Web.ReadableStreamDefaultReader{controller_pid: pid}

      {:error, :already_locked} ->
        raise TypeError, "ReadableStream is already locked"
    end
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
    case Controller.tee(pid) do
      {:ok, {s1, s2}} ->
        {s1, s2}

      {:error, :already_locked} ->
        raise TypeError, "ReadableStream is already locked"
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
