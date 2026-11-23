defmodule Web.Internal.PromiseCellTest do
  # A test changes the linger time of the application.
  use ExUnit.Case, async: false

  alias Web.Internal.PromiseCell

  # A process that is a promise, as the process of a `fetch` request. It
  # settles the promise at the message `{:settle, outcome}`, and it answers
  # the messages of the promise.
  defp start_cell do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:promise, PromiseCell.start(test)})
        loop()
      end)

    assert_receive {:promise, %Web.Promise{pid: ^pid} = promise}
    promise
  end

  defp loop do
    receive do
      {:settle, outcome} ->
        PromiseCell.settle(outcome)
        loop()

      :linger ->
        PromiseCell.linger()

      message ->
        PromiseCell.handle(message)
        loop()
    end
  end

  test "an inspect gives the state of the promise" do
    promise = start_cell()
    assert inspect(promise) == "#Web.Promise<pending>"

    send(promise.pid, {:settle, {:fulfilled, :value}})
    assert inspect(promise) == "#Web.Promise<resolved: :value>"
  end

  test "a second outcome has no effect" do
    promise = start_cell()
    send(promise.pid, {:settle, {:fulfilled, :first}})
    send(promise.pid, {:settle, {:rejected, :second}})

    assert Web.await(promise) == :first
    assert Web.await(promise) == :first
  end

  test "keeps the outcome with no limit for the linger time :infinity" do
    previous = Application.get_env(:web, :linger)
    Application.put_env(:web, :linger, :infinity)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:web, :linger, previous),
        else: Application.delete_env(:web, :linger)
    end)

    promise = start_cell()
    send(promise.pid, {:settle, {:fulfilled, :kept}})
    assert Web.await(promise) == :kept

    send(promise.pid, :linger)

    # The process must stay while time goes by. This negative check has no
    # other end than a time limit.
    monitor = Process.monitor(promise.pid)
    refute_receive {:DOWN, ^monitor, :process, _pid, _reason}, 20
    assert Process.alive?(promise.pid)
    assert Web.await(promise) == :kept
  end
end
