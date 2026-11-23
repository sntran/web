------------------------- MODULE PerformanceObserver -------------------------
(* The timeline of one global object of Web.Performance, one observer of    *)
(* that global object, and its callback process.                            *)
(*                                                                          *)
(* A process is a global object. The first observer of a global object puts *)
(* its performance entry buffer in an ETS table of a server, the timeline   *)
(* server. Two processes act for the global object: the process of the      *)
(* global object, and the callback process, which runs the callbacks with   *)
(* the global object of the observer. Each of them writes its entries to    *)
(* the table with no message to the server. The callback process reads the  *)
(* table. The process of the global object keeps a copy of the timeline,    *)
(* and reads the copy: a write of the callback process adds one to a        *)
(* counter, and the process reads the table again when the counter changed. *)
(*                                                                          *)
(* A process that wrote an entry sends it to the server, and does not wait. *)
(* The server does the observer part of "queue a PerformanceEntry": a copy  *)
(* goes to the observer buffer when the options of the observer have its    *)
(* type, and the row gets the flag queued. (The server keeps the key of the *)
(* last entry of each process: the flag is a comparison with that key.) A   *)
(* buffered observe copies only the rows with the flag. Then the server     *)
(* queues the task: it sets the flag "task queued" of the global object,    *)
(* and sends the task to the callback process when that process has no      *)
(* task.                                                                    *)
(*                                                                          *)
(* The task sets the flag down when it starts, and takes a copy of the list *)
(* of the registered observers. Then it takes the observer buffer, and the  *)
(* callback gets the copies. At its end the task tells the server: a flag   *)
(* that went up during the task sends the next task.                        *)
(*                                                                          *)
(* The messages from one process arrive in their sequence. Thus the server  *)
(* gets the entries of a process before each later call of that process,   *)
(* and before the end of a task.                                            *)
(*                                                                          *)
(* The server monitors the global object, and stops when it stops. The      *)
(* table goes away with it. The callback process then drops the task that   *)
(* it did not start.                                                        *)
(*                                                                          *)
(* Each entry that the server adds to the observer buffer is a copy. A copy *)
(* goes to a callback, to take_records, or a disconnect or the stop of the  *)
(* server drops it. The module counts the copies of each place.             *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design. The value "callback_own_timeline" is the first       *)
(* design: a mark of the callback was an entry of the callback process.     *)
(* The value "write_by_cast" is the second design: the server wrote each    *)
(* entry, and each read was a call of the server.                           *)
(*                                                                          *)
(* The module has no clear of the entries: Performance.tla has the clears   *)
(* of one timeline.                                                         *)
EXTENDS Naturals, Sequences

CONSTANTS
    Types,        \* the entry types
    MaxEntries,   \* the largest number of entries that the processes make
    MaxObserves,  \* the largest number of calls of observe
    Bug           \* "none", or the name of a rule to remove

\* The processes that act for the global object.
Procs == {"global", "callback"}

VARIABLES
    alive,       \* TRUE while the process of the global object runs
    timeline,    \* the performance entry buffer: the rows of the table
    own,         \* the entries that the callback process keeps in its own
                 \* timeline. The design has none
    wire,        \* wire[p] is the sequence of the entries of process p on
                 \* their way to the server
    copy,        \* the numbers of the entries in the copy of the
                 \* process of the global object, in their sequence
    counter,     \* the number of the writes of the callback process
    seen,        \* the counter when the process of the global object
                 \* made its copy
    fromBuffer,  \* the entries that a buffered observe copied
    again,       \* TRUE when the queue step copied an entry that a
                 \* buffered observe copied
    made,        \* the number of entries that the processes made
    server,      \* TRUE while the server runs
    registered,  \* the set of the types of the options list of the
                 \* observer. It is empty when the observer is not in the
                 \* list of the registered observers
    buffer,      \* the observer buffer: a sequence of copies
    pending,     \* the copies that a task carries. The design has none
    queued,      \* the flag "performance observer task queued"
    running,     \* TRUE when the callback process has a task
    tasks,       \* the number of tasks in the mailbox of the callback
                 \* process
    phase,       \* the callback process: "idle", "begun" (it has the copy
                 \* of the list), "callback" (the callback runs), or "end"
    notify,      \* TRUE when the copy of the list has the observer
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

vars == <<alive, timeline, own, wire, copy, counter, seen, fromBuffer, again, made, server,
          registered, buffer, pending, queued, running, tasks, phase, notify,
          requires, since, observes, copies, called, taken, dropped, last>>

\* The flag queued of a row is TRUE after the queue step of its entry.
Entry(p, n, t) == [proc |-> p, n |-> n, type |-> t, queued |-> FALSE]
Queued(e) == [proc |-> e.proc, n |-> e.n, type |-> e.type, queued |-> TRUE]

\* The flag observed of a copy is TRUE when the options of the observer had
\* the type of the entry when the server made the copy.
Copy(e, observed) == [proc |-> e.proc, n |-> e.n, type |-> e.type, observed |-> observed]

Init ==
    /\ alive = TRUE
    /\ timeline = <<>>
    /\ own = <<>>
    /\ wire = [p \in Procs |-> <<>>]
    /\ copy = <<>>
    /\ counter = 0
    /\ seen = 0
    /\ fromBuffer = {}
    /\ again = FALSE
    /\ made = 0
    /\ server = TRUE
    /\ registered = {}
    /\ buffer = <<>>
    /\ pending = <<>>
    /\ queued = FALSE
    /\ running = FALSE
    /\ tasks = 0
    /\ phase = "idle"
    /\ notify = FALSE
    /\ requires = FALSE
    /\ since = FALSE
    /\ observes = 0
    /\ copies = 0
    /\ called = 0
    /\ taken = 0
    /\ dropped = 0
    /\ last = "none"

\* The steps "queue the PerformanceObserver task", in the server: the flag
\* goes up, and the task goes to the callback process when it has none.
\* With the Bug "push_task", the server sends the task also while the
\* callback process has one. With the Bug "no_flag", the flag does not
\* keep a task that waits for the end of the running task.
QueueTask ==
    IF queued
    THEN UNCHANGED <<queued, running, tasks>>
    ELSE IF running /\ Bug # "push_task"
         THEN /\ queued' = (Bug # "no_flag")
              /\ UNCHANGED <<running, tasks>>
         ELSE /\ queued' = TRUE
              /\ running' = TRUE
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

\* Process p runs code now: the callback process only in a callback.
Runs(p) == IF p = "global" THEN alive ELSE phase = "callback"

\* The process that calls a function: its earlier entries arrive at the
\* server before the call.
Ready(p) == Runs(p) /\ wire[p] = <<>>

-----------------------------------------------------------------------------
\* The calls of the processes

\* Process p makes an entry of type t: a mark or a measure. The process
\* writes the entry to the table, and sends it to the server. The process
\* of the global object adds it to its copy. A write of the callback
\* process adds one to the counter. A table that went away with its server
\* takes no entry. With the Bug "callback_own_timeline", an entry of the
\* callback goes to the timeline of the callback process. With the Bug
\* "write_by_cast", only the server writes the entry to the table. With the
\* Bug "no_counter", a write of the callback does not change the counter.
Make(p, t) ==
    /\ Runs(p) /\ t \in Types /\ made < MaxEntries
    /\ made' = made + 1
    /\ LET e == Entry(p, made + 1, t)
       IN  IF p = "callback" /\ Bug = "callback_own_timeline"
           THEN /\ own' = Append(own, e)
                /\ UNCHANGED <<timeline, wire, copy, counter>>
           ELSE IF ~server
           THEN UNCHANGED <<own, timeline, wire, copy, counter>>
           ELSE /\ timeline' = IF Bug = "write_by_cast" THEN timeline ELSE Append(timeline, e)
                /\ wire' = [wire EXCEPT ![p] = Append(@, e)]
                /\ copy' = IF p = "global" /\ Bug # "write_by_cast"
                           THEN Append(copy, e.n) ELSE copy
                /\ counter' = IF p = "callback" /\ Bug # "no_counter"
                              THEN counter + 1 ELSE counter
                /\ UNCHANGED own
    /\ last' = "other"
    /\ UNCHANGED <<alive, seen, fromBuffer, again, server, registered, buffer,
                   pending, queued, running, tasks, phase, notify, requires,
                   since, observes, copies, called, taken, dropped>>

\* The numbers of the entries of a sequence.
Numbers(s) == [i \in 1..Len(s) |-> s[i].n]

\* The process of the global object reads its timeline. When the counter
\* changed, it reads the counter, then the table, and its copy is new.
Read ==
    /\ alive /\ server /\ counter # seen
    /\ copy' = Numbers(timeline)
    /\ seen' = counter
    /\ last' = "other"
    /\ UNCHANGED <<alive, timeline, own, wire, counter, fromBuffer, again,
                   made, server, registered, buffer, pending, queued, running,
                   tasks, phase, notify, requires, since, observes, copies,
                   called, taken, dropped>>

\* The rows of the timeline with type t and the flag queued. With the Bug
\* "buffered_not_queued", also the rows with no flag.
BufferedRows(t) ==
    SelectSeq(timeline, LAMBDA e : e.type = t /\ (e.queued \/ Bug = "buffered_not_queued"))
Buffered(t) ==
    LET old == BufferedRows(t)
    IN  [i \in 1..Len(old) |-> Copy(old[i], TRUE)]

\* Process p calls observe with the type t, and with the flag buffered b.
\* The options of each call add their type. With the flag buffered, the
\* entries of that type in the timeline go to the buffer, and the server
\* queues the task.
Observe(p, t, b) ==
    /\ Ready(p) /\ server /\ t \in Types /\ b \in BOOLEAN
    /\ observes < MaxObserves
    /\ observes' = observes + 1
    /\ registered' = registered \cup {t}
    /\ requires' = TRUE
    /\ since' = TRUE
    /\ IF b
       THEN /\ Store(Buffered(t)) /\ QueueTask
            /\ fromBuffer' = fromBuffer \cup {BufferedRows(t)[i].n : i \in 1..Len(BufferedRows(t))}
       ELSE UNCHANGED <<buffer, pending, copies, queued, running, tasks, fromBuffer>>
    /\ last' = "other"
    /\ UNCHANGED <<copy, counter, seen, alive, timeline, own, wire, again, made, server, phase,
                   notify, called, taken, dropped>>

\* take_records returns the buffer, and empties it.
TakeRecords(p) ==
    /\ Ready(p) /\ server
    /\ buffer' = IF Bug = "take_keeps_buffer" THEN buffer ELSE <<>>
    /\ taken' = taken + Len(buffer)
    /\ last' = "take"
    /\ UNCHANGED <<copy, counter, seen, fromBuffer, again, alive, timeline, own, wire, made, server, registered,
                   pending, queued, running, tasks, phase, notify, requires,
                   since, observes, copies, called, dropped>>

\* disconnect removes the observer from the list of the registered
\* observers, and empties the buffer.
Disconnect(p) ==
    /\ Ready(p) /\ server
    /\ registered' = {}
    /\ IF Bug = "disconnect_keeps_buffer"
       THEN UNCHANGED <<buffer, dropped>>
       ELSE /\ buffer' = <<>>
            /\ dropped' = dropped + Len(buffer)
    /\ last' = "disconnect"
    /\ UNCHANGED <<copy, counter, seen, fromBuffer, again, alive, timeline, own, wire, made, server, pending, queued,
                   running, tasks, phase, notify, requires, since, observes,
                   copies, called, taken>>

\* The process of the global object stops. Its entries on the wire still
\* arrive.
Stop ==
    /\ alive
    /\ alive' = FALSE
    /\ last' = "other"
    /\ UNCHANGED <<copy, counter, seen, fromBuffer, again, timeline, own, wire, made, server, registered, buffer,
                   pending, queued, running, tasks, phase, notify, requires,
                   since, observes, copies, called, taken, dropped>>

-----------------------------------------------------------------------------
\* The server

\* The server gets the next entry of process p. The row of the entry gets
\* the flag queued, and a copy goes to the buffer when the options of the
\* observer have the type of the entry. A server that stopped gets nothing.
\* With the Bug "write_by_cast", the server writes the row here.
Receive(p) ==
    /\ wire[p] # <<>>
    /\ wire' = [wire EXCEPT ![p] = Tail(@)]
    /\ LET e == Head(wire[p])
           observed == e.type \in registered
           copied == observed \/ Bug = "no_filter"
       IN  IF server
           THEN /\ timeline' = IF Bug = "write_by_cast"
                               THEN Append(timeline, Queued(e))
                               ELSE [i \in 1..Len(timeline) |->
                                       IF timeline[i].n = e.n THEN Queued(timeline[i])
                                       ELSE timeline[i]]
                /\ again' = (again \/ (copied /\ e.n \in fromBuffer))
                /\ IF copied
                   THEN Store(<<Copy(e, observed)>>) /\ QueueTask
                   ELSE UNCHANGED <<buffer, pending, copies, queued, running,
                                    tasks>>
           ELSE UNCHANGED <<timeline, again, buffer, pending, copies, queued,
                            running, tasks>>
    /\ last' = "other"
    /\ UNCHANGED <<copy, counter, seen, alive, own, fromBuffer, made, server, registered, phase,
                   notify, requires, since, observes, called, taken, dropped>>

\* The monitor of the server tells it that the global object stopped,
\* after the entries of that process. The server stops. The buffer and the
\* table are lost.
ServerStop ==
    /\ ~alive /\ wire["global"] = <<>> /\ server /\ Bug # "no_monitor"
    /\ server' = FALSE
    /\ timeline' = <<>>
    /\ registered' = {}
    /\ buffer' = <<>>
    /\ dropped' = dropped + Len(buffer)
    /\ queued' = FALSE
    /\ last' = "stop"
    /\ UNCHANGED <<copy, counter, seen, alive, own, fromBuffer, again, wire, made, pending, running, tasks,
                   phase, notify, requires, since, observes, copies, called,
                   taken>>

-----------------------------------------------------------------------------
\* The callback process

\* The callback process starts a task. The server sets the flag down, and
\* gives a copy of the list of the registered observers. When the server
\* stopped, the callback process drops the task. With the Bugs "flag_stays"
\* and "flag_at_end", the flag does not go down here.
Begin ==
    /\ tasks > 0 /\ phase = "idle"
    /\ tasks' = tasks - 1
    /\ IF server
       THEN /\ queued' = IF Bug \in {"flag_stays", "flag_at_end"} THEN queued ELSE FALSE
            /\ notify' = (registered # {})
            /\ phase' = "begun"
       ELSE UNCHANGED <<queued, notify, phase>>
    /\ last' = "other"
    /\ UNCHANGED <<copy, counter, seen, fromBuffer, again, alive, timeline, own, wire, made, server, registered,
                   buffer, pending, running, requires, since, observes,
                   copies, called, taken, dropped>>

\* The task takes the buffer of the observer, when the copy of the list has
\* it. With no entry there is no callback. The first callback after a call
\* of observe has the option dropped_entries_count.
Take ==
    /\ phase = "begun"
    /\ LET got == IF Bug = "take_at_queue" THEN pending ELSE buffer
       IN  IF server /\ notify /\ (Len(got) > 0 \/ Bug = "empty_callback")
           THEN /\ called' = called + Len(got)
                /\ buffer' = IF Bug = "take_at_queue" THEN buffer ELSE <<>>
                /\ pending' = <<>>
                /\ requires' = FALSE
                /\ since' = FALSE
                /\ phase' = "callback"
                /\ last' = "callback"
           ELSE /\ requires' = IF Bug = "empty_task_clears_count" /\ server /\ notify
                               THEN FALSE ELSE requires
                /\ phase' = "end"
                /\ last' = "other"
                /\ UNCHANGED <<buffer, pending, called, since>>
    /\ UNCHANGED <<copy, counter, seen, fromBuffer, again, alive, timeline, own, wire, made, server, registered,
                   queued, running, tasks, notify, observes, copies, taken,
                   dropped>>

\* The callback returns.
Return ==
    /\ phase = "callback"
    /\ phase' = "end"
    /\ last' = "other"
    /\ UNCHANGED <<copy, counter, seen, fromBuffer, again, alive, timeline, own, wire, made, server, registered,
                   buffer, pending, queued, running, tasks, notify, requires,
                   since, observes, copies, called, taken, dropped>>

\* The end of the task, after the entries of the callback: the server sends
\* the next task when the flag went up. With the Bug "flag_at_end", the
\* flag goes down here, and no task goes.
Done ==
    /\ phase = "end" /\ wire["callback"] = <<>>
    /\ phase' = "idle"
    /\ IF server
       THEN IF queued /\ Bug # "flag_at_end"
            THEN /\ tasks' = tasks + 1
                 /\ UNCHANGED <<running, queued>>
            ELSE /\ running' = FALSE
                 /\ queued' = IF Bug = "flag_at_end" THEN FALSE ELSE queued
                 /\ UNCHANGED tasks
       ELSE UNCHANGED <<running, queued, tasks>>
    /\ last' = "other"
    /\ UNCHANGED <<copy, counter, seen, fromBuffer, again, alive, timeline, own, wire, made, server, registered,
                   buffer, pending, notify, requires, since, observes, copies,
                   called, taken, dropped>>

-----------------------------------------------------------------------------

Next ==
    \/ \E p \in Procs : \E t \in Types : Make(p, t)
    \/ \E p \in Procs : \E t \in Types : \E b \in BOOLEAN : Observe(p, t, b)
    \/ \E p \in Procs : TakeRecords(p) \/ Disconnect(p) \/ Receive(p)
    \/ Stop \/ ServerStop \/ Read \/ Begin \/ Take \/ Return \/ Done
    \* The system can stay as it is: no step is necessary.
    \/ UNCHANGED vars

Fairness ==
    /\ \A p \in Procs : WF_vars(Receive(p))
    /\ WF_vars(ServerStop) /\ WF_vars(Begin) /\ WF_vars(Take)
    /\ WF_vars(Return) /\ WF_vars(Done)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ alive \in BOOLEAN /\ server \in BOOLEAN /\ again \in BOOLEAN
    /\ registered \in SUBSET Types
    /\ made \in 0..MaxEntries
    /\ queued \in BOOLEAN /\ running \in BOOLEAN
    /\ requires \in BOOLEAN /\ since \in BOOLEAN /\ notify \in BOOLEAN
    /\ phase \in {"idle", "begun", "callback", "end"}
    /\ observes \in 0..MaxObserves

InTimeline(n) == \E i \in 1..Len(timeline) : timeline[i].n = n

\* The entries of process p on their way to the server that are not in the
\* table.
NotWritten(p) == SelectSeq(wire[p], LAMBDA e : ~InTimeline(e.n))

\* The timeline of the global object has each entry that the processes of
\* the global object made: also the entries of the callback.
OneTimeline ==
    server => Len(timeline) + Len(NotWritten("global")) + Len(NotWritten("callback")) = made

\* A read of a process sees each earlier write of that process: an entry on
\* its way to the server is in the table.
ReadYourWrites == server => \A p \in Procs : NotWritten(p) = <<>>

\* An entry gets to the observer from a buffered observe or from its queue
\* step, not from the two.
OneDeliveryPath == ~again

\* The process of the global object reads its copy only when the copy is
\* the timeline: a write of the callback process changed the counter.
CopyIsCurrent == (server /\ counter = seen) => copy = Numbers(timeline)

\* Each copy is in one place: the buffer, a task, a callback, the result
\* of take_records, or the dropped copies.
EachCopyOnce == Len(buffer) + Len(pending) + called + taken + dropped = copies

\* The observer gets an entry only when its options have the type of the
\* entry.
OnlyObservedEntries == \A i \in 1..Len(buffer) : buffer[i].observed

\* The callback process has at most one task: no task waits in its mailbox
\* while it runs a task.
OneTask == tasks + (IF phase = "idle" THEN 0 ELSE 1) <= 1

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

\* Only a disconnect and the stop of the server drop copies.
DropReason == [][dropped' # dropped => last' \in {"disconnect", "stop"}]_vars

\* Each copy in the buffer goes out: the buffer becomes empty, or the
\* server stops.
Drains == []<>(buffer = <<>> \/ ~server)

\* The callback process comes to rest: it has no task.
Rests == []<>(phase = "idle" /\ tasks = 0)

\* The server stops after the global object.
StopsWithGlobal == ~alive ~> ~server
=============================================================================
