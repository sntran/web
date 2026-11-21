----------------------------- MODULE AbortTimeouts -----------------------------
(* The signals of AbortSignal.timeout/1 that one process makes.            *)
(*                                                                          *)
(* The steps "run steps after a timeout" of the HTML Standard wait for the  *)
(* timeouts of the same global with the same ordering identifier, that     *)
(* started before, and whose time is the same or shorter. In the library   *)
(* the global of a timeout is the process that makes it. When the time of  *)
(* a timeout is complete, its signal starts a new process. That process    *)
(* waits until the signal of each such earlier timeout stopped, and then   *)
(* aborts the signal: the listeners run, and the signal stops. A signal of *)
(* a timeout can also stop with no abort, when it has no use.              *)
(*                                                                          *)
(* The timeouts are the numbers 1..N, in the sequence in which the process *)
(* makes them. Each one has a time of 1 or 2 from the clock at that time.  *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design.                                                      *)
EXTENDS Naturals, Sequences

CONSTANTS
    N,          \* the number of timeouts
    Bug         \* "none", or the name of a rule to remove

Timeouts == 1..N
Times == {1, 2}

VARIABLES
    time,     \* time[t] is the time of timeout t, or 0 before it is made
    due,      \* due[t] is the clock at the end of the time of timeout t
    clock,    \* the time now
    state,    \* state[t]: "none", "pending", "waiting", "aborting", or
              \* "stopped"
    log       \* the timeouts whose listeners ran, in their sequence

vars == <<time, due, clock, state, log>>

Init ==
    /\ time = [t \in Timeouts |-> 0]
    /\ due = [t \in Timeouts |-> 0]
    /\ clock = 0
    /\ state = [t \in Timeouts |-> "none"]
    /\ log = <<>>

\* The process makes the next timeout, with time ms from now.
Make(t, ms) ==
    /\ state[t] = "none" /\ (IF t = 1 THEN TRUE ELSE state[t - 1] # "none")
    /\ time' = [time EXCEPT ![t] = ms]
    /\ due' = [due EXCEPT ![t] = clock + ms]
    /\ state' = [state EXCEPT ![t] = "pending"]
    /\ UNCHANGED <<clock, log>>

\* The earlier timeouts that timeout t waits for.
Earlier(t) ==
    CASE Bug = "no_wait" -> {}
      [] Bug = "strict_compare" -> {e \in Timeouts : e < t /\ time[e] < time[t]}
      [] Bug = "wait_for_later" -> {e \in Timeouts : e # t /\ time[e] <= time[t]}
      [] OTHER -> {e \in Timeouts : e < t /\ time[e] <= time[t]}

Tick ==
    /\ clock < 3
    /\ clock' = clock + 1
    /\ UNCHANGED <<time, due, state, log>>

\* The time of timeout t is complete: its signal starts the process that
\* aborts it.
Fire(t) ==
    /\ state[t] = "pending" /\ clock >= due[t]
    /\ state' = [state EXCEPT ![t] = "waiting"]
    /\ UNCHANGED <<time, due, clock, log>>

\* The process aborts the signal after the earlier timeouts stopped. The
\* listeners run.
Run(t) ==
    /\ state[t] = "waiting"
    /\ \A e \in Earlier(t) : state[e] = "stopped"
    /\ state' = [state EXCEPT ![t] = "aborting"]
    /\ log' = Append(log, t)
    /\ UNCHANGED <<time, due, clock>>

\* After the steps of the abort, the signal stops.
Stop(t) ==
    /\ state[t] = "aborting"
    /\ state' = [state EXCEPT ![t] = "stopped"]
    /\ UNCHANGED <<time, due, clock, log>>

\* A signal with no use stops with no abort.
Drop(t) ==
    /\ state[t] = "pending"
    /\ state' = [state EXCEPT ![t] = "stopped"]
    /\ UNCHANGED <<time, due, clock, log>>

Next ==
    \/ Tick
    \/ \E t \in Timeouts, ms \in Times : Make(t, ms)
    \/ \E t \in Timeouts : Fire(t) \/ Run(t) \/ Stop(t) \/ Drop(t)
    \/ UNCHANGED vars

Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(Tick)
    /\ \A t \in Timeouts : WF_vars(Fire(t)) /\ WF_vars(Run(t)) /\ WF_vars(Stop(t))

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ time \in [Timeouts -> {0} \cup Times]
    /\ due \in [Timeouts -> 0..5]
    /\ clock \in 0..3
    /\ state \in [Timeouts -> {"none", "pending", "waiting", "aborting", "stopped"}]
    /\ \A i \in 1..Len(log) : log[i] \in Timeouts

\* The listeners of an earlier timeout with the same or a shorter time run
\* first.
InSequence ==
    \A i, j \in 1..Len(log) :
       (log[j] < log[i] /\ time[log[j]] <= time[log[i]]) => j < i

\* Each timeout whose time is complete aborts its signal: no wait has no
\* end.
Aborts == \A t \in Timeouts : state[t] = "waiting" ~> state[t] = "stopped"
=============================================================================
