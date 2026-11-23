defmodule Web.Internal.SyncIterator do
  @moduledoc false

  # The process of a `Web.Iterator`: the iterator of an enumerable
  # (`Iterator.from`), or an iterator helper of ECMAScript 2025 (`map`,
  # `filter`, `take`, `drop`, and `flatMap`).
  #
  # An iterator of ECMAScript keeps its state: each call of `next()` gives
  # the next value. A value of Elixir does not change. Thus the state is in
  # a process, and `next/1` and `return/1` are calls of that process. The
  # process does one step at a time, in the sequence of the calls, and it
  # answers each call. The steps of a helper run in this process: the reads
  # of its source, and its callback. The code of an enumerable also runs in
  # this process: thus a resource that the enumerable opens belongs to this
  # process during the whole iteration.
  #
  # The process belongs to the process that made it, as a
  # `Web.ReadableStream`. It stops when that process stops, and then the
  # iterator of an enumerable halts the enumerable. It also stops at its
  # end: after `done: true`, after an error, and after `return()`, as a
  # generator that is completed. A call of a process that stopped gives
  # `done: true`, as GeneratorResume and GeneratorResumeAbrupt of a
  # completed generator.
  #
  # A call gives the process its chain: the iterator processes that run a
  # step and wait for this call. A process puts itself at the head of the
  # chain during its step. A call of an iterator that is in the chain of the
  # caller is a call of an iterator that runs: it raises `Web.TypeError`, as
  # GeneratorValidate ("executing"), and it does not wait for itself. A
  # call from a different process waits until the step ends.

  alias Web.AsyncContext.Snapshot
  alias Web.Internal.AsyncStep
  alias Web.Promise

  @request :"$web_iterator"
  @reply :"$web_iterator_reply"
  @chain :"$web_iterator_chain"

  @typedoc false
  @type work ::
          {:cursor, cursor()}
          | {:map | :filter, Web.Iterator.t(), function()}
          | {:take | :drop, Web.Iterator.t(), non_neg_integer() | :infinity}
          | {:flat_map, Web.Iterator.t(), function(), cursor() | nil}

  @typedoc false
  # The state of an iterator in a process: a `Web.Iterator`, or an
  # enumerable that this process reads.
  @type cursor ::
          {:iterator, Web.Iterator.t()}
          | {:enumerable, {:initial, Enumerable.t()} | {:continuation, function()} | :done}

  @doc "Starts the process of an iterator."
  @spec start(work()) :: Web.Iterator.t()
  def start(work) do
    owner = Promise.owner()
    snapshot = Snapshot.new()
    pid = spawn(fn -> init(work, owner, snapshot) end)
    %Web.Iterator{pid: pid}
  end

  # ---------------------------------------------------------------------------
  # The calls
  # ---------------------------------------------------------------------------

  @doc """
  A call of the iterator: `:next` or `:return`. Returns the iterator result,
  or raises the error of the step with its kind (a raise, a throw, or an
  exit).
  """
  @spec call(Web.Iterator.t(), :next | :return) :: %{value: term(), done: boolean()}
  def call(%Web.Iterator{pid: pid}, step) do
    chain = Process.get(@chain, [])

    if pid in chain do
      raise Web.TypeError, "The iterator runs: a step of the iterator called it again."
    end

    ref = Process.monitor(pid)
    send(pid, {@request, step, {self(), ref}, chain})

    # The process sends the reply before it stops. Thus the reply comes
    # before the message DOWN.
    receive do
      {@reply, ^ref, reply} ->
        Process.demonitor(ref, [:flush])
        result(reply)

      {:DOWN, ^ref, :process, _pid, _reason} ->
        AsyncStep.done()
    end
  end

  defp result({:ok, result}), do: result
  defp result({:raise, kind, reason, stacktrace}), do: :erlang.raise(kind, reason, stacktrace)

  @doc """
  IteratorClose with a throw completion: calls `return()`, and ignores its
  error. The caller raises its own error after it.
  """
  @spec close_quietly(Web.Iterator.t()) :: :ok
  def close_quietly(iterator) do
    _result = call(iterator, :return)
    :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  Calls a callback. A raise, a throw, or an exit of the callback closes
  `iterator` (IfAbruptCloseIterator), and then goes to the caller.
  """
  @spec call_closing((list() -> term()), list(), Web.Iterator.t()) :: term()
  def call_closing(callback, arguments, iterator) do
    callback.(arguments)
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      close_quietly(iterator)
      :erlang.raise(kind, reason, stacktrace)
  end

  @doc """
  GetIteratorFlattenable: the cursor of a `Web.Iterator`, or of an
  enumerable. A string is an iterable only with `:iterate_strings`.
  Returns `{:error, %Web.TypeError{}}` for each other value.
  """
  @spec cursor(term(), :iterate_strings | :reject_strings) ::
          {:ok, cursor()} | {:error, Exception.t()}
  def cursor(%Web.Iterator{} = iterator, _strings), do: {:ok, {:iterator, iterator}}

  def cursor(string, :iterate_strings) when is_binary(string),
    do: {:ok, {:enumerable, {:initial, String.codepoints(string)}}}

  def cursor(value, _strings) do
    if is_binary(value) or is_nil(Enumerable.impl_for(value)) do
      {:error,
       %Web.TypeError{message: "The value is not an iterator or an iterable: #{inspect(value)}"}}
    else
      {:ok, {:enumerable, {:initial, value}}}
    end
  end

  # ---------------------------------------------------------------------------
  # The process
  # ---------------------------------------------------------------------------

  defp init(work, owner, snapshot) do
    Promise.put_owner(owner)
    Snapshot.restore(snapshot)
    loop(%{work: work, counter: 0, owner: Process.monitor(owner)})
  end

  defp loop(state) do
    receive do
      {@request, step, {from, ref}, chain} ->
        Process.put(@chain, [self() | chain])
        {reply, next} = run(step, state)
        Process.delete(@chain)
        send(from, {@reply, ref, reply})
        if next == :completed, do: :ok, else: loop(next)

      {:DOWN, monitor, :process, _owner, _reason} when monitor == state.owner ->
        stop(state.work)

      _other ->
        loop(state)
    end
  end

  # The iterator of an enumerable halts the enumerable when its owner
  # stops, and `flatMap` halts an inner enumerable that it reads. A helper
  # does not close its source: the source has its own owner.
  defp stop({:cursor, {:enumerable, _state} = cursor}), do: close_enumerable(cursor)

  defp stop({:flat_map, _source, _mapper, {:enumerable, _state} = inner}),
    do: close_enumerable(inner)

  defp stop(_work), do: :ok

  defp close_enumerable(cursor) do
    close(cursor)
  catch
    _kind, _reason -> :ok
  end

  # A step that raises completes the iterator, and its error goes to the
  # caller.
  defp run(step, state) do
    step(step, state)
  catch
    kind, reason -> {{:raise, kind, reason, __STACKTRACE__}, :completed}
  end

  defp done, do: {{:ok, AsyncStep.done()}, :completed}

  defp yield(value, state), do: {{:ok, %{value: value, done: false}}, state}

  # ---------------------------------------------------------------------------
  # The steps
  # ---------------------------------------------------------------------------

  # The iterator of an enumerable.
  defp step(:next, %{work: {:cursor, cursor}} = state) do
    case advance(cursor) do
      {:value, value, cursor} -> yield(value, %{state | work: {:cursor, cursor}})
      :done -> done()
    end
  end

  # %IteratorHelperPrototype%.return: a helper that has not started, and a
  # helper at a Yield, close their source with IteratorClose. `flatMap`
  # closes its inner iterator first. An error of a close goes to the
  # caller.
  defp step(:return, %{work: {:flat_map, source, _mapper, inner}}) when not is_nil(inner) do
    try do
      close(inner)
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        close_quietly(source)
        :erlang.raise(kind, reason, stacktrace)
    end

    close({:iterator, source})
    done()
  end

  defp step(:return, %{work: {:cursor, cursor}}) do
    close(cursor)
    done()
  end

  defp step(:return, %{work: work}) do
    close({:iterator, elem(work, 1)})
    done()
  end

  # Iterator.prototype.map: "Let mapped be Completion(Call(mapper, undefined,
  # « value, 𝔽(counter) »)). IfAbruptCloseIterator(mapped, iterated)."
  defp step(:next, %{work: {:map, source, mapper}, counter: counter} = state) do
    case value(source) do
      {:value, value} ->
        mapped = call_closing(mapper, [value, counter], source)
        yield(mapped, %{state | counter: counter + 1})

      :done ->
        done()
    end
  end

  # Iterator.prototype.filter: the counter counts each value of the source.
  defp step(:next, %{work: {:filter, source, predicate}, counter: counter} = state) do
    case value(source) do
      {:value, value} ->
        selected = call_closing(predicate, [value, counter], source)
        state = %{state | counter: counter + 1}
        if AsyncStep.truthy?(selected), do: yield(value, state), else: step(:next, state)

      :done ->
        done()
    end
  end

  # Iterator.prototype.take: "If remaining = 0, then Return ?
  # IteratorClose(iterated, ReturnCompletion(undefined))."
  defp step(:next, %{work: {:take, source, 0}}) do
    close({:iterator, source})
    done()
  end

  defp step(:next, %{work: {:take, source, remaining}} = state) do
    case value(source) do
      {:value, value} -> yield(value, %{state | work: {:take, source, decrement(remaining)}})
      :done -> done()
    end
  end

  # Iterator.prototype.drop: "Repeat, while remaining > 0", at the first
  # call of next().
  defp step(:next, %{work: {:drop, source, remaining}} = state) when remaining != 0 do
    case value(source) do
      {:value, _value} -> step(:next, %{state | work: {:drop, source, decrement(remaining)}})
      :done -> done()
    end
  end

  defp step(:next, %{work: {:drop, source, 0}} = state) do
    case value(source) do
      {:value, value} -> yield(value, state)
      :done -> done()
    end
  end

  # Iterator.prototype.flatMap: the values of the inner iterator, and then
  # the inner iterator of the next value of the source.
  defp step(:next, %{work: {:flat_map, source, mapper, nil}, counter: counter} = state) do
    case value(source) do
      {:value, value} ->
        mapped = call_closing(mapper, [value, counter], source)

        case cursor(mapped, :reject_strings) do
          {:ok, inner} ->
            step(:next, %{state | work: {:flat_map, source, mapper, inner}})

          {:error, error} ->
            close_quietly(source)
            raise error
        end

      :done ->
        done()
    end
  end

  # "Let innerValue be Completion(IteratorStepValue(innerIterator)).
  # IfAbruptCloseIterator(innerValue, iterated)."
  defp step(:next, %{work: {:flat_map, source, mapper, inner}, counter: counter} = state) do
    case advance_closing(inner, source) do
      {:value, value, inner} ->
        yield(value, %{state | work: {:flat_map, source, mapper, inner}})

      :done ->
        step(:next, %{state | work: {:flat_map, source, mapper, nil}, counter: counter + 1})
    end
  end

  defp decrement(:infinity), do: :infinity
  defp decrement(remaining), do: remaining - 1

  # IteratorStepValue of a `Web.Iterator`.
  defp value(iterator) do
    case call(iterator, :next) do
      %{done: true} -> :done
      %{value: value} -> {:value, value}
    end
  end

  defp advance_closing(inner, source) do
    advance(inner)
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      close_quietly(source)
      :erlang.raise(kind, reason, stacktrace)
  end

  # ---------------------------------------------------------------------------
  # Cursors
  # ---------------------------------------------------------------------------

  # The next value of a cursor. The accumulator of the reduction of an
  # enumerable holds the element: `:none` shows that the enumerable gave no
  # element.
  defp advance({:iterator, iterator}) do
    case value(iterator) do
      {:value, value} -> {:value, value, {:iterator, iterator}}
      :done -> :done
    end
  end

  defp advance({:enumerable, :done}), do: :done

  defp advance({:enumerable, enumerable}) do
    case reduce(enumerable) do
      {:suspended, {:value, value}, continuation} ->
        {:value, value, {:enumerable, {:continuation, continuation}}}

      # An enumerable that halts itself, such as `Stream.take/2`, gives its
      # last element together with the halt.
      {:halted, {:value, value}} ->
        {:value, value, {:enumerable, :done}}

      {_done_or_halted, :none} ->
        :done
    end
  end

  defp reduce({:initial, enumerable}) do
    Enumerable.reduce(enumerable, {:cont, :none}, fn value, _acc ->
      {:suspend, {:value, value}}
    end)
  end

  defp reduce({:continuation, continuation}), do: continuation.({:cont, :none})

  # IteratorClose with a normal completion: an error of `return()` goes to
  # the caller. An enumerable runs the code that it has for its end, for
  # example the `after` function of `Stream.resource/3`.
  defp close({:iterator, iterator}) do
    _result = call(iterator, :return)
    :ok
  end

  defp close({:enumerable, {:continuation, continuation}}) do
    _ = continuation.({:halt, :none})
    :ok
  end

  defp close({:enumerable, _initial_or_done}), do: :ok
end
