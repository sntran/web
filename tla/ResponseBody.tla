---------------------------- MODULE ResponseBody ----------------------------
(* The body of a response of Web.Dispatcher.HTTP that the process of the  *)
(* request holds.                                                          *)
(*                                                                          *)
(* The worker reads the connection, and sends each chunk to the process of  *)
(* the request, the holder. The holder keeps the chunks in its buffer       *)
(* until a reader starts a stream read. Then it gives each chunk to the     *)
(* stream when the queue of the stream has space. The worker sends a chunk  *)
(* only while the buffer is below its limit: the buffer counts the chunks   *)
(* that have no credit, and a chunk gets its credit when it leaves the      *)
(* buffer. This is the backpressure. The worker is linked to the holder,    *)
(* and the stream monitors the holder.                                      *)
(*                                                                          *)
(* A body that is complete 1 ms after its headers has no process: it is in  *)
(* the struct of the response, and this module does not apply to it.       *)
(*                                                                          *)
(* The module shows that the reader gets the full body or an error, also    *)
(* when one of the two processes of the request stops with no message, and  *)
(* that a cancel stops the worker: the connection does not stay.            *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design.                                                      *)
EXTENDS Naturals

CONSTANTS
    Chunks,   \* the number of chunks of the full body
    Limit,    \* the number of chunks that the buffer and the queue keep
    Bug       \* "none", or the name of a rule to remove

VARIABLES
    worker,     \* "running", "done", "failed", "crashed", or "stopped"
    holder,     \* "alive", "crashed", or "stopped"
    ended,      \* the end that the holder knows: "no", "done", or "error"
    produced,   \* the number of chunks that the worker sent to the holder
    buffer,     \* the number of chunks in the holder, with no credit
    queue,      \* the number of chunks in the queue of the stream
    stream,     \* "none", "readable", "closed", "errored", or "cancelled"
    got,        \* the number of chunks that the reader has
    result      \* the end that the reader got: "none", "done", or "error"

vars == <<worker, holder, ended, produced, buffer, queue, stream, got, result>>

Init ==
    /\ worker = "running"
    /\ holder = "alive"
    /\ ended = "no"
    /\ produced = 0
    /\ buffer = 0
    /\ queue = 0
    /\ stream = "none"
    /\ got = 0
    /\ result = "none"

\* The worker sends a chunk while the buffer of the holder is below its
\* limit. This is the backpressure.
WorkerData ==
    /\ worker = "running" /\ holder = "alive" /\ produced < Chunks
    /\ buffer < Limit \/ Bug = "no_backpressure"
    /\ produced' = produced + 1
    /\ buffer' = buffer + 1
    /\ UNCHANGED <<worker, holder, ended, queue, stream, got, result>>

\* The worker read the full body, and tells the holder.
WorkerDone ==
    /\ worker = "running" /\ holder = "alive" /\ produced = Chunks
    /\ worker' = "done"
    /\ ended' = "done"
    /\ UNCHANGED <<holder, produced, buffer, queue, stream, got, result>>

\* The connection fails, or the body cannot be decoded. The worker tells
\* the holder.
WorkerFail ==
    /\ worker = "running" /\ holder = "alive"
    /\ worker' = "failed"
    /\ ended' = "error"
    /\ UNCHANGED <<holder, produced, buffer, queue, stream, got, result>>

\* One of the two processes stops with no message, for example because a
\* different process kills it. The model has one such stop at most. The
\* link stops the worker with the holder.
WorkerCrash ==
    /\ worker = "running" /\ holder = "alive"
    /\ worker' = "crashed"
    /\ UNCHANGED <<holder, ended, produced, buffer, queue, stream, got, result>>

HolderCrash ==
    /\ holder = "alive" /\ worker # "crashed"
    /\ holder' = "crashed"
    /\ worker' = IF worker = "running" THEN "stopped" ELSE worker
    /\ UNCHANGED <<ended, produced, buffer, queue, stream, got, result>>

\* The holder gets the exit of the worker as a message: a worker that
\* stopped before the end gives an error.
HolderSeesWorkerCrash ==
    /\ Bug # "worker_exit_ignored"
    /\ holder = "alive" /\ worker = "crashed" /\ ended = "no"
    /\ ended' = "error"
    /\ UNCHANGED <<worker, holder, produced, buffer, queue, stream, got, result>>

\* The reader starts a stream read: the stream exists from this time.
ReaderStart ==
    /\ stream = "none" /\ result = "none"
    /\ stream' = "readable"
    /\ UNCHANGED <<worker, holder, ended, produced, buffer, queue, got, result>>

\* The holder gives a chunk to the stream when the queue has space. The
\* chunk gets its credit: the worker can send one more.
HolderForward ==
    /\ holder = "alive" /\ stream = "readable" /\ buffer > 0 /\ queue < Limit
    /\ buffer' = buffer - 1
    /\ queue' = queue + 1
    /\ UNCHANGED <<worker, holder, ended, produced, stream, got, result>>

\* At the end of the body, the holder closes the stream, and stops. A
\* stream that closes with chunks in its queue stays readable until a read
\* takes the last chunk.
HolderClose ==
    /\ holder = "alive" /\ stream = "readable" /\ buffer = 0
    /\ ended = "done" \/ (Bug = "close_on_failure" /\ ended = "error")
    /\ stream' = "closed"
    /\ holder' = "stopped"
    /\ UNCHANGED <<worker, ended, produced, buffer, queue, got, result>>

\* A failure of the body puts the stream in the errored state.
HolderFail ==
    /\ Bug # "close_on_failure"
    /\ holder = "alive" /\ stream = "readable" /\ ended = "error"
    /\ stream' = "errored"
    /\ queue' = 0
    /\ holder' = "stopped"
    /\ UNCHANGED <<worker, ended, produced, buffer, got, result>>

\* The stream monitors the holder. A holder that stops before the end of
\* the stream puts the stream in the errored state.
StreamSeesHolderCrash ==
    /\ Bug # "no_source_watch"
    /\ holder = "crashed" /\ stream = "readable"
    /\ stream' = "errored"
    /\ queue' = 0
    /\ UNCHANGED <<worker, holder, ended, produced, buffer, got, result>>

\* The reader takes a chunk from the queue.
ReaderRead ==
    /\ result = "none" /\ stream \in {"readable", "closed"} /\ queue > 0
    /\ got' = got + 1
    /\ queue' = queue - 1
    /\ UNCHANGED <<worker, holder, ended, produced, buffer, stream, result>>

\* The reader gets the end of the stream.
ReaderEnd ==
    /\ result = "none" /\ queue = 0 /\ stream \in {"closed", "errored"}
    /\ result' = IF stream = "closed" THEN "done" ELSE "error"
    /\ UNCHANGED <<worker, holder, ended, produced, buffer, queue, stream, got>>

\* The reader stops. The stream is cancelled.
ReaderStop ==
    /\ result = "none" /\ stream = "readable"
    /\ stream' = "cancelled"
    /\ queue' = 0
    /\ result' = "error"
    /\ UNCHANGED <<worker, holder, ended, produced, buffer, got>>

\* The cancel callback of the stream stops the holder, and the link stops
\* the worker.
CancelStopsHolder ==
    /\ Bug # "cancel_ignored"
    /\ stream = "cancelled" /\ holder = "alive"
    /\ holder' = "stopped"
    /\ worker' = IF worker = "running" THEN "stopped" ELSE worker
    /\ UNCHANGED <<ended, produced, buffer, queue, stream, got, result>>

Next ==
    \/ WorkerData \/ WorkerDone \/ WorkerFail \/ WorkerCrash \/ HolderCrash
    \/ HolderSeesWorkerCrash \/ ReaderStart \/ HolderForward \/ HolderClose
    \/ HolderFail \/ StreamSeesHolderCrash \/ CancelStopsHolder
    \/ ReaderRead \/ ReaderEnd \/ ReaderStop
    \/ UNCHANGED vars

\* The worker makes progress, the holder and the stream act, and the reader
\* starts a read and continues to read. The reader does not have to stop.
Fairness ==
    /\ WF_vars(WorkerData \/ WorkerDone)
    /\ WF_vars(HolderSeesWorkerCrash)
    /\ WF_vars(HolderForward \/ HolderClose \/ HolderFail)
    /\ WF_vars(StreamSeesHolderCrash)
    /\ WF_vars(CancelStopsHolder)
    /\ WF_vars(ReaderStart)
    /\ WF_vars(ReaderRead \/ ReaderEnd)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ worker \in {"running", "done", "failed", "crashed", "stopped"}
    /\ holder \in {"alive", "crashed", "stopped"}
    /\ ended \in {"no", "done", "error"}
    /\ produced \in 0..Chunks
    /\ buffer \in 0..Chunks
    /\ queue \in 0..Chunks
    /\ stream \in {"none", "readable", "closed", "errored", "cancelled"}
    /\ got \in 0..Chunks
    /\ result \in {"none", "done", "error"}

\* The holder does not keep more chunks than its limit.
BufferBounded == buffer <= Limit

\* The queue does not have more chunks than its limit.
QueueBounded == queue <= Limit

\* The reader does not get more chunks than the worker read.
NoExtraChunk == got + queue + buffer <= produced

\* When the reader gets the end of the body, it has all the chunks. A body
\* that is not complete gives an error.
FullBodyOrError == result = "done" => got = Chunks

\* The reader gets an end: the end of the body, or an error.
ReaderGetsAnEnd == <>(result # "none")

\* After a cancel, the worker stops: the connection does not stay.
CancelStopsWorker == (stream = "cancelled") ~> (worker # "running")
=============================================================================
