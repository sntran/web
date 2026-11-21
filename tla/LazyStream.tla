----------------------------- MODULE LazyStream -----------------------------
(* The shared state of the copies of one Web.Internal.LazyStream.          *)
(*                                                                          *)
(* A body that has all its bytes has no process until a stream read. Each  *)
(* copy of the struct can be in a different process, and all the copies    *)
(* share one state: one element of an :atomics array, the cell. A copy on   *)
(* a different node does each operation on the node of the array, thus it   *)
(* is one more copy of this module.                                        *)
(*                                                                          *)
(* The operations of a copy:                                               *)
(*   * a claim changes "readable" to "consumed" (an enumeration takes the   *)
(*     bytes), to "locked" (a body function, a tee, or a proxy takes the    *)
(*     bytes, and keeps the lock), or to "canceled" (a cancel), with one    *)
(*     compare-exchange. The bytes go out only at a claim that changes     *)
(*     "readable";                                                         *)
(*   * a stream read changes "readable", "consumed", or "canceled" to      *)
(*     "starting" with one compare-exchange, starts the stream process,    *)
(*     which registers itself, and then sets "process". The stream process *)
(*     gets the bytes only from "readable": else it is a closed stream;    *)
(*   * a copy that finds "starting" waits until it finds "process";        *)
(*   * a copy that finds "process" looks for the stream process in the     *)
(*     registry. The registry has no stream process after it stopped:      *)
(*     the copy gets "gone".                                               *)
(*                                                                          *)
(* The model has no process that stops in the middle of a stream read. The  *)
(* real copies wait for the state "process" some seconds at most, and then  *)
(* they get "gone".                                                        *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design.                                                     *)
EXTENDS Naturals

CONSTANTS
    Copies,  \* the processes that have a copy of the struct
    Bug      \* "none", or the name of a rule to remove

Claims == {"consumed", "canceled", "locked"}

States == {"readable", "consumed", "canceled", "locked", "starting", "process"}

Results == {"none", "ok", "consumed", "canceled", "locked", "process", "gone", "readable"}

VARIABLES
    cell,        \* the state in the :atomics array
    pc,          \* [Copies -> step]: "idle", "check", "start", "publish", or "register"
    target,      \* [Copies -> Claims]: the claim of the bug "read_then_set"
    kind,        \* [Copies -> {"none", "bytes", "closed"}]: the stream that a copy starts
    streams,     \* the number of stream processes that started
    registered,  \* TRUE while the registry has the stream process
    stopped,     \* TRUE after the stream process stopped
    given,       \* the number of times that the bytes went out
    result       \* [Copies -> Results]: the result of the last operation

vars == <<cell, pc, target, kind, streams, registered, stopped, given, result>>

Init ==
    /\ cell = "readable"
    /\ pc = [c \in Copies |-> "idle"]
    /\ target = [c \in Copies |-> "locked"]
    /\ kind = [c \in Copies |-> "none"]
    /\ streams = 0 /\ registered = FALSE /\ stopped = FALSE
    /\ given = 0
    /\ result = [c \in Copies |-> "none"]

\* The state that a copy finds in a cell that is not "starting". For
\* "process", the copy looks in the registry.
Found == IF cell = "process"
         THEN IF registered THEN "process" ELSE "gone"
         ELSE cell

\* Copy c claims the bytes, or cancels. The claim and its result are one
\* compare-exchange. The bug "read_then_set" reads the cell, and sets it in
\* a second step.
Claim(c, to) ==
    /\ pc[c] = "idle" /\ cell # "starting"
    /\ IF cell = "readable"
       THEN IF Bug = "read_then_set"
            THEN /\ pc' = [pc EXCEPT ![c] = "check"]
                 /\ target' = [target EXCEPT ![c] = to]
                 /\ UNCHANGED <<cell, given, result>>
            ELSE /\ cell' = to
                 /\ given' = IF to = "canceled" THEN given ELSE given + 1
                 /\ result' = [result EXCEPT ![c] = "ok"]
                 /\ UNCHANGED <<pc, target>>
       ELSE /\ result' = [result EXCEPT ![c] = Found]
            /\ UNCHANGED <<cell, pc, target, given>>
    /\ UNCHANGED <<kind, streams, registered, stopped>>

\* The second step of the bug "read_then_set".
ClaimSet(c) ==
    /\ pc[c] = "check"
    /\ cell' = target[c]
    /\ given' = IF target[c] = "canceled" THEN given ELSE given + 1
    /\ result' = [result EXCEPT ![c] = "ok"]
    /\ pc' = [pc EXCEPT ![c] = "idle"]
    /\ UNCHANGED <<target, kind, streams, registered, stopped>>

\* Copy c starts a stream read. One compare-exchange changes "readable",
\* "consumed", or "canceled" to "starting". The stream process gets the bytes
\* only from "readable". The bug "no_starting" does not set "starting". The
\* bug "closed_gets_bytes" gives the bytes also to a stream after a claim.
Begin(c) ==
    /\ pc[c] = "idle" /\ cell # "starting"
    /\ IF cell \in {"readable", "consumed", "canceled"}
       THEN LET bytes == cell = "readable" \/ Bug = "closed_gets_bytes"
            IN /\ cell' = IF Bug = "no_starting" THEN cell ELSE "starting"
               /\ pc' = [pc EXCEPT ![c] = "start"]
               /\ kind' = [kind EXCEPT ![c] = IF bytes THEN "bytes" ELSE "closed"]
               /\ given' = IF bytes THEN given + 1 ELSE given
               /\ UNCHANGED result
       ELSE /\ result' = [result EXCEPT ![c] = Found]
            /\ UNCHANGED <<cell, pc, kind, given>>
    /\ UNCHANGED <<target, streams, registered, stopped>>

\* The stream process starts and registers itself. The bug "publish_first"
\* sets "process" before the stream process registers itself.
Start(c) ==
    /\ pc[c] = "start"
    /\ IF Bug = "publish_first"
       THEN /\ cell' = "process"
            /\ pc' = [pc EXCEPT ![c] = "register"]
            /\ UNCHANGED <<streams, registered>>
       ELSE /\ streams' = streams + 1 /\ registered' = TRUE
            /\ pc' = [pc EXCEPT ![c] = "publish"]
            /\ UNCHANGED cell
    /\ UNCHANGED <<target, kind, stopped, given, result>>

\* Copy c sets "process": the copies that wait find the stream process.
Publish(c) ==
    /\ pc[c] = "publish"
    /\ cell' = "process"
    /\ pc' = [pc EXCEPT ![c] = "idle"]
    /\ result' = [result EXCEPT ![c] = "process"]
    /\ UNCHANGED <<target, kind, streams, registered, stopped, given>>

\* The second step of the bug "publish_first".
Register(c) ==
    /\ pc[c] = "register"
    /\ streams' = streams + 1 /\ registered' = TRUE
    /\ pc' = [pc EXCEPT ![c] = "idle"]
    /\ result' = [result EXCEPT ![c] = "process"]
    /\ UNCHANGED <<cell, target, kind, stopped, given>>

\* Copy c reads the state. A copy that finds "starting" waits.
State(c) ==
    /\ pc[c] = "idle" /\ cell # "starting"
    /\ result' = [result EXCEPT ![c] = Found]
    /\ UNCHANGED <<cell, pc, target, kind, streams, registered, stopped, given>>

\* The stream process stops, for example at the end of its linger time. The
\* registry removes its key.
StreamStop ==
    /\ registered
    /\ registered' = FALSE /\ stopped' = TRUE
    /\ UNCHANGED <<cell, pc, target, kind, streams, given, result>>

Next ==
    \/ \E c \in Copies :
        \/ \E to \in Claims : Claim(c, to)
        \/ ClaimSet(c) \/ Begin(c) \/ Start(c) \/ Publish(c) \/ Register(c) \/ State(c)
    \/ StreamStop
    \/ UNCHANGED vars

\* A copy that started an operation completes it.
Spec ==
    /\ Init /\ [][Next]_vars
    /\ \A c \in Copies :
        WF_vars(ClaimSet(c)) /\ WF_vars(Start(c)) /\ WF_vars(Publish(c)) /\ WF_vars(Register(c))

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ cell \in States
    /\ \A c \in Copies :
        /\ pc[c] \in {"idle", "check", "start", "publish", "register"}
        /\ target[c] \in Claims
        /\ kind[c] \in {"none", "bytes", "closed"}
        /\ result[c] \in Results
    /\ streams \in 0..2 /\ registered \in BOOLEAN /\ stopped \in BOOLEAN
    /\ given \in 0..3

\* The bytes go out one time at most: to one body function, enumeration, tee,
\* proxy, or stream process.
BytesOnce == given <= 1

\* No copy takes the bytes after a claim or a stream read used them.
NoBytesAfterUse == [][given' > given => cell = "readable"]_vars

\* One stream process at most, for all the copies.
OneProcess == streams <= 1

\* A copy gets "gone" only after the stream process stopped.
GoneOnlyAfterStop == \A c \in Copies : result[c] = "gone" => stopped

\* A copy that waits for "starting" finds "process".
StartEnds == (cell = "starting") ~> (cell = "process")
=============================================================================
