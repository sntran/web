----------------------------- MODULE LazyStream -----------------------------
(* The shared state of the copies of one Web.Internal.LazyStream, with     *)
(* copies and starters that stop at each step of a stream read.            *)
(*                                                                         *)
(* A body that has all its bytes has no process until a stream read. Each  *)
(* copy of the struct can be in a different process, and all the copies    *)
(* share one state: one element of an :atomics array, the cell. A copy on  *)
(* a different node does each operation on the node of the array, thus it  *)
(* is one more copy of this module.                                        *)
(*                                                                         *)
(* The operations of a copy:                                               *)
(*   * a claim changes a cell with free bytes to "consumed" (an            *)
(*     enumeration takes the bytes), to "locked" (a body function, a tee,  *)
(*     or a proxy takes the bytes, and keeps the lock), or to "canceled"   *)
(*     (a cancel), with one compare-exchange. The bytes are free in the    *)
(*     cell "readable", and in the cell "process" when no read disturbed   *)
(*     the stream process before its stop;                                 *)
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
(*   * a copy that got the stream process keeps it until it takes its      *)
(*     lock or stops: the lifetime rules do not stop the process for the   *)
(*     stop of its owner while a copy waits for its lock;                  *)
(*   * the first disturb of the stream process (a read, a cancel, a pipe,  *)
(*     or the step "consume body") sets "taken" in the same step: a        *)
(*     disturbed stream gives no bytes to a different reader. A stream     *)
(*     process that stops before a disturb takes no bytes from the other   *)
(*     copies: the lifetime rules stop it with no cancel.                  *)
(*                                                                         *)
(* A copy reads the cell and the registry in one step of this model. The   *)
(* real copy reads the registry and then the cell for a stream read, and   *)
(* the cell and then the registry, and the cell again, for a claim and for *)
(* the state: a stream process registers itself before its starter sets a  *)
(* cell that is not "starting", and a starter or a claim decides again     *)
(* with the key and a compare-exchange.                                    *)
(*                                                                         *)
(* The lifetime rules stop a stream process when its owner stopped and no  *)
(* copy keeps it, or after its end. A different process can also kill a    *)
(* starter or a stream process. A copy that got the stream process, and    *)
(* did not lock it before a kill of the process, gets "failed". A kill of  *)
(* a starter in the start of its stream process can leave that start,      *)
(* which continues with no starter: it registers itself only while no      *)
(* stream process has the key and the bytes are free, else it stops        *)
(* normally in its start, with no crash report.                            *)
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
(* stream process that stopped gives "gone".                               *)
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
\* process that stopped before the read, the second step of the bug
\* "read_then_set", the end, and the stop. Each copy does one operation: a
\* different operation is a different copy.
Active == {"ask", "wait", "poll", "lock", "read", "stale", "set"}

CopySteps == Active \cup {"idle", "done", "stopped"}

\* The steps of the starter of a copy: no starter, the key, the decision
\* with the cell, the start of the stream process, and the state after it.
StarterSteps == {None, "register", "decide", "new", "check"}

VARIABLES
    cell,       \* the state in the :atomics array
    cpc,        \* [Copies -> CopySteps]
    op,         \* [Copies -> Ops \cup {None}]: the operation of the copy
    busy,       \* [Copies -> BOOLEAN]: the copy waits for the starter of the key
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

copyVars == <<cpc, op, busy, seen, result>>
starterVars == <<sp, sk, marker, epoch, kills>>
streamVars == <<live, skind, sowner, pulled, held, orphan, killed, crashed>>
vars == <<cell, given, spent, copyVars, starterVars, streamVars>>

Init ==
    /\ cell = "readable"
    /\ cpc = [c \in Copies |-> "idle"]
    /\ op = [c \in Copies |-> None]
    /\ busy = [c \in Copies |-> FALSE]
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

\* The copy starts a starter and waits for its end. For the bug "today", the
\* copy is the starter: it does the steps itself, with no key.
Spawn(c) ==
    /\ sp' = [sp EXCEPT ![c] = IF Today THEN "decide" ELSE "register"]
    /\ cpc' = [cpc EXCEPT ![c] = "wait"]
    /\ busy' = [busy EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<op, seen, result, sk, marker, epoch, kills>>

\* The copy waits for the end of the starter that has the key.
AwaitKey(c) ==
    /\ cpc' = [cpc EXCEPT ![c] = "wait"]
    /\ busy' = [busy EXCEPT ![c] = TRUE]
    /\ seen' = [seen EXCEPT ![c] = epoch]
    /\ UNCHANGED <<op, result, starterVars>>

\* A stream process stops. A copy in the step "lock" or "read" has that
\* process: it cannot read it. With no stream process, the model forgets
\* the last one.
Stopped ==
    /\ live' = live - 1
    /\ cpc' = [c \in Copies |-> IF cpc[c] \in {"lock", "read"} THEN "stale" ELSE cpc[c]]
    /\ IF live = 1
       THEN skind' = "bytes" /\ sowner' = None /\ pulled' = FALSE /\ held' = FALSE
       ELSE UNCHANGED <<skind, sowner, pulled, held>>

-----------------------------------------------------------------------------
\* The steps of a copy

\* Copy c starts the operation o.
Begin(c, o) ==
    /\ cpc[c] = "idle"
    /\ cpc' = [cpc EXCEPT ![c] = "ask"]
    /\ op' = [op EXCEPT ![c] = o]
    /\ UNCHANGED <<cell, given, spent, busy, seen, result, starterVars, streamVars>>

\* Copy c does its operation with the cell that it finds.
Eval(c) ==
    /\ cpc[c] = "ask"
    /\ \/ \* "starting": the copy waits for the starter, or starts a new one.
          /\ cell \in Starting
          /\ IF Today \/ (Bug = "no_take_over" /\ marker = None)
             THEN /\ cpc' = [cpc EXCEPT ![c] = "poll"]
                  /\ UNCHANGED <<op, busy, seen, result, starterVars>>
             ELSE IF marker # None /\ Bug # "no_key" THEN AwaitKey(c) ELSE Spawn(c)
          /\ UNCHANGED <<cell, given, spent, streamVars>>
       \/ \* A stream read.
          /\ cell \notin Starting /\ op[c] = "read"
          /\ CASE cell = "locked" ->
                    End(c, "locked") /\ UNCHANGED starterVars
               [] live > 0 ->
                    /\ cpc' = [cpc EXCEPT ![c] = "lock"]
                    /\ UNCHANGED <<op, busy, seen, result, starterVars>>
               [] cell = "taken" \/ Found = "gone" ->
                    End(c, "released") /\ UNCHANGED starterVars
               [] OTHER -> Spawn(c)
          /\ UNCHANGED <<cell, given, spent, streamVars>>
       \/ \* A claim. The bug "read_then_set" sets the cell in a second step.
          /\ cell \notin Starting /\ op[c] \in Claims
          /\ CASE Free /\ Bug = "read_then_set" ->
                    /\ cpc' = [cpc EXCEPT ![c] = "set"]
                    /\ UNCHANGED <<cell, given, spent, op, busy, seen, result, pulled, held>>
               [] Free ->
                    /\ cell' = op[c]
                    /\ given' = IF op[c] = "canceled" THEN given ELSE given + 1
                    /\ spent' = TRUE
                    /\ End(c, "ok")
                    /\ UNCHANGED <<pulled, held>>
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
                    /\ UNCHANGED <<cell, given, spent, op, busy, seen, result, pulled, held>>
               [] OTHER ->
                    End(c, Found) /\ UNCHANGED <<cell, given, spent, pulled, held>>
          /\ UNCHANGED <<starterVars, live, skind, sowner, orphan, killed, crashed>>
       \/ \* The state.
          /\ cell \notin Starting /\ op[c] = "state"
          /\ End(c, Found)
          /\ UNCHANGED <<cell, given, spent, starterVars, streamVars>>

\* The second step of the bug "read_then_set".
ClaimSet(c) ==
    /\ cpc[c] = "set"
    /\ cell' = op[c]
    /\ given' = IF op[c] = "canceled" THEN given ELSE given + 1
    /\ spent' = TRUE
    /\ End(c, "ok")
    /\ UNCHANGED <<starterVars, streamVars>>

\* The copy gets the end of the starter that it waits for: the monitor of
\* its own starter, and then the monitor of the starter that had the key.
Wake(c) ==
    /\ cpc[c] = "wait" /\ sp[c] = None
    /\ (~busy[c] \/ marker = None \/ epoch # seen[c])
    /\ cpc' = [cpc EXCEPT ![c] = "ask"]
    /\ busy' = [busy EXCEPT ![c] = FALSE]
    /\ seen' = [seen EXCEPT ![c] = 0]
    /\ UNCHANGED <<cell, given, spent, op, result, starterVars, streamVars>>

\* The bug "today": the copy reads the cell again until it is not "starting".
Poll(c) ==
    /\ cpc[c] = "poll" /\ cell \notin Starting
    /\ cpc' = [cpc EXCEPT ![c] = "ask"]
    /\ UNCHANGED <<cell, given, spent, op, busy, seen, result, starterVars, streamVars>>

\* The bug "today": the time limit of the wait. It comes only after the
\* start stopped: a start that continues ends before it.
Timeout(c) ==
    /\ Today /\ cpc[c] = "poll" /\ cell \in Starting
    /\ \A x \in Copies : sp[x] = None
    /\ End(c, "gone")
    /\ UNCHANGED <<cell, given, spent, starterVars, streamVars>>

\* The copy locks the stream process and disturbs it: a read, or the
\* disturb of the step "consume body" and of a pipe. The copy keeps the
\* lock. The first disturb takes the bytes and sets "taken" in the same
\* step: a disturbed stream gives no bytes to a different reader. The bug
\* "pull_keeps_bytes" does not set "taken", and the bug
\* "disturb_keeps_bytes" sets it only when the chunks come.
Lock(c) ==
    /\ cpc[c] \in {"lock", "stale"}
    /\ CASE cpc[c] = "stale" ->
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
              /\ UNCHANGED <<op, busy, seen, result>>
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
    /\ UNCHANGED <<cell, given, spent, result, sk, marker, epoch, kills, streamVars>>

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
    /\ UNCHANGED <<cell, given, spent, cpc, op, result, sk, kills, streamVars>>

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
    /\ IF live = 0 /\ (cell \in {"starting", "process"} \/ Bug = "unchecked_start")
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
            /\ cell' = IF cell = "starting" THEN "readable" ELSE cell
       ELSE /\ cell' = CASE cell = "starting" /\ Bug = "held_at_start" -> "taken"
                         [] cell = "starting" -> "process"
                         [] cell = "starting_closed" -> "taken"
                         [] OTHER -> cell
            /\ UNCHANGED <<cpc, streamVars>>
    /\ Exit(c)
    /\ UNCHANGED <<given, spent, op, busy, seen, result, epoch, kills>>

\* A process kills the starter of copy c before its end. The registry
\* removes its key. A kill in the start of the stream process of the bytes
\* can leave that start, which continues with no starter.
StarterStop(c, continues) ==
    /\ sp[c] \in {"register", "decide", "new", "check"} /\ ~Today
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
    /\ UNCHANGED <<cell, given, spent, op, busy, seen, result, starterVars, orphan, killed,
                   crashed>>

\* A different process kills the stream process.
StreamKill ==
    /\ live > 0 /\ killed < StreamKills
    /\ killed' = killed + 1
    /\ Stopped
    /\ UNCHANGED <<cell, given, spent, op, busy, seen, result, starterVars, orphan, crashed>>

Next ==
    \/ \E c \in Copies :
        \/ \E o \in Ops : Begin(c, o)
        \/ Eval(c) \/ ClaimSet(c) \/ Wake(c) \/ Poll(c) \/ Timeout(c) \/ Lock(c)
        \/ Read(c) \/ Drop(c) \/ CopyStop(c)
        \/ Register(c) \/ Decide(c) \/ New(c) \/ Check(c)
        \/ \E continues \in BOOLEAN : StarterStop(c, continues)
    \/ StreamStop \/ StreamKill \/ OrphanStart
    \/ UNCHANGED vars

\* The steps of copy c and of its starter. At each time, one of them at
\* most can do a step: the copy waits during the work of its starter.
Proc(c) ==
    \/ Eval(c) \/ ClaimSet(c) \/ Wake(c) \/ Poll(c) \/ Lock(c) \/ Read(c)
    \/ Register(c) \/ Decide(c) \/ New(c) \/ Check(c)

\* A copy and a starter that can do a step do it. No process must stop.
Spec == Init /\ [][Next]_vars /\ \A c \in Copies : WF_vars(Proc(c))

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ cell \in Cells
    /\ \A c \in Copies :
        /\ cpc[c] \in CopySteps
        /\ op[c] \in Ops \cup {None}
        /\ busy[c] \in BOOLEAN /\ seen[c] \in 0..1
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
    \A c \in Copies :
        /\ result[c] \in {"gone", "released"} => spent
        /\ result[c] = "failed" => spent \/ killed > 0

\* No start of a stream process writes a crash report.
NoCrash == ~crashed

\* Each operation of a copy that continues ends: no copy waits forever.
ReadEnds == \A c \in Copies : cpc[c] \in Active ~> cpc[c] \in {"done", "stopped"}
=============================================================================
