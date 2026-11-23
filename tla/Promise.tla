------------------------------- MODULE Promise -------------------------------
(* The lifetime of one pending promise of Web.Promise.                      *)
(*                                                                          *)
(* A pending promise is a process. The clients are the processes that       *)
(* await it. The module shows when a client gets the outcome, and when the  *)
(* process of the promise stops.                                            *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design. The tests use those values to make sure that the     *)
(* properties find a design that is not correct.                            *)

CONSTANTS
    Clients,    \* the processes that await the promise
    Bug         \* "none", or the name of a rule to remove

VARIABLES
    status,       \* "pending", "fulfilled", or "rejected"
    alive,        \* TRUE while the process of the promise is alive
    owner_alive,  \* TRUE while the owner of the promise is alive
    waiting,      \* the clients that wait for the outcome
    seen,         \* seen[c] is the result of the last await of client c
    delivered     \* TRUE after the first delivery of the outcome

vars == <<status, alive, owner_alive, waiting, seen, delivered>>

Outcomes == {"fulfilled", "rejected"}

Init ==
    /\ status = "pending"
    /\ alive = TRUE
    /\ owner_alive = TRUE
    /\ waiting = {}
    /\ seen = [c \in Clients |-> "none"]
    /\ delivered = FALSE

\* The executor, or a different process, settles the promise. Each client
\* that waits gets the outcome.
Settle(o) ==
    /\ alive
    /\ status = "pending"
    /\ status' = o
    /\ seen' = [c \in Clients |-> IF c \in waiting THEN o ELSE seen[c]]
    /\ waiting' = {}
    /\ delivered' = (waiting # {})
    /\ UNCHANGED <<alive, owner_alive>>

\* A settlement after the first one has no effect. A settlement of a promise
\* that stopped has no effect.
SettleAgain(o) ==
    /\ \/ status # "pending"
       \/ ~alive
    /\ IF Bug = "settle_two_times" /\ alive
          THEN status' = o /\ UNCHANGED <<alive, owner_alive, waiting, seen, delivered>>
          ELSE UNCHANGED vars

\* Client c awaits the promise.
Await(c) ==
    /\ c \notin waiting
    /\ \/ /\ ~alive
          /\ seen' = [seen EXCEPT ![c] = "released"]
          /\ UNCHANGED <<status, alive, owner_alive, waiting, delivered>>
       \/ /\ alive
          /\ status = "pending"
          /\ waiting' = waiting \cup {c}
          /\ UNCHANGED <<status, alive, owner_alive, seen, delivered>>
       \/ /\ alive
          /\ status \in Outcomes
          /\ seen' = [seen EXCEPT ![c] = status]
          /\ delivered' = TRUE
          /\ UNCHANGED <<status, alive, owner_alive, waiting>>

\* The owner stops. The promise stops with it. Each client that waits sees
\* that the promise stopped.
OwnerStop ==
    /\ owner_alive
    /\ owner_alive' = FALSE
    /\ alive' = FALSE
    /\ IF Bug = "owner_stop_keeps_waiters"
          THEN UNCHANGED <<waiting, seen>>
          ELSE /\ seen' = [c \in Clients |-> IF c \in waiting THEN "released" ELSE seen[c]]
               /\ waiting' = {}
    /\ UNCHANGED <<status, delivered>>

\* The linger time is complete. It starts at the first delivery.
Expire ==
    /\ alive
    /\ status \in Outcomes
    /\ delivered \/ Bug = "expire_before_delivery"
    /\ alive' = FALSE
    /\ UNCHANGED <<status, owner_alive, waiting, seen, delivered>>

Next ==
    \/ \E o \in Outcomes : Settle(o) \/ SettleAgain(o)
    \/ \E c \in Clients : Await(c)
    \/ OwnerStop
    \/ Expire

Spec == Init /\ [][Next]_vars /\ WF_vars(Expire)

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ status \in {"pending"} \cup Outcomes
    /\ alive \in BOOLEAN
    /\ owner_alive \in BOOLEAN
    /\ waiting \subseteq Clients
    /\ seen \in [Clients -> {"none", "released"} \cup Outcomes]
    /\ delivered \in BOOLEAN

\* A client waits only for a promise that is alive and pending. Thus no
\* client waits with no end for a promise that stopped or settled.
NoLostWaiter == waiting # {} => alive /\ status = "pending"

\* Each client that got an outcome got the outcome of the promise. Thus two
\* clients cannot get different outcomes.
Agreement == \A c \in Clients : seen[c] \in Outcomes => seen[c] = status

\* An outcome that no client got stays available while the owner is alive.
KeptForOwner == (status \in Outcomes /\ ~delivered /\ owner_alive) => alive

\* A promise does not continue after its owner.
StopsWithOwner == ~owner_alive => ~alive

\* A promise settles one time only.
SettleOnce == [][status \in Outcomes => status' = status]_vars

\* A promise that stopped does not start again.
StaysStopped == [][~alive => ~alive']_vars

\* After the first delivery, the promise stops. Thus a process that stays
\* alive does not keep each promise that it awaited.
NoLeak == delivered ~> ~alive
=============================================================================
