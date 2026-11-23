defprotocol Web.Internal.AsyncIteration do
  @moduledoc false

  # The async iterators of this library: a `Web.AsyncIterator` and a
  # `Web.ReadableStreamAsyncIterator`. The protocol is the record of an
  # async iterator of ECMAScript, with the methods `next` and `return`. The
  # helpers of `Web.AsyncIterator` read each async iterator through it.
  #
  # A step is `:next`, or `{:return, value}`. Its outcome is the outcome of
  # a promise: `{:fulfilled, %{value: value, done: done}}` or
  # `{:rejected, reason}`.
  #
  #   * `promise/2` gives the promise of a step, for the public functions.
  #   * `request/3` starts a step for the process `reply_to`. That process
  #     gets the outcome with `Web.Internal.AsyncStep.await/1`. A step of an
  #     iterator process needs no promise process: the iterator sends the
  #     outcome to `reply_to` in a message. The calls of `request/3` from
  #     one process get their steps in the sequence of the calls.

  @typedoc "A step of an async iterator."
  @type step :: :next | {:return, term()}

  @typedoc "A step that runs: a promise, or a reply that an iterator process sends."
  @type handle :: Web.Promise.t() | {:reply, pid(), reference()}

  @doc "The promise of a step."
  @spec promise(t(), step()) :: Web.Promise.t()
  def promise(iterator, step)

  @doc "Starts a step. The process `reply_to` awaits the handle."
  @spec request(t(), step(), pid()) :: handle()
  def request(iterator, step, reply_to)
end

defimpl Web.Internal.AsyncIteration, for: Web.ReadableStreamAsyncIterator do
  alias Web.ReadableStreamAsyncIterator

  def promise(iterator, :next), do: ReadableStreamAsyncIterator.next(iterator)

  def promise(iterator, {:return, value}),
    do: ReadableStreamAsyncIterator.return(iterator, value)

  # The read is a request of the process that calls this function. Thus the
  # stream gets the reads of that process in their sequence.
  def request(iterator, step, _reply_to), do: promise(iterator, step)
end

defimpl Web.Internal.AsyncIteration, for: Web.AsyncIterator do
  alias Web.Internal.AsyncIteration
  alias Web.Internal.AsyncStep

  # A wrapper of a different async iterator, as
  # %WrapForValidAsyncIteratorPrototype%: `next()` and `return()` call the
  # methods of that iterator. `return()` gives no argument to the method.
  def promise(%{pid: nil, source: source}, step),
    do: AsyncIteration.promise(source, wrapped(step))

  def promise(%{pid: pid}, step), do: AsyncStep.promise(pid, step)

  def request(%{pid: nil, source: source}, step, reply_to),
    do: AsyncIteration.request(source, wrapped(step), reply_to)

  def request(%{pid: pid}, step, reply_to), do: AsyncStep.request(pid, step, reply_to)

  defp wrapped(:next), do: :next
  defp wrapped({:return, _value}), do: {:return, nil}
end
