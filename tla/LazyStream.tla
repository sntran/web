----------------------------- MODULE LazyStream -----------------------------
(* The shared state of the copies of one Web.Internal.LazyStream, with     *)
(* copies and starters that stop at each step of a stream read, and with   *)
(* kills of starters and of stream processes.                              *)
(*                                                                         *)
(* A body that has all its bytes has no process until a stream read. Each  *)
(* copy of the struct can be in a different process, and all the copies    *)
(* share one state: one element of an :atomics array, the cell. A copy on  *)
(* a different node does each operation on the node of the array, thus it  *)
(* is one more copy of this module.                                        *)
(*                                                                         *)
(* The operations of a copy:                                               *)
(*   * a claim changes "readable" to "consumed" (an enumeration takes the  *)
(*     bytes), to "locked" (a body function, a tee, or a proxy takes the   *)
(*     bytes, and keeps the lock), or to "canceled" (a cancel). It looks   *)
(*     in the registry, and then it does a compare-exchange in a second    *)
(*     step. The bytes are free also in the cell "process" when no read    *)
(*     disturbed the stream process before its stop: then a short process  *)
(*     with the key sets "readable" first. A claim from "process" could    *)
(*     take the bytes of a new stream process: a starter can set "process" *)
(*     again between the look and the compare-exchange;                    *)
(*   * a stream read asks for the stream process. With no stream process,  *)
(*     the copy starts a starter, a short process, and waits for its end:  *)
(*     the process of the copy can stop at each step, and the start must   *)
(*     continue. The starter takes the key {ref, :start} in the registry,  *)
(*     changes the cell to "starting" or "starting_closed" with one        *)
(*     compare-exchange, starts the stream process, which registers        *)
(*     itself, and sets "process" or "taken". A starter whose copy stopped *)
(*     stops the new stream process and sets "readable": no reader keeps   *)
(*     that process;                                                       *)
(*   * a copy that finds "starting" waits for the end of the starter that  *)
(*     has the key (a monitor, not a time limit). With no starter, the     *)
(*     starter that set "starting" stopped: the copy starts a new starter, *)
(*     which continues from the cell and the registry;                     *)
(*   * a copy that got the stream process keeps it until it takes its lock *)
(*     or stops: the lifetime rules do not stop the process for the stop   *)
(*     of its owner while a copy waits for its lock. A process that a      *)
(*     different process killed before the lock took no bytes when no read *)
(*     disturbed it: the lock step asks for the stream process again;      *)
(*   * the first disturb of the stream process (a read, a cancel, a pipe,  *)
(*     or the step "consume body") sets "taken" in the same step: a        *)
(*     disturbed stream gives no bytes to a different reader. A stream     *)
(*     process that stops before a disturb takes no bytes from the other   *)
(*     copies: the lifetime rules stop it with no cancel.                  *)
(*                                                                         *)
(* A copy reads the cell and the registry in one step of this model,       *)
(* except for the claim. The real copy reads the registry and then the     *)
(* cell for a stream read, and the cell and then the registry, and the     *)
(* cell again, for the state: a stream process registers itself before its *)
(* starter sets a cell that is not "starting", and a starter decides again *)
(* with the key and a compare-exchange.                                    *)
(*                                                                         *)
(* The lifetime rules stop a stream process when its owner stopped and no  *)
(* copy keeps it, or after its end. A different process can also kill a    *)
(* starter or a stream process. A kill of a starter in the start of its    *)
(* stream process can leave that start, which continues with no starter:   *)
(* it registers itself only in the state "starting" while no stream        *)
(* process has the key, else it stops normally in its start, with no crash *)
(* report. The state can change from "starting" to "readable" after that   *)
(* start: a starter whose copy stopped sets it. A stream process that the  *)
(* cell does not give has no use: the starter, a claim, and a copy that    *)
(* finds it stop it.                                                       *)
(*                                                                         *)
(* The model has a body with its bytes in the struct. A body that a        *)
(* process holds, such as a fetch body, has the same rules: the holder     *)
(* gives its bytes to the stream process only at the first pull, which     *)
(* comes with the first read.                                              *)
(*                                                                         *)
(* The constant Bug is "none" for the design. Each other value removes one *)
(* rule of the design. The value "today" is the code before this model:    *)
(* the copy starts the stream process itself, a copy that finds "starting" *)
(* waits for a new cell with a time limit, and then gets "gone", and a     *)
(* stream process that stopped gives "gone". The values "lock_no_retry",   *)
(* "stale_stays", and "process_claim" are the code before the rules of the *)
(* kills.                                                                  *)
EXTENDS Naturals

CONSTANTS
    Copies,  \* the processes that have a copy of the struct
    Ops,     \* the operations of the copies: Claims, "read", and "state"
    Kills,   \* the number of starters that a process can kill
    StreamKills, \* the number of stream processes that a process can kill
    Bug      \* "none", or the name of a rule to remove

None == "none"

Claims == {"consumed", "canceled", "locked"}

Starting == {"starting", "starting_closed"}

Cells == {"readable", "consumed", "canceled", "locked", "process", "taken"} \cup Starting

Results == {None, "ok", "readable", "consumed", "canceled", "locked", "process",
            "bytes", "closed", "failed", "released", "gone"}

\* The steps of a copy: no operation yet, an operation to do, a wait for the
\* end of a starter, a wait for a new cell (the bug "today"), a stream
\* process to lock and read, a lock and a read with no chunk yet, a stream
\* process that stopped before the read, the compare-exchange of a claim,
\* the look in the registry after that claim, the end, and the stop. Each
\* copy does one operation: a different operation is a different copy.
Active == {"ask", "wait", "poll", "lock", "read", "stale", "set", "reap"}

CopySteps == Active \cup {"idle", "done", "stopped"}

\* The steps of the starter of a copy: no starter, the key, the decision
\* with the cell, the start of the stream process, the state after it, and
\* the state "readable" after the stop of the process of a copy that
\* stopped.
StarterSteps == {None, "register", "decide", "new", "check", "rollback", "reap"}

\* The states that give a stream process to the copies. A stream process in
\* a different state has no use: no copy can read it.
Pointed == {"process", "taken"} \cup Starting

VARIABLES
    cell,       \* the state in the :atomics array
    cpc,        \* [Copies -> CopySteps]
    op,         \* [Copies -> Ops \cup {None}]: the operation of the copy
    busy,       \* [Copies -> BOOLEAN]: the copy waits for the starter of the key
    rd,         \* [Copies -> Cells \cup {None}]: the cell that a claim found
    seen,       \* [Copies -> 0..1]: the value of epoch when that wait started
    sp,         \* [Copies -> StarterSteps]: the step of the starter of the copy
    sk,         \* [Copies -> {"bytes", "closed"}]: the stream of that starter
    marker,     \* the copy whose starter has the key, or None
    epoch,      \* 0..1: it changes each time that a starter takes the key
    live,       \* the number of stream processes that are alive
    skind,      \* "bytes" or "closed": the last stream process
    sowner,     \* the copy that owns the last stream process, or None
    pulled,     \* TRUE after the first disturb of that process: a read or a cancel
    held,       \* TRUE while a reader keeps the lock of that process
    orphan,     \* the copy of a killed starter whose start continues, or None
    kills,      \* the number of starters that a process killed
    given,      \* the number of times that the bytes went to a reader
    spent,      \* TRUE after the bytes went to a reader, or a cancel discarded them
    killed,     \* the number of stream processes that a process killed
    crashed,    \* TRUE after a start of a stream process crashed
    result      \* [Copies -> Results]: the result of the last operation

copyVars == <<cpc, op, busy, seen, result, rd>>
starterVars == <<sp, sk, marker, epoch, kills>>
streamVars == <<live, skind, sowner, pulled, held, orphan, killed, crashed>>
vars == <<cell, given, spent, copyVars, starterVars, streamVars>>

Init ==
    /\ cell = "readable"
    /\ cpc = [c \in Copies |-> "idle"]
    /\ op = [c \in Copies |-> None]
    /\ busy = [c \in Copies |-> FALSE]
    /\ rd = [c \in Copies |-> None]
    /\ seen = [c \in Copies |-> 0]
    /\ sp = [c \in Copies |-> None]
    /\ sk = [c \in Copies |-> "bytes"]
    /\ marker = None /\ epoch = 0
    /\ live = 0 /\ skind = "bytes" /\ sowner = None /\ pulled = FALSE /\ held = FALSE
    /\ orphan = None /\ killed = 0 /\ crashed = FALSE
    /\ kills = 0 /\ given = 0 /\ spent = FALSE
    /\ result = [c \in Copies |-> None]

Today == Bug = "today"

\* No process has the bytes: the cell "readable", or the cell "process" with
\* a stream process that stopped before its first disturb.
Free == \/ cell = "readable"
        \/ cell = "process" /\ live = 0 /\ Bug \notin {"today", "dead_is_gone"}

\* The state that a copy finds in a cell that is not "starting".
Found == CASE cell \in {"readable", "consumed", "canceled", "locked"} -> cell
           [] live > 0 -> "process"
           [] Free -> "readable"
           [] OTHER -> "gone"

\* The copy ends its operation with the result r.
End(c, r) ==
    /\ cpc' = [cpc EXCEPT ![c] = "done"]
    /\ op' = [op EXCEPT ![c] = None]
    /\ busy' = [busy EXCEPT ![c] = FALSE]
    /\ seen' = [seen EXCEPT ![c] = 0]
    /\ result' = [result EXCEPT ![c] = r]
    /\ rd' = [rd EXCEPT ![c] = None]

\* The copy starts a starter and waits for its end. For the bug "today", the
\* copy is the starter: it does the steps itself, with no key.
Spawn(c) ==
    /\ sp' = [sp EXCEPT ![c] = IF Today THEN "decide" ELSE "register"]
    /\ cpc' = [cpc EXCEPT ![c] = "wait"]
    /\ busy' = [busy EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<op, seen, result, rd, sk, marker, epoch, kills>>

\* The copy waits for the end of the starter that has the key.
AwaitKey(c) ==
    /\ cpc' = [cpc EXCEPT ![c] = "wait"]
    /\ busy' = [busy EXCEPT ![c] = TRUE]
    /\ seen' = [seen EXCEPT ![c] = epoch]
    /\ UNCHANGED <<op, result, rd, starterVars>>

\* A stream process stops. A copy in the step "lock" or "read" has that
\* process: it cannot read it. With no stream process, the model forgets
\* the last one.
StopStream ==
    /\ live' = live - 1
    /\ IF live = 1
       THEN skind' = "bytes" /\ sowner' = None /\ pulled' = FALSE /\ held' = FALSE
       ELSE UNCHANGED <<skind, sowner, pulled, held>>

StaleOf(steps) == [c \in Copies |-> IF steps[c] \in {"lock", "read"} THEN "stale" ELSE steps[c]]

Stopped == StopStream /\ cpc' = StaleOf(cpc)

\* A copy, a claim, or a starter that finds a stream process with no use
\* stops it. The bug "stale_stays" is the code before this rule: no
\* process stops it.
Reaps == live > 0 /\ cell \notin Pointed /\ Bug # "stale_stays"

-----------------------------------------------------------------------------
\* The steps of a copy

\* Copy c starts the operation o.
Begin(c, o) ==
    /\ cpc[c] = "idle"
    /\ cpc' = [cpc EXCEPT ![c] = "ask"]
    /\ op' = [op EXCEPT ![c] = o]
    /\ UNCHANGED <<cell, given, spent, busy, seen, result, rd, starterVars, streamVars>>

\* Copy c does its operation with the cell that it finds.
Eval(c) ==
    /\ cpc[c] = "ask"
    /\ \/ \* "starting": the copy waits for the starter, or starts a new one.
          /\ cell \in Starting
          /\ IF Today \/ (Bug = "no_take_over" /\ marker = None)
             THEN /\ cpc' = [cpc EXCEPT ![c] = "poll"]
                  /\ UNCHANGED <<op, busy, seen, result, rd, starterVars>>
             ELSE IF marker # None /\ Bug # "no_key" THEN AwaitKey(c) ELSE Spawn(c)
          /\ UNCHANGED <<cell, given, spent, streamVars>>
       \/ \* A stream read.
          /\ cell \notin Starting /\ op[c] = "read"
          /\ CASE cell = "locked" ->
                    End(c, "locked") /\ UNCHANGED <<starterVars, streamVars>>
               [] Reaps ->
                    \* A stream process with no use: the copy stops it.
                    /\ Stopped
                    /\ UNCHANGED <<op, busy, seen, result, rd, starterVars, orphan, killed,
                                   crashed>>
               [] live > 0 ->
                    /\ cpc' = [cpc EXCEPT ![c] = "lock"]
                    /\ UNCHANGED <<op, busy, seen, result, rd, starterVars, streamVars>>
               [] cell = "taken" \/ Found = "gone" ->
                    End(c, "released") /\ UNCHANGED <<starterVars, streamVars>>
               [] OTHER -> Spawn(c) /\ UNCHANGED streamVars
          /\ UNCHANGED <<cell, given, spent>>
       \/ \* A claim. The copy looks in the registry, and then it changes the
          \* cell with a compare-exchange in a second step.
          /\ cell \notin Starting /\ op[c] \in Claims
          /\ CASE cell = "readable" \/ (Free /\ Bug = "process_claim") ->
                    /\ cpc' = [cpc EXCEPT ![c] = "set"]
                    /\ rd' = [rd EXCEPT ![c] = cell]
                    /\ UNCHANGED <<cell, given, spent, op, busy, seen, result, pulled, held>>
               [] Free /\ marker = None ->
                    \* The stream process stopped before a read. A short process
                    \* with the key sets "readable": no starter can start a new
                    \* stream process and set "process" again before the
                    \* compare-exchange of the claim. The bug "process_claim"
                    \* takes the bytes from "process".
                    /\ cell' = "readable"
                    /\ UNCHANGED <<given, spent, op, busy, seen, result, rd, cpc, pulled, held>>
               [] Free ->
                    AwaitKey(c) /\ UNCHANGED <<cell, given, spent, rd, pulled, held>>
               [] cell \in Claims ->
                    End(c, cell) /\ UNCHANGED <<cell, given, spent, pulled, held>>
               [] live > 0 /\ op[c] = "canceled" /\ held ->
                    \* A reader has the lock of the stream process.
                    End(c, "locked") /\ UNCHANGED <<cell, given, spent, pulled, held>>
               [] live > 0 /\ op[c] = "canceled" ->
                    \* The cancel of the stream process discards the bytes.
                    /\ cell' = IF cell = "process" THEN "taken" ELSE cell
                    /\ pulled' = TRUE /\ spent' = TRUE
                    /\ End(c, "ok")
                    /\ UNCHANGED <<given, held>>
               [] live > 0 ->
                    \* A body function or an enumeration reads the process.
                    /\ cpc' = [cpc EXCEPT ![c] = "lock"]
                    /\ UNCHANGED <<cell, given, spent, op, busy, seen, result, rd, pulled, held>>
               [] OTHER ->
                    End(c, Found) /\ UNCHANGED <<cell, given, spent, pulled, held>>
          /\ UNCHANGED <<starterVars, live, skind, sowner, orphan, killed, crashed>>
       \/ \* The state.
          /\ cell \notin Starting /\ op[c] = "state"
          /\ End(c, Found)
          /\ UNCHANGED <<cell, given, spent, starterVars, streamVars>>

\* The compare-exchange of a claim, from the cell that the claim found. A
\* cell that changed gives a new try. The bug "read_then_set" sets the cell
\* with no compare. Then the claim looks in the registry.
ClaimSet(c) ==
    /\ cpc[c] = "set"
    /\ IF cell = rd[c] \/ Bug = "read_then_set"
       THEN /\ cell' = op[c]
            /\ given' = IF op[c] = "canceled" THEN given ELSE given + 1
            /\ spent' = TRUE
            /\ cpc' = [cpc EXCEPT ![c] = "reap"]
       ELSE /\ cpc' = [cpc EXCEPT ![c] = "ask"]
            /\ UNCHANGED <<cell, given, spent>>
    /\ rd' = [rd EXCEPT ![c] = None]
    /\ UNCHANGED <<op, busy, seen, result, starterVars, streamVars>>

\* The claim that took the bytes stops a stream process that the registry
\* has: the cell does not give it, thus it has no use.
Reap(c) ==
    /\ cpc[c] = "reap"
    /\ IF Reaps
       THEN StopStream /\ cpc' = StaleOf([cpc EXCEPT ![c] = "done"])
       ELSE cpc' = [cpc EXCEPT ![c] = "done"] /\ UNCHANGED <<live, skind, sowner, pulled, held>>
    /\ result' = [result EXCEPT ![c] = "ok"]
    /\ op' = [op EXCEPT ![c] = None]
    /\ UNCHANGED <<cell, given, spent, busy, seen, rd, starterVars, orphan, killed, crashed>>

\* The copy gets the end of the starter that it waits for: the monitor of
\* its own starter, and then the monitor of the starter that had the key.
Wake(c) ==
    /\ cpc[c] = "wait" /\ sp[c] = None
    /\ (~busy[c] \/ marker = None \/ epoch # seen[c])
    /\ cpc' = [cpc EXCEPT ![c] = "ask"]
    /\ busy' = [busy EXCEPT ![c] = FALSE]
    /\ seen' = [seen EXCEPT ![c] = 0]
    /\ UNCHANGED <<cell, given, spent, op, result, rd, starterVars, streamVars>>

\* The bug "today": the copy reads the cell again until it is not "starting".
Poll(c) ==
    /\ cpc[c] = "poll" /\ cell \notin Starting
    /\ cpc' = [cpc EXCEPT ![c] = "ask"]
    /\ UNCHANGED <<cell, given, spent, op, busy, seen, result, rd, starterVars, streamVars>>

\* The bug "today": the time limit of the wait. It comes only after the
\* start stopped: a start that continues ends before it.
Timeout(c) ==
    /\ Today /\ cpc[c] = "poll" /\ cell \in Starting
    /\ \A x \in Copies : sp[x] = None
    /\ End(c, "gone")
    /\ UNCHANGED <<cell, given, spent, starterVars, streamVars>>

\* The state that a lock step finds after a stop of the process, when no
\* read took the bytes: the bytes are free, a start runs, or a different
\* stream process has them. A new ask then gives the stream process.
Retry == \/ cell \in {"readable", "process"} \cup Starting
         \/ cell = "taken" /\ live > 0

\* The copy locks the stream process and disturbs it: a read, or the
\* disturb of the step "consume body" and of a pipe. The copy keeps the
\* lock. The first disturb takes the bytes and sets "taken" in the same
\* step: a disturbed stream gives no bytes to a different reader. The bug
\* "pull_keeps_bytes" does not set "taken", and the bug
\* "disturb_keeps_bytes" sets it only when the chunks come.
Lock(c) ==
    /\ cpc[c] \in {"lock", "stale"}
    /\ CASE cpc[c] = "stale" /\ Retry /\ Bug # "lock_no_retry" ->
              \* The process stopped before its first read: the lock step asks
              \* again. The bug "lock_no_retry" gives the error.
              /\ cpc' = [cpc EXCEPT ![c] = "ask"]
              /\ UNCHANGED <<cell, given, spent, pulled, held, op, busy, seen, result, rd>>
         [] cpc[c] = "stale" ->
              End(c, "failed") /\ UNCHANGED <<cell, given, spent, pulled, held>>
         [] held ->
              End(c, "locked") /\ UNCHANGED <<cell, given, spent, pulled, held>>
         [] skind = "closed" \/ pulled ->
              \* A closed stream, or a stream that a cancel closed.
              End(c, "closed") /\ held' = TRUE /\ UNCHANGED <<cell, given, spent, pulled>>
         [] OTHER ->
              /\ pulled' = TRUE /\ held' = TRUE /\ given' = given + 1 /\ spent' = TRUE
              /\ cell' = IF cell = "process" /\ Bug \notin {"pull_keeps_bytes",
                                                               "disturb_keeps_bytes"}
                         THEN "taken"
                         ELSE cell
              /\ cpc' = [cpc EXCEPT ![c] = "read"]
              /\ UNCHANGED <<op, busy, seen, result, rd>>
    /\ UNCHANGED <<starterVars, live, skind, sowner, orphan, killed, crashed>>

\* The chunks come to the copy that disturbed the stream process.
Read(c) ==
    /\ cpc[c] = "read"
    /\ cell' = IF cell = "process" /\ Bug = "disturb_keeps_bytes" THEN "taken" ELSE cell
    /\ End(c, "bytes")
    /\ UNCHANGED <<given, spent, starterVars, streamVars>>

\* A copy that has the stream process does not read it.
Drop(c) ==
    /\ cpc[c] \in {"lock", "stale"}
    /\ End(c, "process")
    /\ UNCHANGED <<cell, given, spent, starterVars, streamVars>>

\* The process of copy c stops during its operation. Its starter continues,
\* except for the bug "today": the copy is the starter.
CopyStop(c) ==
    /\ cpc[c] \in Active
    /\ cpc' = [cpc EXCEPT ![c] = "stopped"]
    /\ op' = [op EXCEPT ![c] = None]
    /\ busy' = [busy EXCEPT ![c] = FALSE]
    /\ seen' = [seen EXCEPT ![c] = 0]
    /\ sp' = IF Today THEN [sp EXCEPT ![c] = None] ELSE sp
    /\ UNCHANGED <<cell, given, spent, result, rd, sk, marker, epoch, kills, streamVars>>

-----------------------------------------------------------------------------
\* The steps of a starter

\* The starter of copy c takes the key. When a different starter has it,
\* the starter stops, and its copy waits for the end of that starter. The
\* bug "no_key" takes no key.
Register(c) ==
    /\ sp[c] = "register"
    /\ IF marker = None \/ Bug = "no_key"
       THEN /\ sp' = [sp EXCEPT ![c] = "decide"]
            /\ marker' = IF Bug = "no_key" THEN marker ELSE c
            /\ epoch' = 1 - epoch
            /\ UNCHANGED <<busy, seen>>
       ELSE /\ sp' = [sp EXCEPT ![c] = None]
            /\ busy' = [busy EXCEPT ![c] = TRUE]
            /\ seen' = [seen EXCEPT ![c] = epoch]
            /\ UNCHANGED <<marker, epoch>>
    /\ UNCHANGED <<cell, given, spent, cpc, op, result, rd, sk, kills, streamVars>>

\* The starter ends: the registry removes its key.
Exit(c) ==
    /\ sp' = [sp EXCEPT ![c] = None]
    /\ sk' = [sk EXCEPT ![c] = "bytes"]
    /\ marker' = IF marker = c THEN None ELSE marker

\* The starter decides with the cell and the registry, and changes the cell
\* with one compare-exchange. A stream process with the state "starting" is
\* the process of a starter that stopped: this starter sets its state. The
\* bug "closed_gets_bytes" gives the bytes also to a stream after a claim.
Decide(c) ==
    /\ sp[c] = "decide"
    /\ CASE cell \in Starting /\ live > 0 ->
              /\ cell' = IF cell = "starting" THEN "process" ELSE "taken"
              /\ Exit(c)
         [] cell \in Starting ->
              /\ sp' = [sp EXCEPT ![c] = "new"]
              /\ sk' = [sk EXCEPT ![c] = IF cell = "starting" THEN "bytes" ELSE "closed"]
              /\ UNCHANGED <<cell, marker>>
         [] Free \/ (cell \in {"consumed", "canceled"} /\ Bug = "closed_gets_bytes") ->
              /\ cell' = "starting"
              /\ sp' = [sp EXCEPT ![c] = "new"]
              /\ sk' = [sk EXCEPT ![c] = "bytes"]
              /\ UNCHANGED marker
         [] cell \in {"consumed", "canceled"} ->
              /\ cell' = "starting_closed"
              /\ sp' = [sp EXCEPT ![c] = "new"]
              /\ sk' = [sk EXCEPT ![c] = "closed"]
              /\ UNCHANGED marker
         [] OTHER ->
              Exit(c) /\ UNCHANGED cell
    /\ UNCHANGED <<given, spent, copyVars, epoch, kills, streamVars>>

\* The stream process starts and registers itself. Its owner is the copy.
\* When a different stream process has the key (the start of a killed
\* starter continued), the new process stops normally in its start, and
\* the starter decides again. The bug "unchecked_start" writes a crash
\* report, and the starter stops.
StartStream(c, kind) ==
    /\ live' = live + 1 /\ skind' = kind /\ sowner' = c /\ pulled' = FALSE /\ held' = FALSE

New(c) ==
    /\ sp[c] = "new"
    /\ IF live = 0
       THEN /\ sp' = [sp EXCEPT ![c] = "check"]
            /\ StartStream(c, sk[c])
            /\ UNCHANGED <<sk, marker, crashed>>
       ELSE IF Bug = "unchecked_start"
       THEN /\ Exit(c) /\ crashed' = TRUE
            /\ UNCHANGED <<live, skind, sowner, pulled, held>>
       ELSE /\ sp' = [sp EXCEPT ![c] = "decide"]
            /\ UNCHANGED <<sk, marker, live, skind, sowner, pulled, held, crashed>>
    /\ UNCHANGED <<cell, given, spent, copyVars, epoch, kills, orphan, killed>>

\* The start of the stream process of a killed starter continues, at a
\* later time. The process registers itself only when no stream process has
\* the key and the bytes are free: the cell is "starting", or "process"
\* with no stream process. Else it stops normally in its start. The bug
\* "unchecked_start" registers with no look at the cell, and writes a crash
\* report when a different stream process has the key.
OrphanStart ==
    /\ orphan # None
    /\ orphan' = None
    /\ IF live = 0 /\ (cell = "starting" \/ (cell = "process" /\ Bug = "stale_stays")
                         \/ Bug = "unchecked_start")
       THEN StartStream(orphan, "bytes") /\ UNCHANGED crashed
       ELSE /\ crashed' = (crashed \/ (live > 0 /\ Bug = "unchecked_start"))
            /\ UNCHANGED <<live, skind, sowner, pulled, held>>
    /\ UNCHANGED <<cell, given, spent, copyVars, starterVars, killed>>

\* The starter sets the state after the start. When its copy stopped, it
\* stops the stream process of the bytes, and sets "readable": no reader
\* keeps that process. The bug "today" has no such rule. The bug
\* "held_at_start" is the body that a process holds before this model: the
\* holder gives its bytes to the stream process at its start, and the
\* starter sets "taken".
Check(c) ==
    /\ sp[c] = "check"
    /\ IF sk[c] = "bytes" /\ cpc[c] = "stopped" /\ ~Today
       THEN /\ IF live > 0 /\ sowner = c
               THEN Stopped /\ UNCHANGED <<orphan, killed, crashed>>
               ELSE UNCHANGED <<cpc, streamVars>>
            /\ sp' = [sp EXCEPT ![c] = "rollback"]
            /\ UNCHANGED <<cell, sk, marker>>
       ELSE /\ cell' = CASE cell = "starting" /\ Bug = "held_at_start" -> "taken"
                         [] cell = "starting" -> "process"
                         [] cell = "starting_closed" -> "taken"
                         [] OTHER -> cell
            /\ Exit(c)
            /\ UNCHANGED <<cpc, streamVars>>
    /\ UNCHANGED <<given, spent, op, busy, seen, result, rd, epoch, kills>>

\* The starter of a copy that stopped sets "readable". Then it looks in the
\* registry, and stops a stream process with no use: a start that continued
\* registered itself in the state "starting", after the stop of the
\* process of this starter.
Rollback(c) ==
    /\ sp[c] = "rollback"
    /\ cell' = IF cell = "starting" THEN "readable" ELSE cell
    /\ sp' = [sp EXCEPT ![c] = "reap"]
    /\ UNCHANGED <<given, spent, copyVars, sk, marker, epoch, kills, streamVars>>

StarterReap(c) ==
    /\ sp[c] = "reap"
    /\ IF Reaps THEN Stopped /\ UNCHANGED <<orphan, killed, crashed>> ELSE UNCHANGED <<cpc, streamVars>>
    /\ Exit(c)
    /\ UNCHANGED <<cell, given, spent, op, busy, seen, result, rd, epoch, kills>>

\* A process kills the starter of copy c before its end. The registry
\* removes its key. A kill in the start of the stream process of the bytes
\* can leave that start, which continues with no starter.
StarterStop(c, continues) ==
    /\ sp[c] \in {"register", "decide", "new", "check", "rollback", "reap"} /\ ~Today
    /\ kills < Kills
    /\ continues => sp[c] = "new" /\ sk[c] = "bytes" /\ live = 0
    /\ kills' = kills + 1
    /\ orphan' = IF continues THEN c ELSE None
    /\ Exit(c)
    /\ UNCHANGED <<cell, given, spent, copyVars, epoch, live, skind, sowner, pulled, held,
                   killed, crashed>>

\* A copy that got the stream process and takes its lock next keeps it, as
\* a lock: the bug "no_keep" has no such rule. A copy that disturbed the
\* process has its lock.
Waiting == \E c \in Copies : cpc[c] = "lock"

Reading == \E c \in Copies : cpc[c] = "read"

\* The lifetime rules stop the stream process: its owner stopped and no
\* copy keeps it, or it ended. The registry removes its key. A stream
\* process that no read disturbed stops with no cancel.
StreamStop ==
    /\ live > 0 /\ ~Reading
    /\ \/ sowner \in Copies /\ cpc[sowner] = "stopped" /\ (~Waiting \/ Bug = "no_keep")
       \/ pulled
       \/ skind = "closed"
    /\ Stopped
    /\ UNCHANGED <<cell, given, spent, op, busy, seen, result, rd, starterVars, orphan, killed,
                   crashed>>

\* A different process kills the stream process.
StreamKill ==
    /\ live > 0 /\ killed < StreamKills
    /\ killed' = killed + 1
    /\ Stopped
    /\ UNCHANGED <<cell, given, spent, op, busy, seen, result, rd, starterVars, orphan, crashed>>

Next ==
    \/ \E c \in Copies :
        \/ \E o \in Ops : Begin(c, o)
        \/ Eval(c) \/ ClaimSet(c) \/ Reap(c) \/ Wake(c) \/ Poll(c) \/ Timeout(c) \/ Lock(c)
        \/ Read(c) \/ Drop(c) \/ CopyStop(c)
        \/ Register(c) \/ Decide(c) \/ New(c) \/ Check(c) \/ Rollback(c) \/ StarterReap(c)
        \/ \E continues \in BOOLEAN : StarterStop(c, continues)
    \/ StreamStop \/ StreamKill \/ OrphanStart
    \/ UNCHANGED vars

\* The steps of copy c and of its starter. At each time, one of them at
\* most can do a step: the copy waits during the work of its starter.
Proc(c) ==
    \/ Eval(c) \/ ClaimSet(c) \/ Reap(c) \/ Wake(c) \/ Poll(c) \/ Lock(c) \/ Read(c)
    \/ Register(c) \/ Decide(c) \/ New(c) \/ Check(c) \/ Rollback(c) \/ StarterReap(c)

\* A copy and a starter that can do a step do it. No process must stop.
Spec == Init /\ [][Next]_vars /\ \A c \in Copies : WF_vars(Proc(c))

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ cell \in Cells
    /\ \A c \in Copies :
        /\ cpc[c] \in CopySteps
        /\ op[c] \in Ops \cup {None}
        /\ busy[c] \in BOOLEAN /\ seen[c] \in 0..1 /\ rd[c] \in Cells \cup {None}
        /\ sp[c] \in StarterSteps /\ sk[c] \in {"bytes", "closed"}
        /\ result[c] \in Results
    /\ marker \in Copies \cup {None} /\ epoch \in 0..1
    /\ live \in 0..2 /\ skind \in {"bytes", "closed"} /\ sowner \in Copies \cup {None}
    /\ pulled \in BOOLEAN /\ held \in BOOLEAN /\ kills \in 0..Kills
    /\ given \in 0..3 /\ spent \in BOOLEAN
    /\ orphan \in Copies \cup {None} /\ killed \in 0..StreamKills /\ crashed \in BOOLEAN

\* The bytes go out one time at most: to one body function, enumeration, tee,
\* proxy, or read of the stream process.
BytesOnce == given <= 1

\* No copy takes the bytes after a claim or a read used them.
NoBytesAfterUse == [][given' > given => cell \in {"readable", "process"}]_vars

\* One stream process at most is alive, for all the copies.
OneProcess == live <= 1

\* A copy gets "gone" or "released" only after the bytes went out: a stop of
\* a process that had a copy does not take the bytes from the other copies.
\* A read of the stream process fails only after the bytes went out, or
\* after a process killed the stream process.
NoGoneWhileBytes ==
    \A c \in Copies : result[c] \in {"gone", "released", "failed"} => spent

\* The lifetime rules do not stop a stream process that a copy got and did
\* not lock yet: only a kill does, or the end of a stream that a read used.
\* The lock step asks again after a kill: see NoGoneWhileBytes.
KeptForLock == \A c \in Copies : cpc[c] = "stale" => spent \/ killed > 0

\* No start of a stream process writes a crash report.
NoCrash == ~crashed

\* Each operation of a copy that continues ends: no copy waits forever.
ReadEnds == \A c \in Copies : cpc[c] \in Active ~> cpc[c] \in {"done", "stopped"}

\* Each stream process with no use stops: no stream process stays while the
\* cell does not give it.
UselessStops == (live > 0 /\ cell \notin Pointed) ~> (live = 0 \/ cell \in Pointed)
=============================================================================
