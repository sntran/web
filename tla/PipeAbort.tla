------------------------------ MODULE PipeAbort ------------------------------
(* The abort algorithm of the signal of a pipe of Web.ReadableStream:       *)
(* WritableStreamAbort of the destination, and then ReadableStreamCancel of *)
(* the source.                                                              *)
(*                                                                          *)
(* The process of the pipe sends the abort to the process of the           *)
(* destination. The worker of the destination runs the abort callback of   *)
(* the sink. The destination tells the pipe when the callback returned:    *)
(* the notice. Then the pipe sends the cancel to the source. A destination *)
(* that cannot call the callback now (a write is in flight, or the start   *)
(* is not complete) sends the notice at once. The reply of the abort comes *)
(* when the callback is complete, or at the time limit of the callback.    *)
(*                                                                          *)
(* Each pair of processes has a channel that keeps the sequence of its     *)
(* messages. Two channels have no sequence between them.                   *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one *)
(* rule of the design.                                                     *)
EXTENDS Naturals, Sequences

CONSTANTS
    Bug     \* "none", or the name of a rule to remove

VARIABLES
    ready,     \* TRUE when the destination can call the callback at once
    pipe,      \* "start", "steps" (it waits for the notice or the reply),
               \* "actions" (it waits for the reply), or "done"
    toDest,    \* the messages from the pipe to the destination
    toPipe,    \* the messages from the destination to the pipe
    direct,    \* the messages from the worker to the pipe
    toStream,  \* the messages from the worker to the destination
    worker,    \* "none", "waits" (for the operation in flight), "running",
               \* "returned", "done", or "killed"
    notice,    \* TRUE while the callback of the worker has the notice
    pending,   \* TRUE while the destination did not reply to the abort
    reply,     \* TRUE after the pipe got the reply of the abort
    returned,  \* TRUE after the callback returned
    cancelled  \* TRUE after the source got its cancel

vars == <<ready, pipe, toDest, toPipe, direct, toStream, worker, notice,
          pending, reply, returned, cancelled>>

Init ==
    /\ ready \in BOOLEAN
    /\ pipe = "start"
    /\ toDest = <<>> /\ toPipe = <<>> /\ direct = <<>> /\ toStream = <<>>
    /\ worker = "none" /\ notice = FALSE /\ pending = FALSE
    /\ reply = FALSE /\ returned = FALSE /\ cancelled = FALSE

\* The pipe sends the abort. It sends the cancel when it has the notice.
SendAbort ==
    /\ pipe = "start"
    /\ toDest' = Append(toDest, "abort")
    /\ IF Bug = "parallel"
          THEN pipe' = "actions" /\ cancelled' = TRUE
          ELSE pipe' = "steps" /\ UNCHANGED cancelled
    /\ UNCHANGED <<ready, toPipe, direct, toStream, worker, notice, pending,
                   reply, returned>>

\* The destination gets the abort. It starts the callback, or it sends the
\* notice at once.
DestAbort ==
    /\ toDest # <<>>
    /\ toDest' = Tail(toDest)
    /\ pending' = TRUE
    /\ IF ready
          THEN /\ worker' = "running" /\ notice' = TRUE
               /\ UNCHANGED toPipe
          ELSE /\ worker' = "waits" /\ UNCHANGED notice
               /\ toPipe' = IF Bug = "no_early_notice" THEN toPipe
                            ELSE Append(toPipe, "notice")
    /\ UNCHANGED <<ready, pipe, direct, toStream, reply, returned, cancelled>>

\* The operation in flight is complete: the callback starts.
OperationEnds ==
    /\ worker = "waits"
    /\ worker' = "running"
    /\ UNCHANGED <<ready, pipe, toDest, toPipe, direct, toStream, notice,
                   pending, reply, returned, cancelled>>

\* The callback returns. The worker tells the destination, which tells the
\* pipe.
Return ==
    /\ worker = "running"
    /\ worker' = "returned" /\ returned' = TRUE /\ notice' = FALSE
    /\ IF notice /\ Bug = "direct_notice"
          THEN direct' = Append(direct, "notice") /\ UNCHANGED toStream
          ELSE IF notice
                  THEN toStream' = Append(toStream, "returned") /\ UNCHANGED direct
                  ELSE UNCHANGED <<toStream, direct>>
    /\ UNCHANGED <<ready, pipe, toDest, toPipe, pending, reply, cancelled>>

\* The promise of the callback settles. The worker gives the result.
Finish ==
    /\ worker = "returned"
    /\ worker' = "done"
    /\ toStream' = Append(toStream, "result")
    /\ UNCHANGED <<ready, pipe, toDest, toPipe, direct, notice, pending, reply,
                   returned, cancelled>>

\* The time limit of the callback: the destination stops the worker, and
\* replies to the pipe. The messages of the worker can still come.
TimeLimit ==
    /\ pending /\ worker \in {"running", "returned", "done"}
    /\ worker' = "killed" /\ notice' = FALSE /\ pending' = FALSE
    /\ toPipe' = Append(toPipe, "reply")
    /\ UNCHANGED <<ready, pipe, toDest, direct, toStream, reply, returned, cancelled>>

\* The destination gets the next message of the worker. A notice goes to the
\* pipe only while the abort has no reply.
DestFromWorker ==
    /\ toStream # <<>>
    /\ toStream' = Tail(toStream)
    /\ IF Head(toStream) = "returned"
          THEN /\ toPipe' = IF pending \/ Bug = "relay_unchecked"
                            THEN Append(toPipe, "notice") ELSE toPipe
               /\ UNCHANGED pending
          ELSE /\ toPipe' = IF pending THEN Append(toPipe, "reply") ELSE toPipe
               /\ pending' = FALSE
    /\ UNCHANGED <<ready, pipe, toDest, direct, worker, notice, reply, returned,
                   cancelled>>

\* The pipe gets a message. The notice, or the reply before the notice, ends
\* the wait of the pipe: it sends the cancel. A notice after the end of the
\* wait has no effect.
Gets(m) ==
    /\ IF m = "reply" THEN reply' = TRUE ELSE UNCHANGED reply
    /\ IF pipe = "steps"
          THEN /\ cancelled' = TRUE
               /\ pipe' = "actions"
          ELSE UNCHANGED <<pipe, cancelled>>

PipeGets ==
    /\ toPipe # <<>>
    /\ toPipe' = Tail(toPipe)
    /\ Bug = "keeps_waiting" /\ pipe = "steps" => Head(toPipe) = "notice"
    /\ Gets(Head(toPipe))
    /\ UNCHANGED <<ready, toDest, direct, toStream, worker, notice, pending, returned>>

PipeGetsDirect ==
    /\ direct # <<>>
    /\ direct' = Tail(direct)
    /\ Gets(Head(direct))
    /\ UNCHANGED <<ready, toDest, toPipe, toStream, worker, notice, pending, returned>>

\* The pipe has the results of the two actions.
PipeEnds ==
    /\ pipe = "actions" /\ reply
    /\ pipe' = "done"
    /\ UNCHANGED <<ready, toDest, toPipe, direct, toStream, worker, notice,
                   pending, reply, returned, cancelled>>

Next ==
    \/ SendAbort \/ DestAbort \/ OperationEnds \/ Return \/ Finish \/ TimeLimit
    \/ DestFromWorker \/ PipeGets \/ PipeGetsDirect \/ PipeEnds
    \/ UNCHANGED vars

Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(SendAbort) /\ WF_vars(DestAbort) /\ WF_vars(OperationEnds)
    /\ WF_vars(Return) /\ WF_vars(Finish) /\ WF_vars(TimeLimit)
    /\ WF_vars(DestFromWorker) /\ WF_vars(PipeGets) /\ WF_vars(PipeGetsDirect)
    /\ WF_vars(PipeEnds)

-----------------------------------------------------------------------------
\* Properties

Messages(s) == \A i \in 1..Len(s) : s[i] \in {"abort", "notice", "reply", "returned", "result"}

TypeOK ==
    /\ ready \in BOOLEAN
    /\ pipe \in {"start", "steps", "actions", "done"}
    /\ Messages(toDest) /\ Messages(toPipe) /\ Messages(direct) /\ Messages(toStream)
    /\ worker \in {"none", "waits", "running", "returned", "done", "killed"}
    /\ notice \in BOOLEAN /\ pending \in BOOLEAN /\ reply \in BOOLEAN
    /\ returned \in BOOLEAN /\ cancelled \in BOOLEAN

\* A destination that can call the abort callback at once calls it before
\* the source gets its cancel: the cancel comes after the return of the
\* callback, or after its time limit.
AbortFirst == (ready /\ cancelled) => (returned \/ worker = "killed")

\* No notice comes after the reply of the abort: the pipe takes each
\* message of the destination while it waits.
NoLateNotice ==
    reply => /\ \A i \in 1..Len(toPipe) : toPipe[i] # "notice"
             /\ \A i \in 1..Len(direct) : direct[i] # "notice"

\* The source can get its cancel while a write of the destination is in
\* flight, as in JavaScript. The model check finds a state that does not
\* have this property: such a state is possible.
CancelWaitsForWrite == cancelled => worker # "waits"

\* The pipe ends, also when the callback does not return.
Progress == <>(pipe = "done")
=============================================================================
