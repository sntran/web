---------------------------- MODULE ResponseBody ----------------------------
(* The body of a response of Web.Dispatcher.HTTP.                           *)
(*                                                                          *)
(* The worker reads the connection, and enqueues each chunk directly into   *)
(* the body stream. The stream has a queue with a limit: while the queue    *)
(* is full, the worker waits for a pull. The watcher monitors the worker.   *)
(* The reader reads the stream, or it stops, and then the stream is         *)
(* cancelled.                                                               *)
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
    Limit,    \* the number of chunks that the queue keeps before the worker waits
    Bug       \* "none", or the name of a rule to remove

VARIABLES
    worker,     \* "running", "done", "failed", "crashed", or "stopped"
    watcher,    \* TRUE while the watcher is alive
    produced,   \* the number of chunks that the worker enqueued
    queue,      \* the number of chunks in the queue of the stream
    stream,     \* "readable", "closed", "errored", or "cancelled"
    got,        \* the number of chunks that the reader has
    result      \* the end that the reader got: "none", "done", or "error"

vars == <<worker, watcher, produced, queue, stream, got, result>>

Init ==
    /\ worker = "running"
    /\ watcher = TRUE
    /\ produced = 0
    /\ queue = 0
    /\ stream = "readable"
    /\ got = 0
    /\ result = "none"

\* The worker enqueues a chunk while the queue is below its limit. This is
\* the backpressure.
WorkerData ==
    /\ worker = "running" /\ stream = "readable" /\ produced < Chunks
    /\ queue < Limit \/ Bug = "no_backpressure"
    /\ produced' = produced + 1
    /\ queue' = queue + 1
    /\ UNCHANGED <<worker, watcher, stream, got, result>>

\* The worker read the full body. It closes the stream when the queue is
\* empty: until then an abort can still put the body in the errored state.
WorkerDone ==
    /\ worker = "running" /\ stream = "readable" /\ produced = Chunks /\ queue = 0
    /\ worker' = "done"
    /\ stream' = "closed"
    /\ UNCHANGED <<watcher, produced, queue, got, result>>

\* The connection fails, or the body cannot be decoded. The worker puts the
\* stream in the errored state.
WorkerFail ==
    /\ worker = "running" /\ stream = "readable"
    /\ worker' = "failed"
    /\ stream' = IF Bug = "close_on_failure" THEN "closed" ELSE "errored"
    /\ queue' = IF Bug = "close_on_failure" THEN queue ELSE 0
    /\ UNCHANGED <<watcher, produced, got, result>>

\* One of the two processes stops with no message, for example because a
\* different process kills it. The model has one such stop at most.
WorkerCrash ==
    /\ worker = "running" /\ watcher
    /\ worker' = "crashed"
    /\ UNCHANGED <<watcher, produced, queue, stream, got, result>>

WatcherCrash ==
    /\ watcher /\ worker # "crashed"
    /\ watcher' = FALSE
    /\ UNCHANGED <<worker, produced, queue, stream, got, result>>

\* The watcher sees that the worker stopped, and puts the stream in the
\* errored state.
WatcherSeesCrash ==
    /\ Bug # "no_watcher"
    /\ watcher /\ worker = "crashed" /\ stream = "readable"
    /\ stream' = "errored"
    /\ queue' = 0
    /\ UNCHANGED <<worker, watcher, produced, got, result>>

\* The reader takes a chunk from the queue.
ReaderRead ==
    /\ result = "none" /\ stream \in {"readable", "closed"} /\ queue > 0
    /\ got' = got + 1
    /\ queue' = queue - 1
    /\ UNCHANGED <<worker, watcher, produced, stream, result>>

\* The reader gets the end of the stream.
ReaderEnd ==
    /\ result = "none" /\ queue = 0 /\ stream \in {"closed", "errored"}
    /\ result' = IF stream = "closed" THEN "done" ELSE "error"
    /\ UNCHANGED <<worker, watcher, produced, queue, stream, got>>

\* The reader stops. The stream is cancelled, and its cancel callback tells
\* the watcher, which stops the worker.
ReaderStop ==
    /\ result = "none" /\ stream = "readable"
    /\ stream' = "cancelled"
    /\ queue' = 0
    /\ result' = "error"
    /\ UNCHANGED <<worker, watcher, produced, got>>

WatcherStopsWorker ==
    /\ Bug # "cancel_ignored"
    /\ watcher /\ stream = "cancelled" /\ worker = "running"
    /\ worker' = "stopped"
    /\ UNCHANGED <<watcher, produced, queue, stream, got, result>>

\* A worker that waits for a pull sees that the stream stopped. The model
\* puts this rule with the cancel: the worker stops also when the watcher
\* is not alive.
WorkerSeesCancel ==
    /\ Bug # "cancel_ignored"
    /\ ~watcher /\ stream = "cancelled" /\ worker = "running"
    /\ worker' = "stopped"
    /\ UNCHANGED <<watcher, produced, queue, stream, got, result>>

Next ==
    \/ WorkerData \/ WorkerDone \/ WorkerFail \/ WorkerCrash \/ WatcherCrash
    \/ WatcherSeesCrash \/ WatcherStopsWorker \/ WorkerSeesCancel
    \/ ReaderRead \/ ReaderEnd \/ ReaderStop
    \/ UNCHANGED vars

\* The worker makes progress, the watcher acts, and the reader continues to
\* read. The reader does not have to stop.
Fairness ==
    /\ WF_vars(WorkerData \/ WorkerDone)
    /\ WF_vars(WatcherSeesCrash)
    /\ WF_vars(WatcherStopsWorker \/ WorkerSeesCancel)
    /\ WF_vars(ReaderRead \/ ReaderEnd)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ worker \in {"running", "done", "failed", "crashed", "stopped"}
    /\ watcher \in BOOLEAN
    /\ produced \in 0..Chunks
    /\ queue \in 0..Chunks
    /\ stream \in {"readable", "closed", "errored", "cancelled"}
    /\ got \in 0..Chunks
    /\ result \in {"none", "done", "error"}

\* The queue does not have more chunks than its limit.
QueueBounded == queue <= Limit

\* The reader does not get more chunks than the worker read.
NoExtraChunk == got + queue <= produced

\* When the reader gets the end of the body, it has all the chunks. A body
\* that is not complete gives an error.
FullBodyOrError == result = "done" => got = Chunks

\* The reader gets an end: the end of the body, or an error.
ReaderGetsAnEnd == <>(result # "none")

\* After a cancel, the worker stops: the connection does not stay.
CancelStopsWorker == (stream = "cancelled") ~> (worker # "running")
=============================================================================
