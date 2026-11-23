------------------------- MODULE PerformanceObserver -------------------------
(* One observer of Web.PerformanceObserver, and the processes that it       *)
(* observes.                                                                *)
(*                                                                          *)
(* The entries of Web.Performance are the state of the process that makes   *)
(* them. A process that called observe sends each of its later entries to  *)
(* the server of the observer, and does not wait ("queue a                  *)
(* PerformanceEntry"). The server keeps the options of each observed       *)
(* process, and adds an entry to the observer buffer only when the options *)
(* of its process have its type. Then the server sends one task to the      *)
(* callback process, and sets the flag "task queued" ("queue the            *)
(* PerformanceObserver task"). The task takes the observer buffer from the  *)
(* server when it runs, and the callback gets the entries.                  *)
(*                                                                          *)
(* The messages from one process arrive in their sequence. Thus the server  *)
(* gets the entries of a process before each later call of that process.   *)
(*                                                                          *)
(* The owner made the observer. The server stops when the owner stops. The  *)
(* server monitors each observed process, and removes its options when it   *)
(* stops.                                                                   *)
(*                                                                          *)
(* Each entry that the server adds to the buffer is a copy. A copy goes to  *)
(* a callback, to take_records, or a disconnect or the stop of the server  *)
(* drops it. The module counts the copies of each place.                   *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design.                                                      *)
EXTENDS Naturals, Sequences

CONSTANTS
    Procs,        \* the processes that call the functions
    Types,        \* the entry types
    MaxEntries,   \* the largest number of entries that one process makes
    MaxObserves,  \* the largest number of calls of observe
    Bug           \* "none", or the name of a rule to remove

VARIABLES
    alive,       \* alive[p] is TRUE while process p runs
    timeline,    \* timeline[p] is the sequence of the types of the entries
                 \* of process p: its performance entry buffer
    listed,      \* listed[p] is TRUE when process p sends its entries to
                 \* the observer
    wire,        \* wire[p] is the sequence of the entries of process p on
                 \* their way to the server
    owner,       \* TRUE while the owner of the observer runs
    server,      \* TRUE while the server of the observer runs
    registered,  \* registered[p] is the set of the types that the options
                 \* of process p have
    buffer,      \* the observer buffer: a sequence of copies
    pending,     \* the copies that a task carries. The design has none
    queued,      \* the flag "task queued"
    tasks,       \* the number of tasks in the mailbox of the callback
                 \* process
    requires,    \* the flag "requires dropped entries"
    since,       \* TRUE when a call of observe came after the last callback
    observes,    \* the number of calls of observe
    copies,      \* the number of copies that the server made
    called,      \* the number of copies that a callback got
    taken,       \* the number of copies that take_records returned
    dropped,     \* the number of copies that a disconnect or the stop of
                 \* the server dropped
    last         \* the name of the last step when a property examines
                 \* it, else "other"

vars == <<alive, timeline, listed, wire, owner, server, registered, buffer,
          pending, queued, tasks, requires, since, observes, copies, called,
          taken, dropped, last>>

Entry(p, n, t) == [proc |-> p, n |-> n, type |-> t]

\* The flag observed of a copy is TRUE when the options of the process had
\* the type of the entry when the server made the copy.
Copy(e, observed) == [proc |-> e.proc, n |-> e.n, type |-> e.type, observed |-> observed]

Init ==
    /\ alive = [p \in Procs |-> TRUE]
    /\ timeline = [p \in Procs |-> <<>>]
    /\ listed = [p \in Procs |-> FALSE]
    /\ wire = [p \in Procs |-> <<>>]
    /\ owner = TRUE
    /\ server = TRUE
    /\ registered = [p \in Procs |-> {}]
    /\ buffer = <<>>
    /\ pending = <<>>
    /\ queued = FALSE
    /\ tasks = 0
    /\ requires = FALSE
    /\ since = FALSE
    /\ observes = 0
    /\ copies = 0
    /\ called = 0
    /\ taken = 0
    /\ dropped = 0
    /\ last = "none"

\* The steps "queue the PerformanceObserver task": one task, when the flag
\* is not set.
QueueTask ==
    IF queued /\ Bug # "no_flag"
    THEN UNCHANGED <<queued, tasks>>
    ELSE /\ queued' = TRUE
         /\ tasks' = tasks + 1

\* The server adds copies to the observer buffer. With the Bug
\* "take_at_queue", the task takes the copies when the server sends it.
Store(new) ==
    /\ copies' = copies + Len(new)
    /\ IF Bug = "take_at_queue"
       THEN /\ pending' = pending \o new
            /\ UNCHANGED buffer
       ELSE /\ buffer' = buffer \o new
            /\ UNCHANGED pending

\* The process that calls a function: its earlier entries arrive at the
\* server before the call.
Ready(p) == alive[p] /\ wire[p] = <<>>

-----------------------------------------------------------------------------
\* The calls of the processes

\* Process p makes an entry of type t: a mark or a measure. When the process
\* lists the observer, the entry goes to the server.
Make(p, t) ==
    /\ alive[p] /\ t \in Types /\ Len(timeline[p]) < MaxEntries
    /\ timeline' = [timeline EXCEPT ![p] = Append(@, t)]
    /\ wire' = IF listed[p]
               THEN [wire EXCEPT ![p] = Append(@, Entry(p, Len(timeline[p]) + 1, t))]
               ELSE wire
    /\ last' = "other"
    /\ UNCHANGED <<alive, listed, owner, server, registered, buffer, pending,
                   queued, tasks, requires, since, observes, copies, called,
                   taken, dropped>>

\* The entries of process p with type t, in the sequence of the timeline.
EntriesOf(p) == [i \in 1..Len(timeline[p]) |-> Entry(p, i, timeline[p][i])]
Buffered(p, t) ==
    LET old == SelectSeq(EntriesOf(p), LAMBDA e : e.type = t)
    IN  [i \in 1..Len(old) |-> Copy(old[i], TRUE)]

\* Process p calls observe with the type t, and with the flag buffered b.
\* The options of each call add their type. With the flag buffered, the
\* entries of that type that the process made go to the buffer, and the
\* observer queues the task.
Observe(p, t, b) ==
    /\ Ready(p) /\ server /\ t \in Types /\ b \in BOOLEAN
    /\ observes < MaxObserves
    /\ observes' = observes + 1
    /\ registered' = [registered EXCEPT ![p] = @ \cup {t}]
    /\ listed' = [listed EXCEPT ![p] = TRUE]
    /\ requires' = TRUE
    /\ since' = TRUE
    /\ IF b
       THEN Store(Buffered(p, t)) /\ QueueTask
       ELSE UNCHANGED <<buffer, pending, copies, queued, tasks>>
    /\ last' = "other"
    /\ UNCHANGED <<alive, timeline, wire, owner, server, called, taken, dropped>>

\* take_records returns the buffer, and empties it.
TakeRecords(p) ==
    /\ Ready(p) /\ server
    /\ buffer' = IF Bug = "take_keeps_buffer" THEN buffer ELSE <<>>
    /\ taken' = taken + Len(buffer)
    /\ last' = "take"
    /\ UNCHANGED <<alive, timeline, listed, wire, owner, server, registered,
                   pending, queued, tasks, requires, since, observes, copies,
                   called, dropped>>

\* disconnect removes the options of each process, and empties the buffer.
Disconnect(p) ==
    /\ Ready(p) /\ server
    /\ registered' = [q \in Procs |-> {}]
    /\ IF Bug = "disconnect_keeps_buffer"
       THEN UNCHANGED <<buffer, dropped>>
       ELSE /\ buffer' = <<>>
            /\ dropped' = dropped + Len(buffer)
    /\ last' = "disconnect"
    /\ UNCHANGED <<alive, timeline, listed, wire, owner, server, pending,
                   queued, tasks, requires, since, observes, copies, called,
                   taken>>

\* Process p stops. Its entries on the wire still arrive.
Stop(p) ==
    /\ alive[p]
    /\ alive' = [alive EXCEPT ![p] = FALSE]
    /\ last' = "other"
    /\ UNCHANGED <<timeline, listed, wire, owner, server, registered, buffer,
                   pending, queued, tasks, requires, since, observes, copies,
                   called, taken, dropped>>

\* The owner of the observer stops.
StopOwner ==
    /\ owner
    /\ owner' = FALSE
    /\ last' = "other"
    /\ UNCHANGED <<alive, timeline, listed, wire, server, registered, buffer,
                   pending, queued, tasks, requires, since, observes, copies,
                   called, taken, dropped>>

-----------------------------------------------------------------------------
\* The server

\* The server gets the next entry of process p. It makes a copy when the
\* options of the process have the type of the entry. A server that
\* stopped gets nothing.
Receive(p) ==
    /\ wire[p] # <<>>
    /\ wire' = [wire EXCEPT ![p] = Tail(@)]
    /\ LET e == Head(wire[p])
           observed == e.type \in registered[p]
       IN  IF server /\ (observed \/ Bug = "no_filter")
           THEN Store(<<Copy(e, observed)>>) /\ QueueTask
           ELSE UNCHANGED <<buffer, pending, copies, queued, tasks>>
    /\ last' = "other"
    /\ UNCHANGED <<alive, timeline, listed, owner, server, registered,
                   requires, since, observes, called, taken, dropped>>

\* The monitor of the server tells it that process p stopped, after the
\* entries of the process. The server removes the options of the process.
Down(p) ==
    /\ ~alive[p] /\ wire[p] = <<>> /\ server /\ registered[p] # {}
    /\ Bug # "no_monitor"
    /\ registered' = [registered EXCEPT ![p] = {}]
    /\ IF Bug = "down_drops_entries"
       THEN /\ buffer' = SelectSeq(buffer, LAMBDA c : c.proc # p)
            /\ dropped' = dropped + Len(SelectSeq(buffer, LAMBDA c : c.proc = p))
       ELSE UNCHANGED <<buffer, dropped>>
    /\ last' = "other"
    /\ UNCHANGED <<alive, timeline, listed, wire, owner, server, pending,
                   queued, tasks, requires, since, observes, copies, called,
                   taken>>

\* The server stops after its owner. The buffer is lost.
ServerStop ==
    /\ ~owner /\ server /\ Bug # "no_owner_monitor"
    /\ server' = FALSE
    /\ registered' = [p \in Procs |-> {}]
    /\ buffer' = <<>>
    /\ dropped' = dropped + Len(buffer)
    /\ queued' = FALSE
    /\ last' = "stop"
    /\ UNCHANGED <<alive, timeline, listed, wire, owner, pending, tasks,
                   requires, since, observes, copies, called, taken>>

-----------------------------------------------------------------------------
\* The callback process

\* The callback process takes a task. It asks the server for the buffer:
\* the server empties it, and sets the flag "task queued" down. With no
\* entry there is no callback. The first callback after a call of observe
\* has the option dropped_entries_count. When the server stopped, the
\* callback process drops the task.
Task ==
    /\ tasks > 0
    /\ tasks' = tasks - 1
    /\ IF ~server
       THEN /\ last' = "other"
            /\ UNCHANGED <<buffer, pending, queued, requires, since, called>>
       ELSE LET got == IF Bug = "take_at_queue" THEN pending ELSE buffer
            IN  /\ queued' = (Bug = "flag_stays")
                /\ buffer' = IF Bug = "take_at_queue" THEN buffer ELSE <<>>
                /\ pending' = <<>>
                /\ IF Len(got) > 0 \/ Bug = "empty_callback"
                   THEN /\ called' = called + Len(got)
                        /\ requires' = FALSE
                        /\ since' = FALSE
                        /\ last' = "callback"
                   ELSE /\ requires' = IF Bug = "empty_task_clears_count"
                                       THEN FALSE ELSE requires
                        /\ last' = "other"
                        /\ UNCHANGED <<called, since>>
    /\ UNCHANGED <<alive, timeline, listed, wire, owner, server, registered,
                   observes, copies, taken, dropped>>

-----------------------------------------------------------------------------

Next ==
    \/ \E p \in Procs : \E t \in Types : Make(p, t)
    \/ \E p \in Procs : \E t \in Types : \E b \in BOOLEAN : Observe(p, t, b)
    \/ \E p \in Procs : TakeRecords(p) \/ Disconnect(p) \/ Stop(p)
    \/ \E p \in Procs : Receive(p) \/ Down(p)
    \/ StopOwner \/ ServerStop \/ Task
    \* The system can stay as it is: no step is necessary.
    \/ UNCHANGED vars

Fairness ==
    /\ \A p \in Procs : WF_vars(Receive(p)) /\ WF_vars(Down(p))
    /\ WF_vars(ServerStop) /\ WF_vars(Task)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ alive \in [Procs -> BOOLEAN]
    /\ listed \in [Procs -> BOOLEAN]
    /\ registered \in [Procs -> SUBSET Types]
    /\ \A p \in Procs : Len(timeline[p]) <= MaxEntries
    /\ queued \in BOOLEAN /\ requires \in BOOLEAN /\ since \in BOOLEAN
    /\ observes \in 0..MaxObserves

\* Each copy is in one place: the buffer, a task, a callback, the result
\* of take_records, or the dropped copies.
EachCopyOnce == Len(buffer) + Len(pending) + called + taken + dropped = copies

\* The observer gets an entry only when the options of its process have
\* the type of the entry.
OnlyObservedEntries == \A i \in 1..Len(buffer) : buffer[i].observed

\* The mailbox of the callback process has one task or none.
OneTask == tasks <= 1

\* A callback gets at least one entry.
CallbackHasEntries == [][last' = "callback" => called' > called]_vars

\* The first callback after a call of observe has the option
\* dropped_entries_count, and the other callbacks do not have it.
CountAfterObserve == [][last' = "callback" => requires = since]_vars

\* take_records returns each copy that no callback got: after it, no copy
\* waits for a callback.
TakeRecordsTakesAll ==
    [][last' = "take" => Len(buffer') + Len(pending') = 0]_vars

\* After a disconnect, no copy waits for a callback.
NothingAfterDisconnect ==
    [][last' = "disconnect" => Len(buffer') + Len(pending') = 0]_vars

\* Only a disconnect and the stop of the server drop copies. The stop of
\* an observed process does not drop its entries.
DropReason == [][dropped' # dropped => last' \in {"disconnect", "stop"}]_vars

\* Each copy in the buffer goes out: the buffer becomes empty, or the
\* server stops.
Drains == []<>(buffer = <<>> \/ ~server)

\* The server forgets a process that stopped.
ForgetsStoppedProcess == \A p \in Procs : ~alive[p] ~> (registered[p] = {})

\* The observer stops after its owner.
StopsWithOwner == ~owner ~> ~server
=============================================================================
