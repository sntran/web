defmodule Web.Internal.AsyncStep do
  @moduledoc false

  # The steps of the async iterators of `Web.AsyncIterator`, and the
  # abstract operations of ECMAScript that their helpers use.
  #
  # An iterator process gets each step as the message
  # `{:"$web_async_iterator", step, {reply_to, ref}}` (see `request/3`), and
  # it sends the outcome to `reply_to` as
  # `{:"$web_async_iterator_reply", ref, outcome}` (see `reply/2`). The
  # iterator processes match the step message in their `receive`.
  # It sends one outcome for each step, in the sequence of its steps. A
  # process that awaits a step monitors the iterator process: an iterator
  # process stops only when it is done, or when its owner stops. Thus a
  # step of an iterator process that stopped gives `done: true`.

  alias Web.Internal.AsyncIteration
  alias Web.Internal.PromiseCell
  alias Web.Promise

  @request :"$web_async_iterator"
  @reply :"$web_async_iterator_reply"

  @doc "The iterator result `{ value: undefined, done: true }`."
  @spec done() :: %{value: nil, done: true}
  def done, do: %{value: nil, done: true}

  @doc "Sends the outcome of a step to the process that waits for it."
  @spec reply({pid(), reference()}, Promise.outcome()) :: :ok
  def reply({reply_to, ref}, outcome) do
    send(reply_to, {@reply, ref, outcome})
    :ok
  end

  @doc "Starts a step of the iterator process `pid`, for `reply_to`."
  @spec request(pid(), AsyncIteration.step(), pid()) :: AsyncIteration.handle()
  def request(pid, step, reply_to) do
    ref = make_ref()
    send(pid, {@request, step, {reply_to, ref}})
    {:reply, pid, ref}
  end

  @doc """
  Waits for the outcome of a step. Only the process `reply_to` of the
  request can wait for a reply.
  """
  @spec await(AsyncIteration.handle()) :: Promise.outcome()
  def await(%Promise{} = promise), do: Promise.wait(promise)

  def await({:reply, pid, ref}) do
    monitor = Process.monitor(pid)

    # The iterator sends the reply before it stops. Thus the reply comes
    # before the message DOWN.
    receive do
      {@reply, ^ref, outcome} ->
        Process.demonitor(monitor, [:flush])
        outcome

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        {:fulfilled, done()}
    end
  end

  @doc """
  The promise of a step of the iterator process `pid`. The promise is a
  process that gets the reply: see `Web.Internal.PromiseCell`.
  """
  @spec promise(pid(), AsyncIteration.step()) :: Promise.t()
  def promise(pid, step) do
    owner = Promise.owner()
    ref = make_ref()
    cell = spawn(fn -> cell(owner, pid, ref) end)

    # The process that calls this function sends the step. Thus the
    # iterator gets the steps of one process in their sequence.
    send(pid, {@request, step, {cell, ref}})
    PromiseCell.promise(cell)
  end

  defp cell(owner, pid, ref) do
    _promise = PromiseCell.start(owner)
    cell_wait(Process.monitor(pid), ref)
  end

  defp cell_wait(monitor, ref) do
    receive do
      {@reply, ^ref, outcome} ->
        Process.demonitor(monitor, [:flush])
        PromiseCell.settle(outcome)
        PromiseCell.linger()

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        PromiseCell.settle({:fulfilled, done()})
        PromiseCell.linger()

      message ->
        case PromiseCell.handle(message) do
          {:owner_down, _reason} -> exit(:normal)
          _handled_or_unknown -> cell_wait(monitor, ref)
        end
    end
  end

  @doc """
  AsyncIteratorClose: calls `return()` of the iterator, and waits for it.
  `completion` is `{:normal, value}` or `{:throw, reason}`. A throw
  completion stays, also when `return()` rejects. Else the rejection of
  `return()` is the result.
  """
  @spec close(AsyncIteration.t(), {:normal, term()} | {:throw, term()}) ::
          {:normal, term()} | {:throw, term()}
  def close(iterator, completion) do
    outcome = iterator |> AsyncIteration.request({:return, nil}, self()) |> await()

    case {completion, outcome} do
      {{:throw, _reason}, _outcome} -> completion
      {_normal, {:rejected, reason}} -> {:throw, reason}
      {_normal, {:fulfilled, _result}} -> completion
    end
  end

  @doc """
  The callback of a helper, as IsCallable. A function of ECMAScript
  ignores the arguments that it does not declare. A function of Elixir has
  a fixed arity: a callback of arity 0 to `max` gets the first arguments.
  Returns a function of the list of all arguments. Raises `Web.TypeError`
  for each other value.
  """
  @spec callback!(term(), non_neg_integer(), String.t()) :: (list() -> term())
  def callback!(fun, max, method) when is_function(fun) do
    {:arity, arity} = Function.info(fun, :arity)

    if arity <= max do
      fn arguments -> apply(fun, Enum.take(arguments, arity)) end
    else
      raise_not_callable(fun, max, method)
    end
  end

  def callback!(value, max, method), do: raise_not_callable(value, max, method)

  defp raise_not_callable(value, max, method) do
    raise Web.TypeError,
          "The callback of #{method} must be a function of arity 0 to #{max}, " <>
            "not #{inspect(value)}."
  end

  @doc """
  Calls a callback, and then AwaitNonPrimitive: a `Web.Promise` is awaited.
  Returns `{:ok, value}`, or `{:error, reason}` for a raise, a throw, an
  exit, or a promise that rejects.
  """
  @spec call(function(), list()) :: {:ok, term()} | {:error, term()}
  def call(invoker, arguments) do
    case invoker.(arguments) do
      %Promise{} = promise ->
        case Promise.wait(promise) do
          {:fulfilled, value} -> {:ok, value}
          {:rejected, reason} -> {:error, reason}
        end

      value ->
        {:ok, value}
    end
  catch
    kind, reason -> {:error, Exception.normalize(kind, reason, __STACKTRACE__)}
  end

  @doc "ToBoolean, with the values of Elixir: only `nil` and `false` are false."
  @spec truthy?(term()) :: boolean()
  def truthy?(value), do: value not in [nil, false]
end
