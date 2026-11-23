defmodule Web.Internal.AsyncFromSyncIterator do
  @moduledoc false

  # The async iterator of an enumerable, for `Web.AsyncIterator.from/1`, and
  # of a `Web.Iterator`, for `Web.Iterator.to_async/1`:
  # CreateAsyncFromSyncIterator of ECMAScript, for an enumerable as a sync
  # iterator.
  #
  # The iterator is a process. It holds the enumerable, and it does each
  # step in the sequence of the steps that it gets:
  #
  #   * `next()` takes the next element of the enumerable. A `Web.Promise`
  #     element is awaited, as AsyncFromSyncIteratorContinuation does. A
  #     promise that rejects closes the enumerable (closeOnRejection).
  #   * `return()` closes the enumerable, for example the `after` function
  #     of `Stream.resource/3`, and gives `done: true`.
  #
  # The process takes the first element only for the first `next()`. It
  # stops after the end, after an error of the enumerable, after
  # `return()`, and when its owner stops. Then each step gives
  # `done: true`: see `Web.Internal.AsyncStep`.
  #
  # The code of the enumerable runs in this process. Thus a resource that
  # the enumerable opens, for example a file, belongs to this process
  # during the whole iteration.
  #
  # A `Web.Iterator` has its own process. `next()` and `return()` call
  # `next()` and `return()` of that iterator, also a `return()` before the
  # first `next()` (%AsyncFromSyncIteratorPrototype%). The process does not
  # close the iterator when its owner stops: the iterator has its own
  # owner.

  alias Web.AsyncContext.Snapshot
  alias Web.Internal.AsyncStep
  alias Web.Promise

  @doc "Starts the async iterator of an enumerable or of a `Web.Iterator`."
  @spec start(Enumerable.t() | Web.Iterator.t()) :: Web.AsyncIterator.t()
  def start(source) do
    owner = Promise.owner()
    snapshot = Snapshot.new()
    pid = spawn(fn -> init(source, owner, snapshot) end)
    %Web.AsyncIterator{pid: pid}
  end

  defp init(source, owner, snapshot) do
    Promise.put_owner(owner)
    Snapshot.restore(snapshot)

    enumerable =
      case source do
        %Web.Iterator{} = iterator -> {:iterator, iterator}
        enumerable -> {:initial, enumerable}
      end

    loop(%{enumerable: enumerable, owner: Process.monitor(owner)})
  end

  defp loop(state) do
    receive do
      {:"$web_async_iterator", :next, target} ->
        state |> next(target) |> continue()

      # %AsyncFromSyncIteratorPrototype%.return: an error of the code for
      # the end rejects the promise.
      {:"$web_async_iterator", {:return, _value}, target} ->
        case halt(state.enumerable) do
          :ok -> AsyncStep.reply(target, {:fulfilled, AsyncStep.done()})
          {:error, reason} -> AsyncStep.reply(target, {:rejected, reason})
        end

      {:DOWN, monitor, :process, _owner, _reason} when monitor == state.owner ->
        owner_down(state.enumerable)

      _other ->
        loop(state)
    end
  end

  defp continue(%{enumerable: :done}), do: :ok
  defp continue(state), do: loop(state)

  defp next(state, target) do
    case step(state.enumerable) do
      {:value, %Promise{} = promise, enumerable} ->
        case Promise.wait(promise) do
          {:fulfilled, value} ->
            AsyncStep.reply(target, {:fulfilled, %{value: value, done: false}})
            %{state | enumerable: enumerable}

          {:rejected, reason} ->
            halt(enumerable)
            AsyncStep.reply(target, {:rejected, reason})
            %{state | enumerable: :done}
        end

      {:value, value, enumerable} ->
        AsyncStep.reply(target, {:fulfilled, %{value: value, done: false}})
        %{state | enumerable: enumerable}

      :done ->
        AsyncStep.reply(target, {:fulfilled, AsyncStep.done()})
        %{state | enumerable: :done}

      # The enumerable failed. As a generator that throws, it is complete.
      {:error, reason} ->
        AsyncStep.reply(target, {:rejected, reason})
        %{state | enumerable: :done}
    end
  end

  # IteratorNext of a `Web.Iterator`: its result, or its error.
  defp step({:iterator, iterator} = source) do
    case Web.Iterator.next(iterator) do
      %{done: true} -> :done
      %{value: value} -> {:value, value, source}
    end
  catch
    kind, reason -> {:error, Exception.normalize(kind, reason, __STACKTRACE__)}
  end

  # The accumulator of the reduction holds the element. The value `:none`
  # shows that the enumerable gave no element.
  defp step(enumerable) do
    case reduce(enumerable) do
      {:suspended, {:value, value}, continuation} ->
        {:value, value, {:continuation, continuation}}

      # An enumerable that halts itself, such as `Stream.take/2`, gives its
      # last element together with the halt.
      {:halted, {:value, value}} ->
        {:value, value, :done}

      {_done_or_halted, :none} ->
        :done
    end
  catch
    kind, reason -> {:error, Exception.normalize(kind, reason, __STACKTRACE__)}
  end

  defp reduce({:initial, enumerable}) do
    Enumerable.reduce(enumerable, {:cont, :none}, fn value, _acc ->
      {:suspend, {:value, value}}
    end)
  end

  defp reduce({:continuation, continuation}), do: continuation.({:cont, :none})

  # Runs the code that the enumerable has for its end. Only `return()`
  # uses the error of that code: after a rejection, the first error stays,
  # and after the stop of the owner, no process waits.
  defp halt({:continuation, continuation}) do
    _ = continuation.({:halt, :none})
    :ok
  catch
    kind, reason -> {:error, Exception.normalize(kind, reason, __STACKTRACE__)}
  end

  defp halt({:iterator, iterator}) do
    _result = Web.Iterator.return(iterator)
    :ok
  catch
    kind, reason -> {:error, Exception.normalize(kind, reason, __STACKTRACE__)}
  end

  defp halt(_initial_or_done), do: :ok

  defp owner_down({:iterator, _iterator}), do: :ok
  defp owner_down(enumerable), do: halt(enumerable)
end
