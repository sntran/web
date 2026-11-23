defmodule Web.Test.ScriptedIterator do
  @moduledoc false

  # An async iterator that a test controls. The process that calls `new/0`
  # is the iterator process: it gets each step of the iterator as a
  # message (see `Web.Internal.AsyncStep`), and it gives each outcome when
  # it wants. Thus the test sees each read and each close of a helper, and
  # it puts their outcomes in each sequence that it needs.
  #
  #     source = ScriptedIterator.new()
  #     helper = Web.AsyncIterator.map(source, &(&1 * 2))
  #     promise = Web.AsyncIterator.next(helper)
  #     target = ScriptedIterator.assert_next()
  #     ScriptedIterator.give(target, 21)

  import ExUnit.Assertions

  alias Web.Internal.AsyncStep

  @doc "An iterator that the calling process serves."
  def new, do: %Web.AsyncIterator{pid: self()}

  @doc """
  An iterator that the calling process serves, with the name `tag`: a
  process gives each step to the caller as `{:scripted, tag, step,
  target}`. Thus a test serves many iterators, and knows the iterator of
  each step. Stop the process with `stop/1`.
  """
  def new(tag) do
    test = self()
    %Web.AsyncIterator{pid: spawn(fn -> forward(test, tag) end)}
  end

  defp forward(test, tag) do
    receive do
      {:"$web_async_iterator", step, target} ->
        send(test, {:scripted, tag, step, target})
        forward(test, tag)
    end
  end

  @doc "Stops the process of an iterator of `new/1`."
  def stop(%Web.AsyncIterator{pid: pid}) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
    :ok
  end

  @doc "Waits for a read of the iterator `tag` of `new/1`."
  def assert_read(tag, timeout \\ 1_000) do
    assert_receive {:scripted, ^tag, :next, target}, timeout
    target
  end

  @doc "Waits for a close of the iterator `tag` of `new/1`."
  def assert_close(tag, timeout \\ 1_000) do
    assert_receive {:scripted, ^tag, {:return, _value}, target}, timeout
    target
  end

  @doc "Waits for a read of the iterator. Returns the target of the reply."
  def assert_next(timeout \\ 1_000) do
    assert_receive {:"$web_async_iterator", :next, target}, timeout
    target
  end

  @doc "Waits for a close of the iterator. Returns the target of the reply."
  def assert_return(timeout \\ 1_000) do
    assert_receive {:"$web_async_iterator", {:return, _value}, target}, timeout
    target
  end

  @doc "Tells that no step came. Call `settle/1` first."
  def refute_step do
    refute_received {:"$web_async_iterator", _step, _target}
  end

  @doc "Tells that no close came. Call `settle/1` first."
  def refute_return do
    refute_received {:"$web_async_iterator", {:return, _value}, _target}
  end

  @doc "Gives a value to a read."
  def give(target, value), do: AsyncStep.reply(target, {:fulfilled, %{value: value, done: false}})

  @doc "Gives the end to a read, or the result of a close."
  def finish(target), do: AsyncStep.reply(target, {:fulfilled, AsyncStep.done()})

  @doc "Rejects a step."
  def fail(target, reason), do: AsyncStep.reply(target, {:rejected, reason})

  @doc """
  Waits until each process of `pids`, and each process that is linked to
  one of them (the jobs of a helper), is at rest: it waits for a message,
  its mailbox is empty, and it did no work between two examinations. Then
  the function finds the linked processes again: a process that started
  during the examinations is not at rest. (A read of the links of a process
  is work of that process: thus it comes after the two examinations.)
  """
  def settle(pids, attempts \\ 2_000) do
    all = linked(pids)
    before = Enum.map(all, &info(&1, pids))
    rest? = Enum.all?(before, &at_rest?/1) and Enum.map(all, &info(&1, pids)) == before

    cond do
      rest? and linked(pids) == all ->
        :ok

      attempts == 0 ->
        flunk("the processes are not at rest: #{inspect(Enum.zip(all, before))}")

      true ->
        Process.sleep(1)
        settle(pids, attempts - 1)
    end
  end

  defp linked(pids), do: pids |> Enum.flat_map(&with_links/1) |> Enum.uniq() |> Enum.sort()

  defp with_links(pid) do
    case Process.info(pid, :links) do
      {:links, links} -> [pid | Enum.filter(links, &is_pid/1)] -- [self()]
      nil -> [pid]
    end
  end

  # A linked process that stopped, and that is still a link, has an exit
  # signal that its peer did not take: it is not at rest.
  defp info(pid, pids) do
    case Process.info(pid, [:status, :message_queue_len, :reductions]) do
      nil -> if pid in pids, do: nil, else: :exit_in_transit
      info -> info
    end
  end

  defp at_rest?(nil), do: true
  defp at_rest?(:exit_in_transit), do: false

  defp at_rest?(info) do
    info[:status] == :waiting and info[:message_queue_len] == 0
  end
end
