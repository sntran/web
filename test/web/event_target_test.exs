defmodule Web.EventTargetTest do
  use ExUnit.Case, async: true

  test "dispatchEvent invokes registered listeners and removes once listeners" do
    parent = self()

    target =
      Web.EventTarget.new(owner: self())
      |> Web.EventTarget.addEventListener("message", fn event ->
        send(parent, {:persistent, event.detail})
      end)
      |> Web.EventTarget.addEventListener(
        "message",
        fn event ->
          send(parent, {:once, event.detail})
        end,
        once: true
      )

    event = Web.CustomEvent.new("message", detail: %{value: 1})

    {target, true} = Web.EventTarget.dispatchEvent(target, event)

    assert_receive {:persistent, %{value: 1}}
    assert_receive {:once, %{value: 1}}

    {target, true} = Web.EventTarget.dispatchEvent(target, event)

    assert_receive {:persistent, %{value: 1}}
    refute_receive {:once, _}

    assert map_size(target.listeners) == 1
  end

  test "removeEventListener removes matching callbacks" do
    callback = fn -> :ok end

    target =
      Web.EventTarget.new(owner: self())
      |> Web.EventTarget.addEventListener("close", callback)
      |> Web.EventTarget.removeEventListener("close", callback)

    assert target.listeners == %{}
  end

  test "remove_event_listener keeps non-matching listeners for the same type" do
    keep = &Kernel.is_nil/1
    drop = fn _event -> :ok end

    target =
      Web.EventTarget.new(owner: self())
      |> Web.EventTarget.addEventListener("shared", keep)
      |> Web.EventTarget.addEventListener("shared", drop)

    target = Web.EventTarget.removeEventListener(target, "shared", drop)

    assert [%{callback: ^keep}] = target.listeners["shared"]
  end

  test "alias methods, duplicate suppression, atom types, and zero-arity callbacks work" do
    parent = self()
    callback = fn -> send(parent, :ping) end

    target =
      Web.EventTarget.new(owner: self())
      |> Web.EventTarget.addEventListener(:tick, callback, %{once: false})
      |> Web.EventTarget.addEventListener(:tick, callback)

    assert [%{watcher: nil}] = target.listeners["tick"]

    {target, true} = Web.EventTarget.dispatchEvent(target, Web.CustomEvent.new(:tick))
    assert_receive :ping

    target = Web.EventTarget.removeEventListener(target, :tick, callback)
    assert target.listeners == %{}
  end

  test "camelCase aliases dispatch and remove listeners" do
    parent = self()
    callback = fn event -> send(parent, {:camel, event.type}) end
    beta_callback = fn -> send(parent, :beta) end

    target =
      Web.EventTarget.new(owner: self())
      |> Web.EventTarget.addEventListener("alpha", callback)
      |> Web.EventTarget.addEventListener("beta", beta_callback)

    target =
      Web.EventTarget.addEventListener(
        target,
        "ignored",
        fn -> :ok end,
        signal: Web.AbortSignal.abort(:done)
      )

    {target, true} =
      Web.EventTarget.dispatchEvent(target, Web.CustomEvent.new("beta"))

    assert_receive :beta

    target =
      target
      |> Web.EventTarget.removeEventListener("beta", beta_callback)

    {_target, true} = Web.EventTarget.dispatchEvent(target, Web.CustomEvent.new("alpha"))
    assert_receive {:camel, "alpha"}

    callback2 = fn event -> send(parent, {:camel2, event.type}) end

    target =
      Web.EventTarget.new(owner: self())
      |> Web.EventTarget.addEventListener("gamma", callback2)

    {target, true} = Web.EventTarget.dispatchEvent(target, Web.CustomEvent.new("none"))
    refute_receive {:camel2, _}

    target = Web.EventTarget.removeEventListener(target, "gamma", callback2)
    assert target.listeners == %{}
  end

  test "camelCase entry points register and compare callbacks across callback shapes" do
    parent = self()
    callback = &Kernel.is_nil/1
    zero_arity = fn -> send(parent, :zero) end

    target =
      Web.EventTarget.new(owner: self())
      |> Web.EventTarget.addEventListener("shape", callback)
      |> Web.EventTarget.addEventListener("shape", zero_arity)

    {target, true} = Web.EventTarget.dispatchEvent(target, Web.CustomEvent.new("shape"))
    assert_receive :zero

    target = Web.EventTarget.removeEventListener(target, "shape", zero_arity)
    assert [%{callback: ^callback}] = target.listeners["shape"]
  end

  test "pre-aborted signals and nil owners do not register active watchers" do
    callback = fn _event -> :ok end

    skipped =
      Web.EventTarget.new(owner: self())
      |> Web.EventTarget.addEventListener("aborted", callback,
        signal: Web.AbortSignal.abort(:done)
      )

    assert skipped.listeners == %{}

    target =
      Web.EventTarget.new(owner: nil)
      |> Web.EventTarget.addEventListener("plain", callback, signal: self())

    assert [%{watcher: nil}] = target.listeners["plain"]
  end

  test "watchers poll while signals stay alive and stop when removed" do
    callback = fn _event -> :ok end

    target =
      Web.EventTarget.new(owner: self())
      |> Web.EventTarget.addEventListener("loop", callback, signal: self())

    assert [%{watcher: watcher}] = target.listeners["loop"]
    assert is_pid(watcher)

    Process.sleep(60)
    assert Process.alive?(watcher)

    target = Web.EventTarget.removeEventListener(target, "loop", callback)
    assert target.listeners == %{}
  end

  test "handle_info returns unknown for unrelated messages" do
    assert :unknown = Web.EventTarget.handle_info(Web.EventTarget.new(owner: self()), :other)
  end

  test "watcher cleanup handles dead signal pids and dead watcher pids" do
    dead_signal =
      spawn(fn ->
        :ok
      end)

    Process.sleep(10)

    target =
      Web.EventTarget.new(owner: self())
      |> Web.EventTarget.addEventListener("dead", fn _event -> :ok end, signal: dead_signal)

    assert target = await_abort_cleanup(target)
    assert target.listeners == %{}

    dead_watcher =
      spawn(fn ->
        :ok
      end)

    Process.sleep(10)

    callback = fn _event -> :ok end

    target = %Web.EventTarget{
      owner: self(),
      listeners: %{"manual" => [%{id: 1, callback: callback, once: false, watcher: dead_watcher}]},
      next_id: 2
    }

    target = Web.EventTarget.removeEventListener(target, "manual", callback)
    assert target.listeners == %{}
  end

  test "watchers exit cleanly when the owner process goes down" do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    controller = Web.AbortController.new()

    target =
      Web.EventTarget.new(owner: owner)
      |> Web.EventTarget.addEventListener("owned", fn _event -> :ok end,
        signal: controller.signal
      )

    assert [%{watcher: watcher}] = target.listeners["owned"]
    send(owner, :stop)
    Process.sleep(60)

    refute Process.alive?(watcher)
  end

  test "abort signal options remove listeners through handle_info" do
    parent = self()
    controller = Web.AbortController.new()

    target =
      Web.EventTarget.new(owner: self())
      |> Web.EventTarget.addEventListener(
        "abortable",
        fn event ->
          send(parent, {:event, event.type})
        end,
        signal: controller.signal
      )

    Web.AbortController.abort(controller, :stop)

    target = await_abort_cleanup(target)
    assert target.listeners == %{}
  end

  test "pid-backed signal watchers ignore unrelated messages and clean up on abort" do
    callback = fn _event -> :ok end

    target =
      Web.EventTarget.new(owner: self())
      |> Web.EventTarget.addEventListener("pid-signal", callback, signal: self())

    assert [%{watcher: watcher}] = target.listeners["pid-signal"]

    send(watcher, :noise)
    send(watcher, {:abort, self(), :pid_stop})

    target = await_abort_cleanup(target)
    assert target.listeners == %{}
  end

  test "token-backed signal watchers handle both abort message shapes" do
    callback = fn _event -> :ok end

    target =
      Web.EventTarget.new(owner: self())
      |> Web.EventTarget.addEventListener("token-signal", callback, signal: :token_signal)

    assert [%{watcher: watcher}] = target.listeners["token-signal"]
    send(watcher, :noise)
    send(watcher, {:abort, :token_signal})
    target = await_abort_cleanup(target)
    assert target.listeners == %{}

    target =
      Web.EventTarget.new(owner: self())
      |> Web.EventTarget.addEventListener("token-signal-2", callback, signal: :token_signal_2)

    assert [%{watcher: watcher2}] = target.listeners["token-signal-2"]
    send(watcher2, {:abort, :token_signal_2, :token_stop})
    target = await_abort_cleanup(target)
    assert target.listeners == %{}
  end

  test "abort-signal watchers ignore unrelated messages before reacting to abort" do
    controller = Web.AbortController.new()

    target =
      Web.EventTarget.new(owner: self())
      |> Web.EventTarget.addEventListener("signal", fn _event -> :ok end,
        signal: controller.signal
      )

    assert [%{watcher: watcher}] = target.listeners["signal"]
    send(watcher, :noise)

    assert target.listeners["signal"] != nil

    Web.AbortController.abort(controller, :stop)

    target = await_abort_cleanup(target)
    assert target.listeners == %{}
  end

  test "abort-signal watcher removes the listener when the signal process dies abruptly" do
    controller = Web.AbortController.new()

    target =
      Web.EventTarget.new(owner: self())
      |> Web.EventTarget.addEventListener("signal-down", fn _event -> :ok end,
        signal: controller.signal
      )

    Process.sleep(60)
    Process.exit(controller.signal.pid, :kill)

    target = await_abort_cleanup(target)
    assert target.listeners == %{}
  end

  test "pid-backed signal watcher removes the listener when the signal process exits" do
    signal =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    target =
      Web.EventTarget.new(owner: self())
      |> Web.EventTarget.addEventListener("pid-down", fn _event -> :ok end, signal: signal)

    Process.sleep(60)
    send(signal, :stop)

    target = await_abort_cleanup(target)
    assert target.listeners == %{}
  end

  test "token-backed watchers exit when their owner process goes down" do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    target =
      Web.EventTarget.new(owner: owner)
      |> Web.EventTarget.addEventListener("token-owned", fn _event -> :ok end,
        signal: :owner_bound_token
      )

    assert [%{watcher: watcher}] = target.listeners["token-owned"]
    send(owner, :stop)
    Process.sleep(60)

    refute Process.alive?(watcher)
  end

  defp await_abort_cleanup(target) do
    receive do
      message ->
        case Web.EventTarget.handle_info(target, message) do
          {:ok, updated_target} -> updated_target
          :unknown -> await_abort_cleanup(target)
        end
    after
      1_000 -> flunk("expected abort cleanup message")
    end
  end
end
