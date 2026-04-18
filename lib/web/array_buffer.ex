defmodule Web.ArrayBuffer do
  @moduledoc """
  WHATWG-style ArrayBuffer representation with detachable backing storage.
  """

  defmodule TableOwner do
    @moduledoc false

    use GenServer

    def start_link(table_name) do
      GenServer.start(__MODULE__, table_name, name: __MODULE__)
    end

    def init(table_name) do
      {:ok, table_name}
    end

    def handle_call(:ensure_table, _from, table_name) do
      tid =
        case :ets.whereis(table_name) do
          :undefined ->
            :ets.new(table_name, [
              :named_table,
              :public,
              :set,
              read_concurrency: true,
              write_concurrency: true
            ])

          tid ->
            tid
        end

      {:reply, tid, table_name}
    end
  end

  alias Web.TypeError

  @table __MODULE__
  @table_owner Web.ArrayBuffer.TableOwner

  @enforce_keys [:id, :data, :byte_length]
  defstruct [:id, :data, :byte_length]

  @type t :: %__MODULE__{
          id: reference() | nil,
          data: binary(),
          byte_length: non_neg_integer()
        }

  @doc """
  Creates a new ArrayBuffer from a binary or from a byte length.

  ## Examples

      iex> buffer = Web.ArrayBuffer.new("hello")
      iex> {Web.ArrayBuffer.data(buffer), Web.ArrayBuffer.byte_length(buffer)}
      {"hello", 5}

      iex> buffer = Web.ArrayBuffer.new(4)
      iex> {Web.ArrayBuffer.data(buffer), Web.ArrayBuffer.byte_length(buffer)}
      {<<0, 0, 0, 0>>, 4}
  """
  @spec new(binary() | non_neg_integer()) :: t()
  def new(data) when is_binary(data) do
    build_buffer(data)
  end

  def new(byte_length) when is_integer(byte_length) and byte_length >= 0 do
    build_buffer(:binary.copy(<<0>>, byte_length))
  end

  @doc """
  Returns the backing binary for the buffer.

  Raises `Web.TypeError` when the buffer has been detached.
  """
  @spec data(t()) :: binary()
  def data(%__MODULE__{} = buffer) do
    case state(buffer) do
      %{detached?: true} ->
        raise TypeError.exception("Cannot access a detached ArrayBuffer")

      %{data: data} ->
        data
    end
  end

  @doc """
  Returns the current byte length of the buffer.
  """
  @spec byte_length(t()) :: non_neg_integer()
  def byte_length(%__MODULE__{} = buffer) do
    buffer
    |> state()
    |> Map.fetch!(:byte_length)
  end

  @doc """
  Returns whether the buffer has been detached.
  """
  @spec detached?(t()) :: boolean()
  def detached?(%__MODULE__{} = buffer) do
    buffer
    |> state()
    |> Map.fetch!(:detached?)
  end

  @doc """
  Detaches the buffer and clears its backing storage.
  """
  @spec detach(t()) :: t()
  def detach(%__MODULE__{} = buffer) do
    case buffer.id do
      id when is_reference(id) ->
        write_state(id, %{data: <<>>, byte_length: 0, detached?: true})
        %{buffer | data: <<>>, byte_length: 0}

      _ ->
        %{buffer | data: <<>>, byte_length: 0}
    end
  end

  @doc false
  @spec identity(t()) :: reference() | nil
  def identity(%__MODULE__{} = buffer), do: buffer.id

  defp build_buffer(data) do
    id = make_ref()
    write_state(id, %{data: data, byte_length: byte_size(data), detached?: false})
    %__MODULE__{id: id, data: data, byte_length: byte_size(data)}
  end

  defp state(%__MODULE__{} = buffer) do
    case buffer.id do
      id when is_reference(id) ->
        case :ets.lookup(table(), id) do
          [{^id, state}] -> state
          [] -> %{data: buffer.data, byte_length: buffer.byte_length, detached?: false}
        end

      _ ->
        %{data: buffer.data, byte_length: buffer.byte_length, detached?: false}
    end
  end

  defp write_state(id, state) do
    true = :ets.insert(table(), {id, state})
    :ok
  end

  defp table do
    owner = ensure_owner()

    case GenServer.call(owner, :ensure_table) do
      tid when is_reference(tid) -> tid
      tid when is_atom(tid) -> tid
    end
  end

  defp ensure_owner do
    case Process.whereis(@table_owner) do
      nil ->
        case TableOwner.start_link(@table) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      pid ->
        pid
    end
  end
end
