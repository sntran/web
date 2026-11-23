------------------------- MODULE PerformanceObserver -------------------------
(* The timeline of one global object of Web.Performance, one observer of    *)
(* that global object, and its callback process.                            *)
(*                                                                          *)
(* A process is a global object. The first observer of a global object      *)
(* moves its performance entry buffer to a server, the timeline server.     *)
(* Two processes act for the global object: the process of the global       *)
(* object, and the callback process, which runs the callbacks with the      *)
(* global object of the observer. Each of them sends its entries to the     *)
(* server, and does not wait ("queue a PerformanceEntry"). The server adds  *)
(* the entry to the timeline, and a copy to the observer buffer when the    *)
(* options of the observer have its type. Then it queues the task: it sets *)
(* the flag "task queued" of the global object, and sends the task to the   *)
(* callback process when that process has no task.                          *)
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
(* callback process then drops the task that it did not start.              *)
(*                                                                          *)
(* Each entry that the server adds to the observer buffer is a copy. A copy *)
(* goes to a callback, to take_records, or a disconnect or the stop of the  *)
(* server drops it. The module counts the copies of each place.             *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design. The value "callback_own_timeline" is the first       *)
(* design: a mark of the callback was an entry of the callback process.     *)
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
    timeline,    \* the performance entry buffer in the server
    own,         \* the entries that the callback process keeps in its own
                 \* timeline. The design has none
    wire,        \* wire[p] is the sequence of the entries of process p on
                 \* their way to the server
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

vars == <<alive, timeline, own, wire, made, server, registered, buffer,
          pending, queued, running, tasks, phase, notify, requires, since,
          observes, copies, called, taken, dropped, last>>

Entry(p, n, t) == [proc |-> p, n |-> n, type |-> t]

\* The flag observed of a copy is TRUE when the options of the observer had
\* the type of the entry when the server made the copy.
Copy(e, observed) == [proc |-> e.proc, n |-> e.n, type |-> e.type, observed |-> observed]

Init ==
    /\ alive = TRUE
    /\ timeline = <<>>
    /\ own = <<>>
    /\ wire = [p \in Procs |-> <<>>]
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

\* Process p makes an entry of type t: a mark or a measure. The entry goes
\* to the server. With the Bug "callback_own_timeline", an entry of the
\* callback goes to the timeline of the callback process.
Make(p, t) ==
    /\ Runs(p) /\ t \in Types /\ made < MaxEntries
    /\ made' = made + 1
    /\ IF p = "callback" /\ Bug = "callback_own_timeline"
       THEN /\ own' = Append(own, Entry(p, made + 1, t))
            /\ UNCHANGED wire
       ELSE /\ wire' = [wire EXCEPT ![p] = Append(@, Entry(p, made + 1, t))]
            /\ UNCHANGED own
    /\ last' = "other"
    /\ UNCHANGED <<alive, timeline, server, registered, buffer, pending,
                   queued, running, tasks, phase, notify, requires, since,
                   observes, copies, called, taken, dropped>>

\* The entries of the timeline with type t.
Buffered(t) ==
    LET old == SelectSeq(timeline, LAMBDA e : e.type = t)
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
       THEN Store(Buffered(t)) /\ QueueTask
       ELSE UNCHANGED <<buffer, pending, copies, queued, running, tasks>>
    /\ last' = "other"
    /\ UNCHANGED <<alive, timeline, own, wire, made, server, phase, notify,
                   called, taken, dropped>>

\* take_records returns the buffer, and empties it.
TakeRecords(p) ==
    /\ Ready(p) /\ server
    /\ buffer' = IF Bug = "take_keeps_buffer" THEN buffer ELSE <<>>
    /\ taken' = taken + Len(buffer)
    /\ last' = "take"
    /\ UNCHANGED <<alive, timeline, own, wire, made, server, registered,
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
    /\ UNCHANGED <<alive, timeline, own, wire, made, server, pending, queued,
                   running, tasks, phase, notify, requires, since, observes,
                   copies, called, taken>>

\* The process of the global object stops. Its entries on the wire still
\* arrive.
Stop ==
    /\ alive
    /\ alive' = FALSE
    /\ last' = "other"
    /\ UNCHANGED <<timeline, own, wire, made, server, registered, buffer,
                   pending, queued, running, tasks, phase, notify, requires,
                   since, observes, copies, called, taken, dropped>>

-----------------------------------------------------------------------------
\* The server

\* The server gets the next entry of process p. The entry goes to the
\* timeline, and a copy to the buffer when the options of the observer
\* have its type. A server that stopped gets nothing.
Receive(p) ==
    /\ wire[p] # <<>>
    /\ wire' = [wire EXCEPT ![p] = Tail(@)]
    /\ LET e == Head(wire[p])
           observed == e.type \in registered
       IN  IF server
           THEN /\ timeline' = Append(timeline, e)
                /\ IF observed \/ Bug = "no_filter"
                   THEN Store(<<Copy(e, observed)>>) /\ QueueTask
                   ELSE UNCHANGED <<buffer, pending, copies, queued, running,
                                    tasks>>
           ELSE UNCHANGED <<timeline, buffer, pending, copies, queued,
                            running, tasks>>
    /\ last' = "other"
    /\ UNCHANGED <<alive, own, made, server, registered, phase, notify,
                   requires, since, observes, called, taken, dropped>>

\* The monitor of the server tells it that the global object stopped,
\* after the entries of that process. The server stops. The buffer is lost.
ServerStop ==
    /\ ~alive /\ wire["global"] = <<>> /\ server /\ Bug # "no_monitor"
    /\ server' = FALSE
    /\ registered' = {}
    /\ buffer' = <<>>
    /\ dropped' = dropped + Len(buffer)
    /\ queued' = FALSE
    /\ last' = "stop"
    /\ UNCHANGED <<alive, timeline, own, wire, made, pending, running, tasks,
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
    /\ UNCHANGED <<alive, timeline, own, wire, made, server, registered,
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
    /\ UNCHANGED <<alive, timeline, own, wire, made, server, registered,
                   queued, running, tasks, notify, observes, copies, taken,
                   dropped>>

\* The callback returns.
Return ==
    /\ phase = "callback"
    /\ phase' = "end"
    /\ last' = "other"
    /\ UNCHANGED <<alive, timeline, own, wire, made, server, registered,
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
    /\ UNCHANGED <<alive, timeline, own, wire, made, server, registered,
                   buffer, pending, notify, requires, since, observes, copies,
                   called, taken, dropped>>

-----------------------------------------------------------------------------

Next ==
    \/ \E p \in Procs : \E t \in Types : Make(p, t)
    \/ \E p \in Procs : \E t \in Types : \E b \in BOOLEAN : Observe(p, t, b)
    \/ \E p \in Procs : TakeRecords(p) \/ Disconnect(p) \/ Receive(p)
    \/ Stop \/ ServerStop \/ Begin \/ Take \/ Return \/ Done
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
    /\ alive \in BOOLEAN /\ server \in BOOLEAN
    /\ registered \in SUBSET Types
    /\ made \in 0..MaxEntries
    /\ queued \in BOOLEAN /\ running \in BOOLEAN
    /\ requires \in BOOLEAN /\ since \in BOOLEAN /\ notify \in BOOLEAN
    /\ phase \in {"idle", "begun", "callback", "end"}
    /\ observes \in 0..MaxObserves

\* The timeline of the global object has each entry that the processes of
\* the global object made: also the entries of the callback.
OneTimeline ==
    server => Len(timeline) + Len(wire["global"]) + Len(wire["callback"]) = made

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
