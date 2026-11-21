------------------------------ MODULE AbortSteps ------------------------------
(* The steps "signal abort" of the DOM Standard in Web.AbortSignal: one    *)
(* abort of a signal that can have a listener, an abort algorithm, and a   *)
(* signal of AbortSignal.any/1 that depends on it. AbortSignal.tla has the *)
(* lifetime of the signal.                                                 *)
(*                                                                          *)
(* The steps run in the process that aborts, the caller:                   *)
(*   1. Mark: the process of the signal marks the signal and the dependent  *)
(*      signal aborted, and gives the abort algorithms to the caller.       *)
(*   2. The caller runs the abort algorithms.                               *)
(*   3. The caller fires the event "abort" at the signal, then at the       *)
(*      dependent signal. The process of each signal answers the requests   *)
(*      of the dispatch: the listeners are there.                           *)
(*   4. The caller tells the processes that they can stop.                  *)
(* With __signal_abort_later__/2, the call returns after step 1, and a new  *)
(* process does steps 2 to 4. When the process that does the steps stops,  *)
(* for example in a listener, the processes of the signals stop. A second  *)
(* abort finds the signal aborted, and does nothing.                       *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design.                                                      *)
EXTENDS Naturals, Sequences

CONSTANTS
    Bug         \* "none", or the name of a rule to remove

VARIABLES
    listener,     \* TRUE when the signal has a listener of the event
    algorithm,    \* TRUE when the signal has an abort algorithm
    aborted,      \* TRUE after the mark of the abort
    running,      \* TRUE while the process of the signal is alive
    dep,          \* the dependent signal: "none", "running", "aborted", or
                  \* "stopped"
    caller,       \* the steps of the process that aborts: "idle", "called",
                  \* "marked", "algorithms", "early", "dep_first", "fired",
                  \* "fired_dep", "done", or "stopped"
    later,        \* TRUE for an abort of __signal_abort_later__/2
    returned,     \* TRUE after the call of the abort returned
    handed,       \* TRUE when the caller got the abort algorithm at the mark
    heard,        \* TRUE after the listener of the signal ran
    log           \* the steps that the processes see, in their sequence:
                  \* "alg", "event", and "dep_event"

vars == <<listener, algorithm, aborted, running, dep, caller, later, returned,
          handed, heard, log>>

Init ==
    /\ listener = FALSE
    /\ algorithm = FALSE
    /\ aborted = FALSE
    /\ running = TRUE
    /\ dep = "none"
    /\ caller = "idle"
    /\ later = FALSE
    /\ returned = FALSE
    /\ handed = FALSE
    /\ heard = FALSE
    /\ log = <<>>

InLog(e) == \E i \in 1..Len(log) : log[i] = e

\* Before the abort: a client adds a listener and an abort algorithm, and
\* AbortSignal.any/1 makes a signal that depends on the signal. That signal
\* can stop with no abort, when its maker stopped.
AddListener ==
    /\ caller = "idle" /\ ~listener
    /\ listener' = TRUE
    /\ UNCHANGED <<algorithm, aborted, running, dep, caller, later, returned,
                   handed, heard, log>>

AddAlgorithm ==
    /\ caller = "idle" /\ ~algorithm
    /\ algorithm' = TRUE
    /\ UNCHANGED <<listener, aborted, running, dep, caller, later, returned,
                   handed, heard, log>>

Depend ==
    /\ caller = "idle" /\ dep = "none"
    /\ dep' = "running"
    /\ UNCHANGED <<listener, algorithm, aborted, running, caller, later, returned,
                   handed, heard, log>>

DepExpire ==
    /\ caller = "idle" /\ dep = "running"
    /\ dep' = "stopped"
    /\ UNCHANGED <<listener, algorithm, aborted, running, caller, later, returned,
                   handed, heard, log>>

\* Step 1. The process of the signal marks the signal and the dependent
\* signal, and gives the algorithm to the caller. It stays, to answer the
\* dispatch. With the bug "stop_at_mark", it stops at once.
Mark ==
    /\ aborted' = TRUE
    /\ running' = (Bug # "stop_at_mark")
    /\ dep' = IF dep = "running" /\ Bug # "dependent_late" THEN "aborted" ELSE dep
    /\ handed' = algorithm
    /\ caller' = "marked"
    /\ UNCHANGED <<listener, algorithm, heard, log>>

\* The call of AbortController.abort/2. It returns after step 4. With the
\* bug "now_returns_first", it returns after the mark.
Abort ==
    /\ caller = "idle"
    /\ Mark
    /\ later' = FALSE
    /\ returned' = (Bug = "now_returns_first")

\* The call of __signal_abort_later__/2. The signal is aborted when the call
\* returns. With the bug "later_unmarked", the call returns at once, and the
\* new process marks the signal.
AbortLater ==
    /\ caller = "idle"
    /\ later' = TRUE
    /\ returned' = TRUE
    /\ IF Bug = "later_unmarked"
          THEN /\ caller' = "called"
               /\ UNCHANGED <<listener, algorithm, aborted, running, dep, handed,
                              heard, log>>
          ELSE Mark

LateMark ==
    /\ caller = "called"
    /\ Mark
    /\ UNCHANGED <<later, returned>>

\* Step 2. The caller runs the abort algorithm. With the bug "event_first",
\* it runs it after the event.
Algorithms ==
    /\ \/ caller = "marked" /\ Bug # "event_first"
       \/ caller = "early"
    /\ log' = IF handed THEN Append(log, "alg") ELSE log
    /\ caller' = IF caller = "marked" THEN "algorithms" ELSE "fired"
    /\ UNCHANGED <<listener, algorithm, aborted, running, dep, later, returned,
                   handed, heard>>

\* Step 3. The listener of the signal runs, while the process of the signal
\* answers the dispatch.
FireSignal ==
    /\ \/ caller = "algorithms" /\ Bug # "dependent_first"
       \/ caller = "marked" /\ Bug = "event_first"
       \/ caller = "dep_first"
    /\ heard' = (listener /\ running)
    /\ log' = Append(log, "event")
    /\ caller' = CASE caller = "algorithms" -> "fired"
                  [] caller = "marked" -> "early"
                  [] OTHER -> "fired_dep"
    /\ UNCHANGED <<listener, algorithm, aborted, running, dep, later, returned,
                   handed>>

\* Step 3 for the dependent signal. With the bug "dependent_late", the mark
\* of the dependent signal comes only now. With the bug "dependent_first",
\* its event comes before the event of the signal.
FireDependent ==
    /\ \/ caller = "fired"
       \/ caller = "algorithms" /\ Bug = "dependent_first"
    /\ dep' = IF dep = "running" THEN "aborted" ELSE dep
    /\ log' = IF dep \in {"running", "aborted"} THEN Append(log, "dep_event") ELSE log
    /\ caller' = IF caller = "fired" THEN "fired_dep" ELSE "dep_first"
    /\ UNCHANGED <<listener, algorithm, aborted, running, later, returned, handed,
                   heard>>

\* Step 4: the caller tells the processes that they can stop. The call of
\* AbortController.abort/2 returns.
Done ==
    /\ caller = "fired_dep"
    /\ caller' = "done"
    /\ returned' = TRUE
    /\ UNCHANGED <<listener, algorithm, aborted, running, dep, later, handed,
                   heard, log>>

\* The process that does the steps stops, for example in a listener.
CallerStop ==
    /\ caller \in {"marked", "algorithms", "early", "dep_first", "fired", "fired_dep"}
    /\ caller' = "stopped"
    /\ UNCHANGED <<listener, algorithm, aborted, running, dep, later, returned,
                   handed, heard, log>>

\* A second abort finds the signal aborted, and does nothing. With the bug
\* "abort_twice", it fires the event again while the process runs.
AbortAgain ==
    /\ aborted /\ caller # "called"
    /\ IF Bug = "abort_twice" /\ running
          THEN /\ log' = Append(log, "event")
               /\ heard' = (heard \/ listener)
               /\ UNCHANGED <<listener, algorithm, aborted, running, dep, caller,
                              later, returned, handed>>
          ELSE UNCHANGED vars

\* The process of a signal gets the end of the steps, or the stop of the
\* caller, and stops.
Finished == caller = "done" \/ (caller = "stopped" /\ Bug # "ignore_caller_stop")

SignalStop ==
    /\ aborted /\ running /\ Finished
    /\ running' = FALSE
    /\ UNCHANGED <<listener, algorithm, aborted, dep, caller, later, returned,
                   handed, heard, log>>

DepStop ==
    /\ dep = "aborted" /\ Finished
    /\ dep' = "stopped"
    /\ UNCHANGED <<listener, algorithm, aborted, running, caller, later, returned,
                   handed, heard, log>>

Next ==
    \/ AddListener \/ AddAlgorithm \/ Depend \/ DepExpire
    \/ Abort \/ AbortLater \/ LateMark \/ Algorithms \/ FireSignal \/ FireDependent
    \/ Done \/ CallerStop \/ AbortAgain \/ SignalStop \/ DepStop
    \/ UNCHANGED vars

Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(LateMark) /\ WF_vars(Algorithms) /\ WF_vars(FireSignal)
    /\ WF_vars(FireDependent) /\ WF_vars(Done) /\ WF_vars(SignalStop)
    /\ WF_vars(DepStop)

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ listener \in BOOLEAN
    /\ algorithm \in BOOLEAN
    /\ aborted \in BOOLEAN
    /\ running \in BOOLEAN
    /\ dep \in {"none", "running", "aborted", "stopped"}
    /\ caller \in {"idle", "called", "marked", "algorithms", "early", "dep_first",
                   "fired", "fired_dep", "done", "stopped"}
    /\ later \in BOOLEAN
    /\ returned \in BOOLEAN
    /\ handed \in BOOLEAN
    /\ heard \in BOOLEAN
    /\ \A i \in 1..Len(log) : log[i] \in {"alg", "event", "dep_event"}

\* The dependent signal is aborted before a listener runs: the mark of the
\* signal marks it too.
DependentMarked == aborted => dep # "running"

\* The abort algorithm runs before the event.
AlgorithmsFirst ==
    \A i \in 1..Len(log) : log[i] = "event" => ~\E j \in (i + 1)..Len(log) : log[j] = "alg"

\* The event at the signal comes before the event at the dependent signal.
SignalFirst ==
    \A i \in 1..Len(log) : log[i] = "dep_event" => \E j \in 1..(i - 1) : log[j] = "event"

\* Each step happens one time at most: a second abort does nothing.
StepsOnce == \A i, j \in 1..Len(log) : i # j => log[i] # log[j]

\* The listener of the signal runs: the process of the signal answers the
\* dispatch.
ListenerHears == InLog("event") /\ listener => heard

\* The signal is aborted when the call of the abort returns.
ReturnedAborted == returned => aborted

\* AbortController.abort/2 returns after the steps.
StepsBeforeReturn == returned /\ ~later => caller = "done"

\* An aborted signal stops: after the steps, or after the stop of the
\* process that does them.
AbortedStops == aborted ~> ~running

\* The steps are complete when the caller does not stop.
StepsComplete == (aborted /\ caller # "stopped") ~> (caller \in {"done", "stopped"})
=============================================================================
