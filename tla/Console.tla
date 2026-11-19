------------------------------- MODULE Console -------------------------------
(* The state of Web.Console for one process: the groups, the timers, and    *)
(* the counters.                                                            *)
(*                                                                          *)
(* The module shows the message that each function writes, with its level   *)
(* and its indent, as the Console Standard specifies.                       *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design.                                                      *)
EXTENDS Integers

CONSTANTS
    Labels,    \* the labels of the timers and the counters
    MaxDepth,  \* the largest number of open groups
    MaxCount,  \* the largest value of a counter
    Bug        \* "none", or the name of a rule to remove

VARIABLES
    depth,   \* the number of open groups
    timers,  \* the labels of the timers that run
    counts,  \* counts[l] is the value of counter l. 0 is: no counter
    last,    \* the last call: its function, its label, and if its timer or
             \* its counter was there before the call
    out      \* the message that the last call wrote

vars == <<depth, timers, counts, last, out>>

NoLabel == "none"
Call(op, label, existed) == [op |-> op, label |-> label, existed |-> existed]

\* A message has a kind, a level, an indent, and the value of a counter.
Message(kind, level, value) ==
    [kind |-> kind, level |-> level,
     indent |-> IF Bug = "no_indent" THEN 0 ELSE depth, value |-> value]
Nothing == [kind |-> "none", level |-> "none", indent |-> 0, value |-> 0]

Init ==
    /\ depth = 0
    /\ timers = {}
    /\ counts = [l \in Labels |-> 0]
    /\ last = Call("none", NoLabel, FALSE)
    /\ out = Nothing

\* log, info, warn, error, and debug write one message.
Log(level) ==
    /\ level \in {"debug", "info", "notice", "warning", "error"}
    /\ out' = Message("log", level, 0)
    /\ last' = Call("log", NoLabel, FALSE)
    /\ UNCHANGED <<depth, timers, counts>>

\* group writes its label, then opens the group.
Group(labelled) ==
    /\ labelled \in BOOLEAN /\ depth < MaxDepth
    /\ out' = IF labelled THEN Message("group", "notice", 0) ELSE Nothing
    /\ depth' = depth + 1
    /\ last' = Call("group", NoLabel, FALSE)
    /\ UNCHANGED <<timers, counts>>

\* group_end with no open group has no effect.
GroupEnd ==
    /\ depth' = IF depth > 0 \/ Bug = "group_end_below_zero" THEN depth - 1 ELSE 0
    /\ out' = Nothing
    /\ last' = Call("group_end", NoLabel, FALSE)
    /\ UNCHANGED <<timers, counts>>

Clear ==
    /\ depth' = 0
    /\ out' = Nothing
    /\ last' = Call("clear", NoLabel, FALSE)
    /\ UNCHANGED <<timers, counts>>

\* time does not start a timer that runs: it writes a warning.
Time(l) ==
    /\ l \in Labels
    /\ timers' = timers \cup {l}
    /\ out' = IF l \in timers /\ Bug # "time_starts_again"
              THEN Message("timer_exists", "warning", 0) ELSE Nothing
    /\ last' = Call("time", l, l \in timers)
    /\ UNCHANGED <<depth, counts>>

\* time_log writes the time of a timer. The timer continues.
TimeLog(l) ==
    /\ l \in Labels
    /\ out' = IF l \in timers
              THEN Message("elapsed", "info", 0) ELSE Message("no_timer", "warning", 0)
    /\ last' = Call("time_log", l, l \in timers)
    /\ UNCHANGED <<depth, timers, counts>>

\* time_end writes the time of a timer, and stops it.
TimeEnd(l) ==
    /\ l \in Labels
    /\ out' = IF l \in timers
              THEN Message("elapsed", "info", 0) ELSE Message("no_timer", "warning", 0)
    /\ timers' = IF Bug = "time_end_keeps_timer" THEN timers ELSE timers \ {l}
    /\ last' = Call("time_end", l, l \in timers)
    /\ UNCHANGED <<depth, counts>>

\* count adds one to a counter, and writes its value.
Count(l) ==
    /\ l \in Labels /\ counts[l] < MaxCount
    /\ counts' = [counts EXCEPT ![l] = @ + 1]
    /\ out' = Message("count", "info", counts[l] + 1)
    /\ last' = Call("count", l, counts[l] > 0)
    /\ UNCHANGED <<depth, timers>>

\* count_reset sets a counter to zero. With no counter, it writes a warning.
CountReset(l) ==
    /\ l \in Labels
    /\ counts' = IF Bug = "count_reset_keeps_count" THEN counts
                 ELSE [counts EXCEPT ![l] = 0]
    /\ out' = IF counts[l] > 0 THEN Nothing ELSE Message("no_counter", "warning", 0)
    /\ last' = Call("count_reset", l, counts[l] > 0)
    /\ UNCHANGED <<depth, timers>>

Next ==
    \/ \E level \in {"debug", "info", "notice", "warning", "error"} : Log(level)
    \/ \E labelled \in BOOLEAN : Group(labelled)
    \/ GroupEnd \/ Clear
    \/ \E l \in Labels : Time(l) \/ TimeLog(l) \/ TimeEnd(l) \/ Count(l) \/ CountReset(l)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ depth \in 0..MaxDepth
    /\ timers \subseteq Labels
    /\ counts \in [Labels -> 0..MaxCount]

\* A message has the indent of the groups that were open when the function
\* wrote it. The label of a group has the indent of the groups around it.
IndentIsDepth ==
    out.kind # "none" =>
        out.indent = IF last.op = "group" THEN depth - 1 ELSE depth

\* A timer that runs is not started again: the call writes a warning.
TimerIsNotStartedAgain ==
    (last.op = "time" /\ last.existed) =>
        (out.kind = "timer_exists" /\ out.level = "warning")

\* A timer that ended does not run.
EndedTimerDoesNotRun == last.op = "time_end" => last.label \notin timers

\* A call for a timer that does not run writes a warning, and a call for a
\* timer that runs writes its time.
TimerMessages ==
    last.op \in {"time_log", "time_end"} =>
        IF last.existed
        THEN out.kind = "elapsed" /\ out.level = "info"
        ELSE out.kind = "no_timer" /\ out.level = "warning"

\* count writes the new value of its counter.
CountWritesValue ==
    last.op = "count" =>
        (out.kind = "count" /\ out.value = counts[last.label] /\ out.value >= 1)

\* After count_reset, the counter is zero. With no counter, the call writes
\* a warning.
ResetCounterIsZero ==
    last.op = "count_reset" =>
        /\ counts[last.label] = 0
        /\ (~last.existed) = (out.kind = "no_counter")
=============================================================================
