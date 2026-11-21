------------------------- MODULE TransformLifetime -------------------------
(* The lifetime of the two sides of one Web.TransformStream.               *)
(*                                                                          *)
(* The two sides are two stream processes. For the lifetime rules of       *)
(* tla/StreamLifetime.tla they are one stream: a lock of one side keeps the *)
(* two sides. Each side keeps a copy of the lock of the other side. A side  *)
(* tells the other side each change of its own lock in a message, and it    *)
(* monitors the other side: the stop of the other side clears the copy.     *)
(*                                                                          *)
(* The readable side has the reader lock, and the writable side has the     *)
(* writer lock. The writer lock of a pipe is not a lock for these rules,    *)
(* thus it is not in this module.                                          *)
(*                                                                          *)
(* A side is "active", "unread" (the readable side is closed, and it has    *)
(* chunks that no process read), or "complete" (it has no more work). A     *)
(* complete side stops after its linger time, also with a lock. When the    *)
(* owner stopped, a side that is not complete, with no lock and no copy of  *)
(* a lock, ends: the readable side cancels, and the writable side aborts.   *)
(* Then the other side gets an error.                                       *)
(*                                                                          *)
(* Each side has one inbox for the messages of the other side: the lock     *)
(* messages, the error, and the monitor message of a stop. A process gets   *)
(* the messages of one process in their sequence. The worker of a side     *)
(* sends the error, thus that sequence is an approximation.                *)
(*                                                                          *)
(* The module has no clock: a timer step can occur at each moment when it   *)
(* is possible. Thus a change of a lock that is in a message can come after *)
(* the end of the linger time of the other side. The handoff time of an     *)
(* owner that stops normally makes this rare.                              *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design.                                                     *)
EXTENDS Naturals, Sequences

CONSTANTS
    Procs,     \* the processes that can use the stream
    Owner,     \* the process that made the stream; an element of Procs
    MaxInbox,  \* the lock messages in an inbox, at most
    Bug        \* "none", or the name of a rule to remove

Sides == {"readable", "writable"}

Other(s) == IF s = "readable" THEN "writable" ELSE "readable"

LockMessages == {"locked", "unlocked", "down"}

VARIABLES
    phase,    \* [Sides -> {"active", "unread", "complete"}]
    lock,     \* [Sides -> Procs \cup {"none"}]: the own lock of each side
    copy,     \* [Sides -> BOOLEAN]: the copy of the lock of the other side
    inbox,    \* [Sides -> Seq]: the messages from the other side
    running,  \* [Sides -> BOOLEAN]: the process of the side is alive
    live,     \* the processes that are alive
    expired   \* the sides that the owner rule ended

vars == <<phase, lock, copy, inbox, running, live, expired>>

Init ==
    /\ phase = [s \in Sides |-> "active"]
    /\ lock = [s \in Sides |-> "none"]
    /\ copy = [s \in Sides |-> FALSE]
    /\ inbox = [s \in Sides |-> <<>>]
    /\ running = [s \in Sides |-> TRUE]
    /\ live = Procs
    /\ expired = {}

\* Side s sends message m to the other side. A message to a process that
\* stopped has no effect.
Send(box, s, m) ==
    IF running[Other(s)] THEN [box EXCEPT ![Other(s)] = Append(@, m)] ELSE box

\* Side s tells a change of its own lock. The bug "no_notify" does not tell.
Tell(box, s, m) == IF Bug = "no_notify" THEN box ELSE Send(box, s, m)

\* The rule of the lock: the own lock, or the copy of the lock of the other
\* side. The bug "own_lock_only" ignores the copy.
Locked(s) == lock[s] # "none" \/ (copy[s] /\ Bug # "own_lock_only")

\* Process p takes the lock of side s.
Lock(p, s) ==
    /\ running[s] /\ p \in live /\ lock[s] = "none"
    /\ Len(inbox[Other(s)]) < MaxInbox
    /\ lock' = [lock EXCEPT ![s] = p]
    /\ inbox' = Tell(inbox, s, "locked")
    /\ UNCHANGED <<phase, copy, running, live, expired>>

\* Process p releases the lock of side s.
Unlock(p, s) ==
    /\ running[s] /\ lock[s] = p
    /\ Len(inbox[Other(s)]) < MaxInbox
    /\ lock' = [lock EXCEPT ![s] = "none"]
    /\ inbox' = Tell(inbox, s, "unlocked")
    /\ UNCHANGED <<phase, copy, running, live, expired>>

\* Process p stops. Each side that runs gets the monitor message of its lock
\* holder, releases the lock, and tells the other side.
ProcStop(p) ==
    /\ p \in live
    /\ live' = live \ {p}
    /\ lock' = [s \in Sides |-> IF lock[s] = p THEN "none" ELSE lock[s]]
    /\ LET Released(s) == lock[s] = p /\ running[s]
           AfterReadable == IF Released("readable")
                            THEN Tell(inbox, "readable", "unlocked") ELSE inbox
       IN inbox' = IF Released("writable")
                   THEN Tell(AfterReadable, "writable", "unlocked") ELSE AfterReadable
    /\ UNCHANGED <<phase, copy, running, expired>>

\* The writable side closes. The flush closes the readable side, which keeps
\* its chunks.
Close ==
    /\ running["readable"] /\ running["writable"]
    /\ phase["writable"] = "active" /\ phase["readable"] = "active"
    /\ phase' = [phase EXCEPT !["writable"] = "complete", !["readable"] = "unread"]
    /\ UNCHANGED <<lock, copy, inbox, running, live, expired>>

\* The process that holds the reader lock reads the last chunks.
ReadAll(p) ==
    /\ running["readable"] /\ lock["readable"] = p /\ phase["readable"] = "unread"
    /\ phase' = [phase EXCEPT !["readable"] = "complete"]
    /\ UNCHANGED <<lock, copy, inbox, running, live, expired>>

\* The owner stopped, and the linger time of side s is complete. A side with
\* no lock ends. It discards its chunks, and the other side gets an error.
\* The bug "no_owner_rule" never ends a side.
OwnerExpire(s) ==
    /\ running[s] /\ phase[s] # "complete" /\ Owner \notin live
    /\ ~Locked(s) /\ Bug # "no_owner_rule"
    /\ phase' = [phase EXCEPT ![s] = "complete"]
    /\ inbox' = Send(inbox, s, "error")
    /\ expired' = expired \cup {s}
    /\ UNCHANGED <<lock, copy, running, live>>

\* The linger time of a complete side is complete: the side stops. The other
\* side gets the monitor message. The bug "no_monitor" has no monitor.
StopComplete(s) ==
    /\ running[s] /\ phase[s] = "complete"
    /\ running' = [running EXCEPT ![s] = FALSE]
    /\ inbox' = [(IF Bug = "no_monitor" THEN inbox ELSE Send(inbox, s, "down"))
                    EXCEPT ![s] = <<>>]
    /\ UNCHANGED <<phase, lock, copy, live, expired>>

\* Side s gets the next message of the other side.
Deliver(s) ==
    /\ running[s] /\ inbox[s] # <<>>
    /\ LET m == Head(inbox[s])
       IN /\ copy' = [copy EXCEPT ![s] = IF m = "locked" THEN TRUE
                                         ELSE IF m = "error" THEN @ ELSE FALSE]
          /\ phase' = IF m = "error" THEN [phase EXCEPT ![s] = "complete"] ELSE phase
    /\ inbox' = [inbox EXCEPT ![s] = Tail(@)]
    /\ UNCHANGED <<lock, running, live, expired>>

Next ==
    \/ \E p \in Procs, s \in Sides : Lock(p, s) \/ Unlock(p, s)
    \/ \E p \in Procs : ProcStop(p) \/ ReadAll(p)
    \/ Close
    \/ \E s \in Sides : OwnerExpire(s) \/ StopComplete(s) \/ Deliver(s)
    \/ UNCHANGED vars

\* The timers and the messages of the two sides do their steps. The
\* processes do their steps when they want.
Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(OwnerExpire("readable")) /\ WF_vars(OwnerExpire("writable"))
    /\ WF_vars(StopComplete("readable")) /\ WF_vars(StopComplete("writable"))
    /\ WF_vars(Deliver("readable")) /\ WF_vars(Deliver("writable"))

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ \A s \in Sides :
        /\ phase[s] \in {"active", "unread", "complete"}
        /\ lock[s] \in Procs \cup {"none"}
        /\ copy[s] \in BOOLEAN
        /\ running[s] \in BOOLEAN
        /\ Len(inbox[s]) <= MaxInbox + 3
        /\ \A i \in 1..Len(inbox[s]) : inbox[s][i] \in LockMessages \cup {"error"}
    /\ phase["writable"] # "unread"
    /\ live \subseteq Procs
    /\ expired \subseteq Sides

\* With no lock message in its inbox, the copy of a side that runs is the
\* lock of the other side, and false when the other side stopped.
CopyAgrees ==
    \A s \in Sides :
        (running[s] /\ \A i \in 1..Len(inbox[s]) : inbox[s][i] = "error")
            => copy[s] = (running[Other(s)] /\ lock[Other(s)] # "none")

\* The owner rule ends a side only when the two sides have no lock that the
\* side knows. Only a change of the lock that is still in a message can be
\* late.
KeptByLock ==
    [][\A s \in Sides :
        (s \in expired' /\ s \notin expired)
            => /\ lock[s] = "none"
               /\ \/ lock[Other(s)] = "none"
                  \/ ~running[Other(s)]
                  \/ \E i \in 1..Len(inbox[s]) : inbox[s][i] \in LockMessages]_vars

\* The two sides do not continue after all the processes that can use them.
NoOrphan == (live = {}) ~> (\A s \in Sides : ~running[s])
=============================================================================
