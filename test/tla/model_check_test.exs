defmodule Web.TLA.ModelCheckTest do
  # The model check of the TLA+ specifications in `tla/`. The checker is
  # `Accord.TLA.Checker`, in Elixir.
  #
  # Each specification has the constant `Bug`. The value "none" is the
  # design. Each other value removes one rule of the design, and a test makes
  # sure that a property finds it. Thus a property that cannot fail is found.
  use ExUnit.Case, async: true

  alias Web.Test.SpecModel

  defp bug(name), do: {~s(Bug = "none"), ~s(Bug = "#{name}")}

  defp assert_holds(result) do
    assert {:ok, %{distinct_states: states, warnings: []}} = result
    assert states > 1
  end

  defp assert_violates(result, property) do
    assert {:error, %{property: ^property, trace: [_ | _]}, _stats} = result
  end

  describe "Promise" do
    test "the design has all its properties" do
      assert_holds(SpecModel.check("Promise"))
    end

    test "a promise that can settle two times is found" do
      assert_violates(SpecModel.check("Promise", bug("settle_two_times")), "SettleOnce")
    end

    test "a client that waits for a promise that stopped is found" do
      assert_violates(
        SpecModel.check("Promise", bug("owner_stop_keeps_waiters")),
        "NoLostWaiter"
      )
    end

    test "an outcome that is released before a client gets it is found" do
      assert_violates(SpecModel.check("Promise", bug("expire_before_delivery")), "KeptForOwner")
    end
  end

  describe "StreamLifetime" do
    test "the design has all its properties" do
      assert_holds(SpecModel.check("StreamLifetime"))
    end

    test "the design with the option :unread_timeout has all its properties" do
      assert_holds(
        SpecModel.check("StreamLifetime", {"UnreadLimit = FALSE", "UnreadLimit = TRUE"})
      )
    end

    test "an errored stream that stays because of its chunks is found" do
      assert_violates(
        SpecModel.check("StreamLifetime", bug("errored_keeps_chunks")),
        "CompleteStops"
      )
    end

    test "a stream that continues after all its processes is found" do
      result = SpecModel.check("StreamLifetime", bug("no_owner_rule"), deadlock: false)
      assert_violates(result, "NoOrphan")
    end

    test "a stream that discards chunks while a process holds the lock is found" do
      assert_violates(
        SpecModel.check("StreamLifetime", bug("owner_rule_ignores_lock")),
        "LockStopsOwnerRule"
      )
    end
  end

  describe "AbortSignal" do
    test "the design has all its properties" do
      assert_holds(SpecModel.check("AbortSignal"))
    end

    test "an abort that does not go to the subscribers is found" do
      assert_violates(
        SpecModel.check("AbortSignal", bug("abort_skips_subscribers")),
        "AbortReachesSubscribers"
      )
    end

    test "a signal that stops while a process is subscribed is found" do
      assert_violates(
        SpecModel.check("AbortSignal", bug("stop_with_subscribers")),
        "NoFalseAbort"
      )
    end

    test "an unsubscribe that keeps the subscription is found" do
      assert_violates(
        SpecModel.check("AbortSignal", bug("unsubscribe_keeps_entry")),
        "SubscriptionsMatch"
      )
    end
  end

  describe "ResponseBody" do
    test "the design has all its properties" do
      assert_holds(SpecModel.check("ResponseBody"))
    end

    test "a body that is not complete, but looks complete, is found" do
      assert_violates(
        SpecModel.check("ResponseBody", bug("exit_on_worker_stop")),
        "FullBodyOrError"
      )
    end
  end
end
