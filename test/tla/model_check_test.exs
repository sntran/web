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

  describe "MessagePort" do
    test "the design has all its properties" do
      assert_holds(SpecModel.check("MessagePort"))
    end

    test "the design has all its properties with more messages and more transfers" do
      larger = [{"MaxMessages = 2", "MaxMessages = 3"}, {"MaxTransfers = 1", "MaxTransfers = 2"}]
      assert_holds(SpecModel.check("MessagePort", larger))
    end

    test "a message that is lost in a transfer is found" do
      assert_violates(
        SpecModel.check("MessagePort", bug("returned_item_is_lost")),
        "NothingLost"
      )
    end

    test "a transfer that changes the sequence of the messages is found" do
      assert_violates(
        SpecModel.check("MessagePort", bug("returned_item_to_tail")),
        "MessagesInOrder"
      )
    end

    test "a holder that gets the event close two times is found" do
      assert_violates(SpecModel.check("MessagePort", bug("two_closes")), "OneClosePerHolder")
    end

    test "a listener process that ignores its gate is found" do
      assert_violates(SpecModel.check("MessagePort", bug("no_gate")), "MessageOnlyAfterStart")
    end

    test "a port that waits with no end for a stopped listener process is found" do
      assert_violates(SpecModel.check("MessagePort", bug("no_answer_at_closed_gate")), "Drains")
    end

    test "an event close that waits for the start of the port is found" do
      assert_violates(
        SpecModel.check("MessagePort", bug("close_waits_for_start")),
        "CloseDoesNotWaitForStart"
      )
    end
  end

  describe "BroadcastChannel" do
    test "the design has all its properties" do
      assert_holds(SpecModel.check("BroadcastChannel"))
    end

    test "the design has all its properties when no channel is slow" do
      assert_holds(SpecModel.check("BroadcastChannel", {"Slow = {c3}", "Slow = {}"}))
    end

    test "a channel that gets its own message is found" do
      assert_violates(
        SpecModel.check("BroadcastChannel", bug("message_to_sender")),
        "NoMessageToSender"
      )
    end

    test "one dispatcher that waits for a slow channel is found" do
      assert_violates(
        SpecModel.check("BroadcastChannel", bug("one_dispatcher")),
        "NoWaitForSlowChannel"
      )
    end

    test "a closed channel that delivers a message is found" do
      assert_violates(
        SpecModel.check("BroadcastChannel", bug("closed_channel_delivers")),
        "NoMessageAfterClose"
      )
    end
  end

  describe "Disposal" do
    test "the design has all its properties" do
      assert_holds(SpecModel.check("Disposal"))
    end

    test "a block that starts with a value that is not disposable is found" do
      assert_violates(
        SpecModel.check("Disposal", bug("value_is_not_examined")),
        "BlockHasDisposableValue"
      )
    end

    test "a resource that stays after an error of the block is found" do
      assert_violates(SpecModel.check("Disposal", bug("no_disposal_after_error")), "AllReleased")
    end

    test "an error of a disposal that replaces the error of the block is found" do
      assert_violates(
        SpecModel.check("Disposal", bug("disposal_error_replaces")),
        "NoErrorIsLost"
      )
    end
  end

  describe "Console" do
    test "the design has all its properties" do
      assert_holds(SpecModel.check("Console"))
    end

    test "a message with no indent in a group is found" do
      assert_violates(SpecModel.check("Console", bug("no_indent")), "IndentIsDepth")
    end

    test "a depth of the groups below zero is found" do
      assert_violates(SpecModel.check("Console", bug("group_end_below_zero")), "TypeOK")
    end

    test "a timer that starts again is found" do
      assert_violates(
        SpecModel.check("Console", bug("time_starts_again")),
        "TimerIsNotStartedAgain"
      )
    end

    test "a timer that runs after its end is found" do
      assert_violates(
        SpecModel.check("Console", bug("time_end_keeps_timer")),
        "EndedTimerDoesNotRun"
      )
    end

    test "a counter that keeps its value after a reset is found" do
      assert_violates(
        SpecModel.check("Console", bug("count_reset_keeps_count")),
        "ResetCounterIsZero"
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
