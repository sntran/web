-------------------------------- MODULE PipeTo --------------------------------
(* ReadableStreamPipeTo of Web.ReadableStream: the loop of reads and writes  *)
(* of the process of the pipe, the conditions that end it, the shutdown,    *)
(* and the release of the two locks.                                        *)
(*                                                                          *)
(* The source enqueues Chunks chunks and closes, or it errors. The          *)
(* destination writes the chunks one at a time, and it can error. The       *)
(* destination can be closed when the pipe starts. The signal can abort at  *)
(* each time. The pipe reads one chunk when the destination is ready, and   *)
(* writes it. The pipe learns of a close or an error of a stream from its   *)
(* promise `closed`: a notice that comes later. A read that is in progress  *)
(* gives a chunk that the source has, also after the close of the source.   *)
(*                                                                          *)
(* The shutdown waits for the writes of the pipe while the destination is   *)
(* writable. Then it does its action (a close, an abort, or a cancel, as    *)
(* the options preventClose, preventAbort, and preventCancel permit), and   *)
(* releases the two locks.                                                  *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design. "lose_last_chunk" and "dest_closed_no_cancel" are    *)
(* defects that version 0.5.0 corrected.                                    *)
EXTENDS Naturals

CONSTANTS
    Chunks,  \* the number of chunks of the source
    HWM,     \* the high water mark of the destination
    Opts,    \* the actions that the options prevent: a subset of
             \* {"close", "abort", "cancel"}
    Bug      \* "none", or the name of a rule to remove

opts == Opts

VARIABLES
    endless,   \* TRUE for a source that does not close by itself
    sState,    \* the source: "readable", "closed", or "errored"
    left,      \* the chunks that the source did not enqueue
    avail,     \* the chunks in the queue of the source
    dInit,     \* the state of the destination when the pipe starts
    dState,    \* the destination: "writable", "closing", "closed", "erroring",
               \* or "errored"
    dQueue,    \* the writes of the pipe that the sink did not complete
    written,   \* the chunks that the sink got
    signal,    \* TRUE after the abort of the signal
    pipe,      \* "start", "run", "waits" (for the writes), "acts", or "done"
    action,    \* the action of the shutdown, or "done" after it
    chose,     \* the action that the shutdown chose
    result,    \* "none", "ok", "error", or "aborted"
    reading,   \* TRUE while a read of the pipe is in progress
    reply,     \* the answer of the read: "none", "chunk", "done", or "error"
    sNote,     \* the notice of the source: "none", "closed", or "errored"
    dNote,     \* the notice of the destination: "none" or "errored"
    locked,    \* TRUE while the pipe holds the two locks
    effects    \* the actions that the pipe did, and "lost" when its abort
               \* rejected a write of the pipe

vars == <<endless, sState, left, avail, dInit, dState, dQueue, written,
          signal, pipe, action, chose, result, reading, reply, sNote, dNote, locked,
          effects>>

pipeVars == <<pipe, action, chose, result, reading, reply, sNote, dNote, locked, effects>>

Init ==
    /\ endless \in BOOLEAN
    /\ sState = "readable" /\ left = Chunks /\ avail = 0
    /\ dInit \in {"writable", "closed", "errored"} /\ dState = dInit
    /\ dQueue = 0 /\ written = 0 /\ signal = FALSE
    /\ pipe = "start" /\ action = "none" /\ chose = "none" /\ result = "none"
    /\ reading = FALSE /\ reply = "none" /\ sNote = "none"
    \* The promise `closed` of an errored destination rejects at once.
    /\ dNote = IF dInit = "errored" THEN "errored" ELSE "none"
    /\ locked = TRUE /\ effects = {}

\* The action for a condition, with the options. "abort_cancel" is the abort
\* algorithm of the signal.
Allowed(a) == a \notin opts \/ (a = "close" /\ Bug = "ignore_prevent_close")

\* -------------------------------------------------------------------------
\* The streams

Enqueue ==
    /\ pipe # "start" /\ sState = "readable" /\ left > 0
    /\ left' = left - 1 /\ avail' = avail + 1
    /\ UNCHANGED <<endless, sState, dInit, dState, dQueue, written, signal, pipeVars>>

SourceClose ==
    /\ pipe # "start" /\ sState = "readable" /\ left = 0 /\ ~endless
    /\ sState' = "closed" /\ sNote' = "closed"
    /\ UNCHANGED <<endless, left, avail, dInit, dState, dQueue, written, signal,
                   pipe, action, chose, result, reading, reply, dNote, locked, effects>>

SourceError ==
    /\ pipe # "start" /\ sState = "readable"
    /\ sState' = "errored" /\ avail' = 0 /\ sNote' = "errored"
    /\ UNCHANGED <<endless, left, dInit, dState, dQueue, written, signal,
                   pipe, action, chose, result, reading, reply, dNote, locked, effects>>

\* The source answers the read of the pipe.
SourceAnswers ==
    /\ reading /\ reply = "none"
    /\ avail > 0 \/ sState # "readable"
    /\ IF avail > 0
          THEN reply' = "chunk" /\ avail' = avail - 1
          ELSE /\ reply' = (IF sState = "errored" THEN "error" ELSE "done")
               /\ UNCHANGED avail
    /\ UNCHANGED <<endless, sState, left, dInit, dState, dQueue, written, signal,
                   pipe, action, chose, result, reading, sNote, dNote, locked, effects>>

\* The sink completes one write. A close completes after the writes.
SinkWrites ==
    /\ dQueue > 0 /\ dState \in {"writable", "closing", "erroring"}
    /\ dQueue' = dQueue - 1 /\ written' = written + 1
    /\ UNCHANGED <<endless, sState, left, avail, dInit, dState, signal, pipeVars>>

SinkCloses ==
    /\ dState = "closing" /\ dQueue = 0
    /\ dState' = "closed"
    /\ UNCHANGED <<endless, sState, left, avail, dInit, dQueue, written, signal, pipeVars>>

\* WritableStreamFinishErroring: the write in flight is complete.
FinishErroring ==
    /\ dState = "erroring" /\ dQueue = 0
    /\ dState' = "errored"
    /\ UNCHANGED <<endless, sState, left, avail, dInit, dQueue, written, signal, pipeVars>>

DestError ==
    /\ pipe # "start" /\ dState = "writable"
    /\ dState' = "errored" /\ dQueue' = 0 /\ dNote' = "errored"
    /\ UNCHANGED <<endless, sState, left, avail, dInit, written, signal,
                   pipe, action, chose, result, reading, reply, sNote, locked, effects>>

SignalAborts ==
    /\ pipe # "start" /\ ~signal
    /\ signal' = TRUE
    /\ UNCHANGED <<endless, sState, left, avail, dInit, dState, dQueue, written, pipeVars>>

\* -------------------------------------------------------------------------
\* The pipe

\* The shutdown: it waits for the writes of the pipe while the destination
\* is writable, and then it acts.
Shutdown(a, r) ==
    /\ action' = a /\ chose' = a /\ result' = r
    /\ pipe' = IF dState = "writable" /\ dQueue > 0 /\ Bug # "no_wait_writes"
                  THEN "waits" ELSE "acts"

\* The conditions of the Standard: an error of the source (forward), an
\* error of the destination (backward), a close of the source (forward),
\* and a closed destination (backward).
SourceErrors == Shutdown(IF Allowed("abort") THEN "abort" ELSE "none", "error")
DestErrors == Shutdown(IF Allowed("cancel") THEN "cancel" ELSE "none", "error")
SourceCloses == Shutdown(IF Allowed("close") THEN "close" ELSE "none", "ok")
DestCloses == Shutdown(IF Allowed("cancel") THEN "cancel" ELSE "none", "error")

\* The checks when the pipe starts, in the sequence of the Standard.
Start ==
    /\ pipe = "start"
    /\ CASE dState = "errored" ->
              DestErrors /\ dNote' = "none"
         [] dState = "closed" /\ Bug # "dest_closed_no_cancel" ->
              DestCloses /\ UNCHANGED dNote
         [] OTHER ->
              pipe' = "run" /\ UNCHANGED <<action, chose, result, dNote>>
    /\ UNCHANGED <<endless, sState, left, avail, dInit, dState, dQueue, written,
                   signal, reading, reply, sNote, locked, effects>>

\* The pipe reads one chunk when the destination is ready: its queue is
\* below the high water mark.
Read ==
    /\ pipe = "run" /\ ~reading /\ dState = "writable"
    /\ dQueue < HWM \/ Bug = "no_flow_control"
    /\ reading' = TRUE
    /\ UNCHANGED <<endless, sState, left, avail, dInit, dState, dQueue, written,
                   signal, pipe, action, chose, result, reply, sNote, dNote, locked, effects>>

\* The pipe gets the answer of its read. It writes a chunk, also while the
\* shutdown waits. The end of the source is its close.
TakeReply ==
    /\ reading /\ reply # "none"
    /\ reading' = FALSE /\ reply' = "none"
    /\ IF reply = "chunk" /\ pipe \in {"run", "waits"} /\ dState = "writable"
          THEN dQueue' = dQueue + 1 ELSE UNCHANGED dQueue
    /\ IF reply = "done" /\ pipe = "run"
          THEN SourceCloses
          ELSE UNCHANGED <<pipe, action, chose, result>>
    /\ UNCHANGED <<endless, sState, left, avail, dInit, dState, written, signal,
                   sNote, dNote, locked, effects>>

\* The pipe gets the notice of the source. A read in progress gives the
\* chunk that the source has: the pipe waits for its answer. A source that
\* closed with chunks in its queue gives them to the next reads.
TakeSourceNote ==
    /\ pipe # "start" /\ sNote # "none"
    /\ sNote' = "none"
    /\ CASE pipe # "run" ->
              UNCHANGED <<pipe, action, chose, result>>
         [] sNote = "errored" ->
              SourceErrors
         [] Bug = "lose_last_chunk" \/ (~reading /\ avail = 0) ->
              SourceCloses
         [] OTHER ->
              UNCHANGED <<pipe, action, chose, result>>
    /\ UNCHANGED <<endless, sState, left, avail, dInit, dState, dQueue, written,
                   signal, reading, reply, dNote, locked, effects>>

TakeDestNote ==
    /\ pipe # "start" /\ dNote # "none"
    /\ dNote' = "none"
    /\ IF pipe = "run" THEN DestErrors ELSE UNCHANGED <<pipe, action, chose, result>>
    /\ UNCHANGED <<endless, sState, left, avail, dInit, dState, dQueue, written,
                   signal, reading, reply, sNote, locked, effects>>

\* The abort algorithm of the signal.
TakeSignal ==
    /\ signal /\ pipe = "run" /\ Bug # "ignore_signal"
    /\ LET a == IF Allowed("abort") /\ Allowed("cancel") THEN "abort_cancel"
                ELSE IF Allowed("abort") THEN "abort"
                ELSE IF Allowed("cancel") THEN "cancel" ELSE "none"
       IN Shutdown(a, "aborted")
    /\ UNCHANGED <<endless, sState, left, avail, dInit, dState, dQueue, written,
                   signal, reading, reply, sNote, dNote, locked, effects>>

\* The writes of the pipe are complete, or the destination is not writable.
WritesDone ==
    /\ pipe = "waits" /\ (dQueue = 0 \/ dState # "writable")
    /\ pipe' = "acts"
    /\ UNCHANGED <<endless, sState, left, avail, dInit, dState, dQueue, written,
                   signal, action, chose, result, reading, reply, sNote, dNote, locked, effects>>

\* The action: an abort waits for the write in flight, and rejects the
\* writes in the queue. A cancel discards the chunks of the source.
Act ==
    /\ pipe = "acts" /\ action # "done"
    /\ LET abort == action \in {"abort", "abort_cancel"} /\ dState \in {"writable", "closing"}
           cancel == action \in {"cancel", "abort_cancel"} /\ sState = "readable"
           close == action = "close" /\ dState = "writable"
       IN /\ dState' = CASE abort /\ dQueue > 0 -> "erroring"
                          [] abort -> "errored"
                          [] close -> "closing"
                          [] OTHER -> dState
          /\ dQueue' = IF abort /\ dQueue > 1 THEN 1 ELSE dQueue
          /\ sState' = IF cancel THEN "closed" ELSE sState
          /\ avail' = IF cancel THEN 0 ELSE avail
          /\ effects' = effects
                \cup (IF abort THEN {"abort"} ELSE {})
                \cup (IF abort /\ dQueue > 1 THEN {"lost"} ELSE {})
                \cup (IF cancel THEN {"cancel"} ELSE {})
                \cup (IF close THEN {"close"} ELSE {})
    \* WritableStreamDefaultWriterCloseWithErrorPropagation: the close of an
    \* errored destination rejects with its error.
    /\ result' = IF action = "close" /\ dState = "errored" THEN "error" ELSE result
    /\ action' = "done"
    /\ UNCHANGED <<endless, left, dInit, written, signal, pipe, chose,
                   reading, reply, sNote, dNote, locked>>

\* The action is complete: the pipe releases the two locks. A close
\* completes after the writes of the destination.
Finish ==
    /\ pipe = "acts" /\ action = "done" /\ dState \notin {"closing", "erroring"}
    /\ pipe' = "done"
    /\ locked' = (Bug = "keep_lock")
    /\ UNCHANGED <<endless, sState, left, avail, dInit, dState, dQueue, written,
                   signal, action, chose, result, reading, reply, sNote, dNote, effects>>

Next ==
    \/ Enqueue \/ SourceClose \/ SourceError \/ SourceAnswers
    \/ SinkWrites \/ SinkCloses \/ FinishErroring \/ DestError \/ SignalAborts
    \/ Start \/ Read \/ TakeReply \/ TakeSourceNote \/ TakeDestNote \/ TakeSignal
    \/ WritesDone \/ Act \/ Finish
    \/ UNCHANGED vars

\* The source and the sink do their work. An error and the signal can come,
\* or not.
Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(Enqueue) /\ WF_vars(SourceClose) /\ WF_vars(SourceAnswers)
    /\ WF_vars(SinkWrites) /\ WF_vars(SinkCloses) /\ WF_vars(FinishErroring)
    /\ WF_vars(Start) /\ WF_vars(Read) /\ WF_vars(TakeReply) /\ WF_vars(TakeSourceNote)
    /\ WF_vars(TakeDestNote) /\ WF_vars(TakeSignal) /\ WF_vars(WritesDone)
    /\ WF_vars(Act) /\ WF_vars(Finish)

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ endless \in BOOLEAN
    /\ sState \in {"readable", "closed", "errored"}
    /\ left \in 0..Chunks /\ avail \in 0..Chunks
    /\ dInit \in {"writable", "closed", "errored"}
    /\ dState \in {"writable", "closing", "closed", "erroring", "errored"}
    /\ dQueue \in 0..Chunks /\ written \in 0..Chunks /\ signal \in BOOLEAN
    /\ pipe \in {"start", "run", "waits", "acts", "done"}
    /\ action \in {"none", "close", "abort", "cancel", "abort_cancel", "done"}
    /\ chose \in {"none", "close", "abort", "cancel", "abort_cancel"}
    /\ result \in {"none", "ok", "error", "aborted"}
    /\ reading \in BOOLEAN /\ reply \in {"none", "chunk", "done", "error"}
    /\ sNote \in {"none", "closed", "errored"} /\ dNote \in {"none", "errored"}
    /\ locked \in BOOLEAN /\ effects \subseteq {"close", "abort", "cancel", "lost"}

\* The flow control: the pipe writes only when the destination is ready.
QueueBound == dQueue <= HWM

\* A pipe that ends with the close of the source gave each chunk to the
\* sink, unless the destination errored: the error rejects the writes.
AllChunks == (pipe = "done" /\ result = "ok" /\ dState # "errored") => written = Chunks

\* The shutdown waits for the writes: the abort of the pipe rejects no write
\* of the pipe. With the high water mark 1, the only write is in flight, and
\* the abort waits for it also with no rule of the pipe.
NoLostWrite == "lost" \notin effects

\* A destination that is closed or errored when the pipe starts cancels the
\* source, unless preventCancel.
ClosedDestCancels ==
    (pipe # "start" /\ dInit # "writable" /\ "cancel" \notin opts) => chose = "cancel"

\* The options prevent their actions.
PreventsActions ==
    /\ "close" \in opts => "close" \notin effects
    /\ "abort" \in opts => "abort" \notin effects
    /\ "cancel" \in opts => "cancel" \notin effects

\* The pipe releases its two locks when it ends.
LocksReleased == pipe = "done" => ~locked

\* A result "aborted" comes only from the signal.
AbortedBySignal == result = "aborted" => signal

\* The pipe ends when the source ends, and after the abort of the signal.
Progress ==
    /\ (sState # "readable" \/ dState \in {"closed", "errored"}) ~> pipe = "done"
    /\ signal ~> pipe = "done"
=============================================================================
