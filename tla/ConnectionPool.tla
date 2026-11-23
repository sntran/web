--------------------------- MODULE ConnectionPool ---------------------------
(* The pool of the HTTP connections of one origin: see                    *)
(* Web.Dispatcher.HTTP.Pool.                                               *)
(*                                                                          *)
(* A process of a request asks for a connection. The pool gives an idle     *)
(* connection, or a slot: the process then opens a new connection itself.   *)
(* When the pool has no free connection and no free slot, the process waits *)
(* in a queue. At the end of its response, the process gives back its       *)
(* connection, or only its slot when its connection closed. The pool gives  *)
(* each connection and slot that comes back to the first process in the     *)
(* queue. A process that waits can stop its wait, and a process can stop at *)
(* each time: the pool monitors it. The server can close an idle            *)
(* connection.                                                              *)
(*                                                                          *)
(* The module shows that the pool never has more than Size connections and  *)
(* slots, that its slots are the slots of the processes, that a process     *)
(* waits only when all of them are in use, and that each process that waits *)
(* gets a connection or a slot.                                             *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design.                                                      *)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Procs,   \* the processes of the requests
    Size,    \* the number of connections and slots of the origin
    Bug      \* "none", or the name of a rule to remove

VARIABLES
    idle,    \* the number of idle connections in the pool
    slots,   \* the processes that have a connection or a slot, for the pool
    queue,   \* the processes that wait, in their sequence
    holder   \* for each process: "none", "waiting", "conn", or "slot"

vars == <<idle, slots, queue, holder>>

Init ==
    /\ idle = 0
    /\ slots = {}
    /\ queue = <<>>
    /\ holder = [p \in Procs |-> "none"]

Borrowers == {p \in Procs : holder[p] \in {"conn", "slot"}}

Waiting == {p \in Procs : holder[p] = "waiting"}

InQueue(p) == \E i \in 1..Len(queue) : queue[i] = p

Without(p) == SelectSeq(queue, LAMBDA q : q # p)

\* A process asks for a connection: an idle connection, else a slot, else
\* the process waits.
Checkout(p) ==
    /\ holder[p] = "none"
    /\ IF idle > 0
       THEN /\ idle' = idle - 1
            /\ slots' = slots \cup {p}
            /\ holder' = [holder EXCEPT ![p] = "conn"]
            /\ UNCHANGED queue
       ELSE IF Cardinality(slots) < Size \/ Bug = "no_limit"
       THEN /\ slots' = slots \cup {p}
            /\ holder' = [holder EXCEPT ![p] = "slot"]
            /\ UNCHANGED <<idle, queue>>
       ELSE /\ queue' = Append(queue, p)
            /\ holder' = [holder EXCEPT ![p] = "waiting"]
            /\ UNCHANGED <<idle, slots>>

\* The process gives back its connection. The first process of the queue
\* gets it, else it is idle.
Return(p) ==
    /\ holder[p] \in {"conn", "slot"}
    /\ IF queue # <<>> /\ Bug # "serve_ignored"
       THEN /\ slots' = (slots \ {p}) \cup {Head(queue)}
            /\ holder' = [holder EXCEPT ![p] = "none", ![Head(queue)] = "conn"]
            /\ queue' = Tail(queue)
            /\ UNCHANGED idle
       ELSE /\ slots' = slots \ {p}
            /\ holder' = [holder EXCEPT ![p] = "none"]
            /\ idle' = idle + 1
            /\ UNCHANGED queue

\* The slot of a process is free. The first process of the queue gets it.
FreeSlot(p, h) ==
    IF queue # <<>>
    THEN /\ slots' = (slots \ {p}) \cup {Head(queue)}
         /\ holder' = [h EXCEPT ![p] = "none", ![Head(queue)] = "slot"]
         /\ queue' = Tail(queue)
    ELSE /\ slots' = slots \ {p}
         /\ holder' = [h EXCEPT ![p] = "none"]
         /\ UNCHANGED queue

\* The connection of the process closed: it gives back only its slot.
Release(p) ==
    /\ holder[p] \in {"conn", "slot"}
    /\ FreeSlot(p, holder)
    /\ UNCHANGED idle

\* A process that waits stops its wait, for example at an abort.
Cancel(p) ==
    /\ holder[p] = "waiting"
    /\ queue' = Without(p)
    /\ holder' = [holder EXCEPT ![p] = "none"]
    /\ UNCHANGED <<idle, slots>>

\* A process stops with no message. Its socket closes with it, and the pool
\* gets the stop from its monitor. A new process can take the name later.
Stop(p) ==
    /\ holder[p] # "none"
    /\ IF holder[p] = "waiting"
       THEN /\ queue' = Without(p)
            /\ holder' = [holder EXCEPT ![p] = "none"]
            /\ UNCHANGED <<idle, slots>>
       ELSE IF Bug = "no_down_cleanup"
       THEN /\ holder' = [holder EXCEPT ![p] = "none"]
            /\ UNCHANGED <<idle, slots, queue>>
       ELSE /\ FreeSlot(p, holder)
            /\ UNCHANGED idle

\* The server closes an idle connection. The pool sees it and removes it.
ServerClose ==
    /\ idle > 0
    /\ idle' = idle - 1
    /\ UNCHANGED <<slots, queue, holder>>

Next ==
    \/ \E p \in Procs : Checkout(p) \/ Return(p) \/ Release(p) \/ Cancel(p) \/ Stop(p)
    \/ ServerClose

\* Each process that has a connection or a slot gives it back some time.
Fairness == \A p \in Procs : WF_vars(Return(p) \/ Release(p))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ idle \in 0..Cardinality(Procs)
    /\ slots \subseteq Procs
    /\ holder \in [Procs -> {"none", "waiting", "conn", "slot"}]

\* The pool never has more connections and slots than its size.
SlotsBounded == idle + Cardinality(slots) <= Size

\* The slots of the pool are the slots that the processes have: a process
\* that stopped gave its slot back.
SlotsMatch == slots = Borrowers

\* The queue has each process that waits, one time.
QueueMatch ==
    /\ {queue[i] : i \in 1..Len(queue)} = Waiting
    /\ Len(queue) = Cardinality(Waiting)

\* A process waits only when no connection and no slot is free.
WaitOnlyWhenFull == queue # <<>> => (idle = 0 /\ Cardinality(slots) = Size)

\* Each process that waits gets a connection or a slot, or stops its wait.
WaitersServed == \A p \in Procs : (holder[p] = "waiting") ~> (holder[p] # "waiting")
=============================================================================
