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

  describe "TransformStream" do
    test "the design has all its properties" do
      assert_holds(SpecModel.check("TransformStream"))
    end

    test "the design with a readable high water mark of 1 has all its properties" do
      assert_holds(SpecModel.check("TransformStream", {"HWM = 0", "HWM = 1"}))
    end

    test "a second call of the transformer at the end is found" do
      assert_violates(
        SpecModel.check("TransformStream", bug("no_finish_promise")),
        "FinishOnce"
      )
    end

    test "a readable side that does not turn its backpressure on is found" do
      assert_violates(
        SpecModel.check("TransformStream", bug("no_backpressure_on")),
        "QueueBound"
      )
    end

    test "a write that waits after the end of the backpressure is found" do
      assert_violates(SpecModel.check("TransformStream", bug("no_release")), "Progress")
    end

    test "a held write that does not mark the cell of the backpressure is found" do
      assert_violates(SpecModel.check("TransformStream", bug("no_mark")), "Progress")
    end

    test "a check and a mark of the cell in two steps are found" do
      assert_violates(
        SpecModel.check("TransformStream", bug("check_then_mark")),
        "OffWhenWanted"
      )
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

  describe "Performance" do
    test "the design has all its properties" do
      assert_holds(SpecModel.check("Performance"))
    end

    test "a measure that makes a mark impossible to find is found" do
      assert_violates(SpecModel.check("Performance", bug("measure_hides_mark")), "MarkIsFound")
    end

    test "a measure that uses the first mark with a name is found" do
      assert_violates(
        SpecModel.check("Performance", bug("measure_uses_first_mark")),
        "MeasureUsesLastMark"
      )
    end

    test "a clear of the marks that removes measures is found" do
      assert_violates(
        SpecModel.check("Performance", bug("clear_marks_removes_measures")),
        "ClearKeepsTheOtherType"
      )
    end
  end

  describe "ResponseBody" do
    test "the design has all its properties" do
      assert_holds(SpecModel.check("ResponseBody"))
    end

    test "the design has all its properties with a larger queue" do
      assert_holds(SpecModel.check("ResponseBody", {"Limit = 1", "Limit = 2"}))
    end

    test "a body that is not complete, but looks complete, is found" do
      assert_violates(
        SpecModel.check("ResponseBody", bug("close_on_failure")),
        "FullBodyOrError"
      )
    end

    test "a reader that waits with no end when the holder stops is found" do
      assert_violates(SpecModel.check("ResponseBody", bug("no_source_watch")), "ReaderGetsAnEnd")
    end

    test "a reader that waits with no end when the holder ignores a failure is found" do
      assert_violates(
        SpecModel.check("ResponseBody", bug("failure_ignored")),
        "ReaderGetsAnEnd"
      )
    end

    test "a holder that reads with no backpressure is found" do
      assert_violates(SpecModel.check("ResponseBody", bug("no_backpressure")), "BufferBounded")
    end

    test "a connection that stays after a cancel is found" do
      assert_violates(
        SpecModel.check("ResponseBody", bug("cancel_ignored")),
        "CancelClosesConnection"
      )
    end
  end

  describe "ConnectionPool" do
    test "the design has all its properties" do
      assert_holds(SpecModel.check("ConnectionPool"))
    end

    test "a pool with no limit is found" do
      assert_violates(SpecModel.check("ConnectionPool", bug("no_limit")), "SlotsBounded")
    end

    test "a slot that stays after its process stopped is found" do
      assert_violates(SpecModel.check("ConnectionPool", bug("no_down_cleanup")), "SlotsMatch")
    end

    test "a connection that goes idle while a process waits is found" do
      assert_violates(
        SpecModel.check("ConnectionPool", bug("serve_ignored")),
        "WaitOnlyWhenFull"
      )
    end
  end

  describe "SocketFlow" do
    test "the design has all its properties" do
      assert_holds(SpecModel.check("SocketFlow"))
    end

    test "the design has all its properties with a larger limit" do
      assert_holds(SpecModel.check("SocketFlow", [{"Limit = 2", "Limit = 3"}]))
    end

    test "a process that asks while a message is in its mailbox is found" do
      assert_violates(SpecModel.check("SocketFlow", bug("ask_with_message")), "MailboxBounded")
    end

    test "a process that reads with no limit is found" do
      assert_violates(SpecModel.check("SocketFlow", bug("no_backpressure")), "BufferBounded")
    end

    test "a process that does not keep its flag when it asks is found" do
      assert_violates(SpecModel.check("SocketFlow", bug("lose_flag")), "FlagMatchesSocket")
    end

    test "a process that reads its socket after the end of the response is found" do
      assert_violates(SpecModel.check("SocketFlow", bug("ask_after_end")), "NoReadAfterEnd")
    end
  end

  describe "SharedConnection" do
    test "the design has all its properties" do
      assert_holds(SpecModel.check("SharedConnection"))
    end

    test "the design has all its properties with two streams" do
      assert_holds(SpecModel.check("SharedConnection", [{"MaxStreams = 1", "MaxStreams = 2"}]))
    end

    test "a request that goes again after the server processed it is found" do
      assert_violates(
        SpecModel.check("SharedConnection", bug("retry_processed")),
        "AtMostOnce"
      )
    end

    test "a connection with more streams than the server allows is found" do
      assert_violates(SpecModel.check("SharedConnection", bug("no_limit")), "StreamsBounded")
    end

    test "a request in the queue that fails at a GOAWAY is found" do
      assert_violates(
        SpecModel.check("SharedConnection", bug("fail_queued")),
        "ErrorOnlyAfterFailure"
      )
    end
  end

  describe "PipeAbort" do
    test "the design has all its properties" do
      assert_holds(SpecModel.check("PipeAbort"))
    end

    test "a pipe that sends the cancel with the abort is found" do
      assert_violates(SpecModel.check("PipeAbort", bug("parallel")), "AbortFirst")
    end

    test "a notice that the worker sends to the pipe is found" do
      assert_violates(SpecModel.check("PipeAbort", bug("direct_notice")), "NoLateNotice")
    end

    test "a notice after the reply at the time limit is found" do
      assert_violates(SpecModel.check("PipeAbort", bug("relay_unchecked")), "NoLateNotice")
    end

    test "a pipe that waits only for the notice is found" do
      assert_violates(SpecModel.check("PipeAbort", bug("keeps_waiting")), "Progress")
    end

    # A state where the source has its cancel while the write is in flight
    # is possible in the design, and not with the bug.
    test "a destination that sends no notice while a write is in flight is found" do
      cancel_waits = {"    NoLateNotice\n", "    NoLateNotice\n    CancelWaitsForWrite\n"}
      assert_violates(SpecModel.check("PipeAbort", [cancel_waits]), "CancelWaitsForWrite")
      assert_holds(SpecModel.check("PipeAbort", [bug("no_early_notice"), cancel_waits]))
    end
  end

  describe "PublicAbort" do
    test "the design has all its properties" do
      assert_holds(SpecModel.check("PublicAbort"))
    end

    test "an abort that comes before the requests of the listeners is found" do
      assert_violates(SpecModel.check("PublicAbort", bug("no_fence")), "CloseFirst")
    end

    test "a result of the worker that the stream handles before the abort is found" do
      assert_violates(SpecModel.check("PublicAbort", bug("no_hold")), "ResultAfter")
    end

    test "a window that stays after the stop of the caller is found" do
      assert_violates(SpecModel.check("PublicAbort", bug("keep_window")), "Progress")
    end
  end

  describe "PriorityMessages" do
    test "the design has all its properties" do
      assert_holds(SpecModel.check("PriorityMessages"))
    end

    test "a priority message that passes the messages of its sender is found" do
      assert_violates(SpecModel.check("PriorityMessages", bug("no_fence")), "SenderOrder")
    end

    test "an abort as a usual message is found: it waits for the writes of others" do
      assert_violates(SpecModel.check("PriorityMessages", bug("usual_abort")), "AbortPasses")
    end

    test "a stream that handles each message up to the fence first is found" do
      assert_violates(SpecModel.check("PriorityMessages", bug("take_all")), "AbortPasses")
    end

    test "a fence after the priority message is found: the sender can stop before it" do
      assert_violates(SpecModel.check("PriorityMessages", bug("fence_after")), "Progress")
    end

    test "a stream that forgets a fence that it handled is found" do
      assert_violates(SpecModel.check("PriorityMessages", bug("forget_fence")), "Progress")
    end
  end

  describe "PipeTo" do
    test "the design has all its properties" do
      assert_holds(SpecModel.check("PipeTo"))
    end

    test "the design with the three options has all its properties" do
      options = {"Opts = {}", ~s(Opts = {"close", "abort", "cancel"})}
      assert_holds(SpecModel.check("PipeTo", options))
    end

    test "a last chunk that is lost when the source closes during a read is found" do
      assert_violates(SpecModel.check("PipeTo", bug("lose_last_chunk")), "AllChunks")
    end

    test "a pipe to a closed destination that does not cancel the source is found" do
      assert_violates(
        SpecModel.check("PipeTo", bug("dest_closed_no_cancel")),
        "ClosedDestCancels"
      )
    end

    test "a read when the destination is not ready is found" do
      assert_violates(SpecModel.check("PipeTo", bug("no_flow_control")), "QueueBound")
    end

    # With the high water mark 1, the only write of the pipe is in flight,
    # and the abort of the destination waits for it.
    test "the design with the high water mark 2 has all its properties" do
      assert_holds(SpecModel.check("PipeTo", {"HWM = 1", "HWM = 2"}))
    end

    test "a shutdown that does not wait for the writes is found" do
      assert_violates(
        SpecModel.check("PipeTo", [{"HWM = 1", "HWM = 2"}, bug("no_wait_writes")]),
        "NoLostWrite"
      )
    end

    test "a close with preventClose is found" do
      close = {"Opts = {}", ~s(Opts = {"close"})}

      assert_violates(
        SpecModel.check("PipeTo", [close, bug("ignore_prevent_close")]),
        "PreventsActions"
      )
    end

    test "a pipe that keeps its locks is found" do
      assert_violates(SpecModel.check("PipeTo", bug("keep_lock")), "LocksReleased")
    end

    test "a pipe that ignores its signal is found" do
      assert_violates(SpecModel.check("PipeTo", bug("ignore_signal")), "Progress")
    end
  end
end
