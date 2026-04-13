defmodule Web.AsyncContext do
  @moduledoc """
  Namespace for the TC39-style async-context primitives used by `Web`.

  Public user-facing APIs live on:

    * `Web.AsyncContext.Variable`
    * `Web.AsyncContext.Snapshot`

  The top-level module keeps internal plumbing used by the runtime to preserve
  async context across BEAM process boundaries.

  ## Overview

  `Web.AsyncContext.Variable` provides scoped, named values that flow through
  promises and streams when snapshots are captured and re-entered.

  `Web.AsyncContext.Snapshot` captures those variable bindings along with
  logger metadata, `$callers`, and the current ambient abort signal so they can
  be re-entered later with `Snapshot.run/2`.

  ## Example

      use Web

      request_id = Web.AsyncContext.Variable.new("request_id")

      Web.AsyncContext.Variable.run(request_id, "req-42", fn ->
        snapshot = Web.AsyncContext.Snapshot.take()

        Task.async(fn ->
          Web.AsyncContext.Snapshot.run(snapshot, fn ->
            Web.AsyncContext.Variable.get(request_id)
          end)
        end)
        |> Task.await()
      end)
  """

  @ambient_signal_key {__MODULE__, :ambient_signal}

  @doc false
  @spec with_signal(Web.AbortSignal.t(), (-> result)) :: result when result: var
  def with_signal(%Web.AbortSignal{} = signal, fun) when is_function(fun, 0) do
    previous = Process.get(@ambient_signal_key)
    Process.put(@ambient_signal_key, signal)

    try do
      fun.()
    after
      case previous do
        nil -> Process.delete(@ambient_signal_key)
        prev -> Process.put(@ambient_signal_key, prev)
      end
    end
  end

  @doc false
  @spec ambient_signal_key() :: term()
  def ambient_signal_key, do: @ambient_signal_key
end
