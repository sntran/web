--------------------------- MODULE StreamLifetime ---------------------------
(* The lifetime of one readable stream of Web.Stream.                       *)
(*                                                                          *)
(* A stream is a process. The module shows when the stream stops, and that  *)
(* it does not stop while a process uses it.                                *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design. The tests use those values to make sure that the     *)
(* properties find a design that is not correct.                            *)
(*                                                                          *)
(* The module has no clock. A timer step can occur at each moment when it   *)
(* is possible. Thus the module includes an owner that stops normally, for  *)
(* which the stream waits for the linger time, and an owner that stops with *)
(* a failure, for which the stream does not wait.                           *)
(*                                                                          *)
(* The writer lock of a pipe is not in this module. Such a lock does not    *)
(* keep a stream, thus it does not change these rules.                      *)
EXTENDS Naturals

CONSTANTS
    Procs,         \* the processes that can use the stream
    Owner,         \* the process that made the stream; an element of Procs
    MaxQueue,      \* the largest number of chunks in the queue
    UnreadLimit,   \* TRUE when the stream has the option :unread_timeout
    Bug            \* "none", or the name of a rule to remove

VARIABLES
    phase,      \* "active", "closed", or "errored"
    queue,      \* the number of chunks that are not read
    lock,       \* the process that holds the reader lock, or "none"
    live,       \* the processes that are alive
    running,    \* TRUE while the process of the stream is alive
    disturbed   \* TRUE after the first read or cancel

vars == <<phase, queue, lock, live, running, disturbed>>

Init ==
    /\ phase = "active"
    /\ queue = 0
    /\ lock = "none"
    /\ live = Procs
    /\ running = TRUE
    /\ disturbed = FALSE

Ended == phase \in {"closed", "errored"}

\* The stream has no more data for a reader. No process can read the chunks
\* of an errored stream.
Complete == Ended /\ (queue = 0 \/ phase = "errored")

\* The condition that the stream uses to stop.
MayStop ==
    IF Bug = "errored_keeps_chunks" THEN Ended /\ queue = 0 ELSE Complete

\* The source gives a chunk.
Enqueue ==
    /\ running /\ phase = "active" /\ queue < MaxQueue
    /\ queue' = queue + 1
    /\ UNCHANGED <<phase, lock, live, running, disturbed>>

\* The source closes the stream.
Close ==
    /\ running /\ phase = "active"
    /\ phase' = "closed"
    /\ UNCHANGED <<queue, lock, live, running, disturbed>>

\* The source puts the stream in the errored state. A process that holds the
\* lock keeps it, as the Streams Standard specifies, but it cannot read. The
\* error discards the chunks. A stream that closed with chunks in its queue
\* can still get an error: in the Standard it is readable until a read takes
\* the last chunk.
Fail ==
    /\ running /\ (phase = "active" \/ (phase = "closed" /\ queue > 0))
    /\ phase' = "errored"
    /\ queue' = IF Bug = "errored_keeps_chunks" THEN queue ELSE 0
    /\ UNCHANGED <<lock, live, running, disturbed>>

\* Process p takes the reader lock.
Lock(p) ==
    /\ running /\ p \in live /\ lock = "none"
    /\ lock' = p
    /\ UNCHANGED <<phase, queue, live, running, disturbed>>

\* Process p releases the reader lock.
Unlock(p) ==
    /\ running /\ lock = p
    /\ lock' = "none"
    /\ UNCHANGED <<phase, queue, live, running, disturbed>>

\* Process p reads one chunk.
Read(p) ==
    /\ running /\ lock = p /\ phase # "errored" /\ queue > 0
    /\ queue' = queue - 1
    /\ disturbed' = TRUE
    /\ UNCHANGED <<phase, lock, live, running>>

\* Process p cancels the stream. A halt of an enumeration is a cancel. A
\* cancel does not release the lock, as the Streams Standard specifies.
Cancel(p) ==
    /\ running /\ p \in live /\ lock \in {"none", p} /\ ~Ended
    /\ phase' = "closed"
    /\ queue' = 0
    /\ disturbed' = TRUE
    /\ UNCHANGED <<lock, live, running>>

\* Process p stops. A lock that it holds is released.
ProcStop(p) ==
    /\ p \in live
    /\ live' = live \ {p}
    /\ lock' = IF lock = p THEN "none" ELSE lock
    /\ UNCHANGED <<phase, queue, running, disturbed>>

\* The linger time of a complete stream is complete. A lock has no effect,
\* because the stream has no more data for the process that holds it.
StopComplete ==
    /\ running /\ MayStop
    /\ running' = FALSE
    /\ lock' = "none"
    /\ UNCHANGED <<phase, queue, live, disturbed>>

\* The owner stopped, and no process took the lock in the linger time. The
\* stream cancels, and it discards its chunks.
OwnerDownExpire ==
    /\ running /\ ~MayStop
    /\ Owner \notin live
    /\ Bug # "no_owner_rule"
    /\ lock = "none" \/ Bug = "owner_rule_ignores_lock"
    /\ phase' = IF Ended THEN phase ELSE "closed"
    /\ queue' = 0
    /\ lock' = "none"
    /\ UNCHANGED <<live, running, disturbed>>

\* The option :unread_timeout: no process started to read the stream in the
\* given time. A stream that has work goes to the errored state. A closed
\* stream discards its chunks.
UnreadExpire ==
    /\ UnreadLimit
    /\ running /\ ~disturbed /\ lock = "none" /\ phase # "errored"
    /\ IF phase = "active"
          THEN phase' = "errored" /\ queue' = IF Bug = "errored_keeps_chunks" THEN queue ELSE 0
          ELSE queue' = 0 /\ UNCHANGED phase
    /\ disturbed' = TRUE
    /\ UNCHANGED <<lock, live, running>>

Next ==
    \/ Enqueue \/ Close \/ Fail
    \/ \E p \in Procs : Lock(p) \/ Unlock(p) \/ Read(p) \/ Cancel(p) \/ ProcStop(p)
    \/ StopComplete \/ OwnerDownExpire \/ UnreadExpire
    \/ (~running /\ UNCHANGED vars)

Fairness ==
    /\ WF_vars(StopComplete)
    /\ WF_vars(OwnerDownExpire)
    /\ WF_vars(UnreadExpire)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ phase \in {"active", "closed", "errored"}
    /\ queue \in 0..MaxQueue
    /\ lock \in Procs \cup {"none"}
    /\ live \subseteq Procs
    /\ running \in BOOLEAN
    /\ disturbed \in BOOLEAN

\* Only a process that is alive holds the lock, and only on a stream that
\* runs.
LockIsValid == lock # "none" => lock \in live /\ running

\* The owner rule does not discard chunks while a process holds the lock.
\* Thus a process that got the stream in a message, and that took the lock,
\* can read all the chunks after the owner stopped.
LockStopsOwnerRule == [][OwnerDownExpire => lock = "none"]_vars

\* A stream that is not complete does not stop. A stream stops only through
\* its lifetime rules.
StopsOnlyWhenComplete == [][(running /\ ~running') => Complete]_vars

\* Without the option :unread_timeout, the chunks that are not read stay
\* available while the owner is alive.
KeptForOwner ==
    (~UnreadLimit /\ Owner \in live /\ phase = "closed" /\ queue > 0) => running

\* A stream that stopped does not start again.
StaysStopped == [][~running => ~running']_vars

\* A complete stream stops. Thus a process that stays alive does not keep
\* each stream that it read to the end, and an errored stream stops also
\* with chunks in its queue.
CompleteStops == Complete ~> ~running

\* A stream does not continue after all the processes that can use it.
NoOrphan == (live = {}) ~> ~running

\* With the option :unread_timeout, a stream that no process touches does
\* not stay: it stops, or a process starts to use it.
UnreadStops ==
    UnreadLimit => ((~disturbed /\ lock = "none") ~> (~running \/ disturbed \/ lock # "none"))
=============================================================================
