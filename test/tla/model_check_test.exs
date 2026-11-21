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

  describe "ByteTee" do
    test "the design has all its properties" do
      assert_holds(SpecModel.check("ByteTee"))
    end

    # The two defects that tests found in the tee of a byte stream.
    test "a tee that forgets a pull during a read is found" do
      assert_violates(SpecModel.check("ByteTee", bug("lost_pull")), "ReadsEnd")
    end

    test "a tee that loses the buffer that a cancel of the source dropped is found" do
      assert_violates(SpecModel.check("ByteTee", bug("respond_dropped")), "NoLostBuffer")
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

    test "a constructor that returns before the end of start on the two sides is found" do
      assert_violates(
        SpecModel.check("TransformStream", bug("start_message")),
        "StartedForUse"
      )
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

  describe "TransformLifetime" do
    test "the design has all its properties" do
      assert_holds(SpecModel.check("TransformLifetime"))
    end

    test "a side that does not tell the change of its lock is found" do
      assert_violates(SpecModel.check("TransformLifetime", bug("no_notify")), "CopyAgrees")
    end

    test "a side that does not monitor the other side is found" do
      assert_violates(SpecModel.check("TransformLifetime", bug("no_monitor")), "CopyAgrees")
    end

    test "a side that asks again after a denial is found" do
      assert_violates(
        SpecModel.check("TransformLifetime", bug("own_lock_only")),
        "DeniedKnowsLock"
      )
    end

    test "two sides that continue after all their processes are found" do
      assert_violates(SpecModel.check("TransformLifetime", bug("no_owner_rule")), "NoOrphan")
    end

    # The design before the handshake: a lock of the other side that is
    # still in a message does not keep the side.
    test "a side that ends with no handshake while a lock is in a message is found" do
      assert_violates(SpecModel.check("TransformLifetime", bug("no_handshake")), "KeptByLock")
    end

    test "a side that grants a lock while it waits for the answer is found" do
      assert_violates(SpecModel.check("TransformLifetime", bug("no_freeze")), "KeptByLock")
    end

    test "two sides that wait for each other in a blocking call are found" do
      assert_violates(SpecModel.check("TransformLifetime", bug("blocking_ask")), "AskAnswered")
    end
  end

  describe "LazyStream" do
    # A bug that needs no kill of a starter: the check is smaller.
    @no_kill {"Kills = 1", "Kills = 0"}
    @stream_kill [@no_kill, {"StreamKills = 0", "StreamKills = 1"}]
    @all_ops ~s(Ops = {"consumed", "canceled", "locked", "read"})
    @only_read {@all_ops, ~s(Ops = {"read"})}

    defp lazy_check(replace), do: SpecModel.check("LazyStream", replace)
    defp lazy_bug(name, replace \\ [@no_kill]), do: lazy_check([bug(name) | replace])

    test "the design has all its properties" do
      assert_holds(lazy_check(nil))
    end

    test "the design with a kill of a stream process has all its properties" do
      assert_holds(lazy_check(@stream_kill))
    end

    test "the code before the specification gives gone after a stop of the copy that starts" do
      assert_violates(lazy_bug("today"), "NoGoneWhileBytes")
    end

    test "copies that wait for a starter that stopped, with no new starter, are found" do
      assert_violates(lazy_bug("no_take_over", [@only_read]), "ReadEnds")
    end

    test "a stream process that stopped before a read and gives gone is found" do
      assert_violates(lazy_bug("dead_is_gone"), "NoGoneWhileBytes")
    end

    test "a read that does not set taken is found" do
      assert_violates(lazy_bug("pull_keeps_bytes"), "BytesOnce")
    end

    test "starters with no key are found" do
      assert_violates(lazy_bug("no_key"), "KeptForLock")
    end

    test "a claim that reads and then sets the cell is found" do
      assert_violates(lazy_bug("read_then_set"), "BytesOnce")

      assert_violates(
        lazy_bug("read_then_set", [@no_kill, {" BytesOnce", ""}]),
        "NoBytesAfterUse"
      )
    end

    test "a stream process that gets the bytes after a claim is found" do
      assert_violates(lazy_bug("closed_gets_bytes"), "BytesOnce")
    end

    test "a stream process that stops while a copy waits for its lock is found" do
      assert_violates(lazy_bug("no_keep"), "KeptForLock")
    end

    test "a disturb that does not take the bytes is found" do
      assert_violates(lazy_bug("disturb_keeps_bytes"), "BytesOnce")
    end

    test "a stream process that takes the bytes at its start is found" do
      assert_violates(lazy_bug("held_at_start"), "NoBytesAfterUse")

      no_use_property =
        {"PROPERTIES NoBytesAfterUse ReadEnds UselessStops", "PROPERTIES ReadEnds UselessStops"}

      assert_violates(lazy_bug("held_at_start", [@no_kill, no_use_property]), "NoGoneWhileBytes")
    end

    test "a second start of a stream process that crashes is found" do
      assert_violates(lazy_bug("unchecked_start", [@only_read]), "NoCrash")
    end

    test "a lock step that does not ask again after a kill of the process is found" do
      assert_violates(lazy_bug("lock_no_retry", @stream_kill), "NoGoneWhileBytes")
    end

    test "a stream process with no use that stays is found" do
      assert_violates(lazy_bug("stale_stays", [@only_read]), "UselessStops")
    end

    test "a claim from the state process, which a new stream process can have again, is found" do
      locked_or_read = {@all_ops, ~s(Ops = {"locked", "read"})}
      assert_violates(lazy_bug("process_claim", [locked_or_read | @stream_kill]), "BytesOnce")
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

    test "a signal that stops at the abort, before the steps of the abort, is found" do
      assert_violates(SpecModel.check("AbortSignal", bug("stop_at_mark")), "ServesSteps")
    end

    test "a signal that a listener or an abort algorithm does not keep is found" do
      assert_violates(SpecModel.check("AbortSignal", bug("use_not_kept")), "KeptForUse")
    end

    test "a signal that a dependent signal does not keep is found" do
      assert_violates(SpecModel.check("AbortSignal", bug("dependent_not_kept")), "KeptForUse")
    end

    test "a signal that stays after the steps of the abort is found" do
      assert_violates(SpecModel.check("AbortSignal", bug("keeps_after_abort")), "AbortedStops")
    end
  end

  describe "AbortSteps" do
    test "the design has all its properties" do
      assert_holds(SpecModel.check("AbortSteps"))
    end

    test "a dependent signal that is not aborted before the listeners run is found" do
      assert_violates(SpecModel.check("AbortSteps", bug("dependent_late")), "DependentMarked")
    end

    test "an event before the abort algorithms is found" do
      assert_violates(SpecModel.check("AbortSteps", bug("event_first")), "AlgorithmsFirst")
    end

    test "an event at the dependent signal before the event at the signal is found" do
      assert_violates(SpecModel.check("AbortSteps", bug("dependent_first")), "SignalFirst")
    end

    test "a second abort that fires the event again is found" do
      assert_violates(SpecModel.check("AbortSteps", bug("abort_twice")), "StepsOnce")
    end

    test "a signal that stops at the mark, before its listeners run, is found" do
      assert_violates(SpecModel.check("AbortSteps", bug("stop_at_mark")), "ListenerHears")
    end

    test "a signal that stays after the stop of the process of the steps is found" do
      assert_violates(SpecModel.check("AbortSteps", bug("ignore_caller_stop")), "AbortedStops")
    end

    test "an abort later that returns before the mark is found" do
      assert_violates(SpecModel.check("AbortSteps", bug("later_unmarked")), "ReturnedAborted")
    end

    test "an abort that returns before its steps is found" do
      assert_violates(
        SpecModel.check("AbortSteps", bug("now_returns_first")),
        "StepsBeforeReturn"
      )
    end
  end

  describe "AbortTimeouts" do
    test "the design has all its properties" do
      assert_holds(SpecModel.check("AbortTimeouts"))
    end

    test "a timeout that does not wait for the earlier timeouts is found" do
      assert_violates(SpecModel.check("AbortTimeouts", bug("no_wait")), "InSequence")
    end

    test "a timeout that does not wait for an earlier timeout with the same time is found" do
      assert_violates(SpecModel.check("AbortTimeouts", bug("strict_compare")), "InSequence")
    end

    test "a timeout that waits for a later timeout is found" do
      assert_violates(SpecModel.check("AbortTimeouts", bug("wait_for_later")), "Aborts")
    end
  end

  describe "EventTarget" do
    test "the design has all its properties" do
      assert_holds(SpecModel.check("EventTarget"))
    end

    test "a pass that calls a listener that came into the list during the pass is found" do
      assert_violates(SpecModel.check("EventTarget", bug("no_clone")), "ClonedOnly")
    end

    test "a listener of a process that stopped is found" do
      assert_violates(
        SpecModel.check("EventTarget", bug("keep_dead_listeners")),
        "ListenersOfLive"
      )
    end

    test "a target that stops while it has a listener is found" do
      assert_violates(SpecModel.check("EventTarget", bug("no_listener_rule")), "KeptForUse")
    end

    test "a target that stays with no use is found" do
      assert_violates(SpecModel.check("EventTarget", bug("stays_unused")), "UnusedStops")
    end

    test "a dispatch with one pass is found" do
      assert_violates(SpecModel.check("EventTarget", bug("one_pass")), "CaptureFirst")
    end

    test "a call of a listener that was removed is found" do
      assert_violates(
        SpecModel.check("EventTarget", bug("no_removed_check")),
        "RemovedNotCalled"
      )
    end

    test "a listener with once that stays in the list is found" do
      assert_violates(SpecModel.check("EventTarget", bug("once_kept")), "OnceOnce")
    end

    test "a dispatch in the dispatch of the same event is found" do
      assert_violates(SpecModel.check("EventTarget", bug("no_dispatch_flag")), "CalledOnce")
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

    test "a request whose write fails on a closed socket, and that gives the error, is found" do
      assert_violates(
        SpecModel.check("SharedConnection", bug("fail_written")),
        "ErrorOnlyAfterFailure"
      )
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

    test "a usual message that does not tell its sender is found" do
      assert_violates(SpecModel.check("PriorityMessages", bug("no_sender")), "SenderOrder")
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

  describe "FormDataParser" do
    @freeze {~s(Callers = {"get", "iter"}), ~s(Callers = {"get", "freeze"})}

    test "the design has all its properties" do
      assert_holds(SpecModel.check("FormDataParser"))
    end

    test "the design with a freeze has all its properties" do
      assert_holds(SpecModel.check("FormDataParser", @freeze))
    end

    # The defect of 622e721: a call to a parser that stopped exited the
    # caller with :noproc.
    test "a call to a parser that stopped, with an exit of OTP, is found" do
      assert_violates(SpecModel.check("FormDataParser", bug("noproc_exit")), "NoCrash")
    end

    test "a call in flight at the stop of the owner, with an exit of OTP, is found" do
      assert_violates(SpecModel.check("FormDataParser", bug("shutdown_exit")), "NoCrash")
    end

    test "a stop that cancels the file stream, which then ends short, is found" do
      assert_violates(SpecModel.check("FormDataParser", bug("cancel_child")), "FileIntegrity")
    end

    test "a pull of a parser that stopped, which ends the file stream short, is found" do
      assert_violates(
        SpecModel.check("FormDataParser", bug("close_on_lost_parser")),
        "FileIntegrity"
      )
    end

    # The parser waits for a source that stalls, and takes no message: the
    # model has no step, thus the check stops the deadlock check.
    test "a parser that takes no cancel while it waits for the source is found" do
      result = SpecModel.check("FormDataParser", bug("blocking_read"), deadlock: false)
      assert_violates(result, "PromptStop")
    end

    test "a query that goes past a file part that its reader did not read is found" do
      assert_violates(SpecModel.check("FormDataParser", bug("no_discard")), "FileBeforeNext")
    end

    # The defect that the property test found: an iteration discarded the
    # file part and read past it, and a get that waited got no answer.
    test "a query that answers only its caller, while other calls wait, is found" do
      assert_violates(SpecModel.check("FormDataParser", bug("serve_only_caller")), "NoLostReply")
    end

    test "a stop that gives no answer to the calls that wait is found" do
      assert_violates(SpecModel.check("FormDataParser", bug("lost_pending")), "NoLostReply")
    end

    test "a discard that moves the iteration past an entry is found" do
      assert_violates(
        SpecModel.check("FormDataParser", bug("discard_skips_entry")),
        "EntriesInOrder"
      )
    end

    test "a stop of the owner with no terminate, which keeps the file stream, is found" do
      assert_violates(
        SpecModel.check("FormDataParser", bug("kill_on_owner_down")),
        "StreamEndsWithParser"
      )
    end

    test "a freeze that gives an error to the calls that wait is found" do
      assert_violates(
        SpecModel.check("FormDataParser", [bug("freeze_drops_pending"), @freeze]),
        "NoWrongError"
      )
    end
  end
end
