defmodule Web.AbortController do
  @moduledoc """
  An implementation of the WHATWG AbortController standard.

  Allows creating an `AbortSignal` that can be used to cancel asynchronous operations
  like `fetch/2`.

  ## Examples

      iex> controller = Web.AbortController.new()
      iex> %Web.AbortSignal{} = controller.signal
      iex> Process.alive?(controller.signal.pid)
      true
      iex> :ok = Web.AbortController.abort(controller, :timeout)
      iex> Process.sleep(10)
      iex> Process.alive?(controller.signal.pid)
      false
  """

  defstruct [:signal]

  @type t :: %__MODULE__{
          signal: Web.AbortSignal.t()
        }

  @doc """
  Creates a new abort controller and signal pair.

  ## Examples

      iex> controller = Web.AbortController.new()
      iex> match?(%Web.AbortController{signal: %Web.AbortSignal{}}, controller)
      true
      iex> Web.AbortController.abort(controller)
      :ok
  """
  def new do
    {:ok, pid} = Web.AbortSignal.start_link()

    %__MODULE__{
      signal: %Web.AbortSignal{aborted: false, reason: nil, pid: pid, ref: make_signal_ref(pid)}
    }
  end

  @doc """
  Aborts the controller's signal.

  ## Examples

      iex> controller = Web.AbortController.new()
      iex> Web.AbortController.abort(controller, :manual_cancel)
      :ok
  """
  def abort(%__MODULE__{signal: %Web.AbortSignal{pid: pid}}, reason \\ :aborted) do
    if Process.alive?(pid) do
      GenServer.cast(pid, {:abort, reason})
    end

    :ok
  end

  defp make_signal_ref(pid) do
    pid
    |> :sys.get_state()
    |> Map.fetch!(:ref)
  end
end
