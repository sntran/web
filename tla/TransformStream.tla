--------------------------- MODULE TransformStream ---------------------------
(* The two sides of one Web.TransformStream.                                *)
(*                                                                          *)
(* A transform stream has two processes, as the two sides of the Streams    *)
(* Standard: the writable side and the readable side. The two sides share   *)
(* [[backpressure]] in one atomic cell. The value of the cell is "off",     *)
(* "on", or "held": the backpressure is on, and the writable side holds a   *)
(* write.                                                                   *)
(*                                                                          *)
(* The readable side changes the cell at its events: a read, an enqueue,    *)
(* and the end of start (ReadableStreamDefaultControllerCallPullIfNeeded).  *)
(* When it wants a chunk, a pull sets "off". A pull that finds "held" sends *)
(* a message to the writable side. An enqueue after which the readable side *)
(* wants no chunk sets "on" when the cell is "off".                         *)
(*                                                                          *)
(* The writable side reads the cell before each transform. It changes "on"  *)
(* to "held" in one atomic step, and then holds the write until the message *)
(* comes. With "off", the transform runs at once. The worker of the         *)
(* writable side runs the transform: it enqueues one chunk on the readable  *)
(* side, and then it gives its result to the writable side. The default     *)
(* transform has no worker: the readable side does the enqueue, and sends   *)
(* the result. The steps are the same.                                      *)
(*                                                                          *)
(* The message of a pull and the result of the worker come from different  *)
(* processes. Their sequence is not known, thus each one is a separate     *)
(* step.                                                                    *)
(*                                                                          *)
(* A close (flush), an abort, and a cancel ask for [[finishPromise]]. Only   *)
(* the first request calls the transformer.                                 *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design. The property tests of transform_stream_test.exs check *)
(* the properties on the real code: the limit of the queue with no chunk    *)
(* lost, a write that a pull continues, and the one call of the             *)
(* transformer.                                                             *)
EXTENDS Naturals

CONSTANTS
    HWM,     \* the high water mark of the readable side
    Writes,  \* the number of chunks that the writer writes
    Bug      \* "none", or the name of a rule to remove

VARIABLES
    written,   \* the chunks that the writer gave to the writable side
    queued,    \* the writes in the queue of the writable side
    flight,    \* the write in flight: "none", "check", "held", "transform", or "result"
    cell,      \* [[backpressure]]: "off", "on", or "held"
    released,  \* the messages of a pull to the writable side
    started,   \* the function start is complete on the readable side
    rq,        \* the chunks in the queue of the readable side
    waiting,   \* the reads that wait on the readable side
    read,      \* the chunks that the reader got
    requests,  \* the operations that asked for [[finishPromise]]
    finish,    \* [[finishPromise]]: "none", "running", or "settled"
    calls      \* the calls of the transformer for a close, an abort, or a cancel

vars == <<written, queued, flight, cell, released, started, rq, waiting, read,
          requests, finish, calls>>

Ends == {"close", "abort", "cancel"}

\* The limit of the queue of the readable side: one transform gives one chunk.
Limit == IF HWM > 1 THEN HWM ELSE 1

Init ==
    /\ written = 0 /\ queued = 0 /\ flight = "none"
    /\ cell = "on" /\ released = 0 /\ started = FALSE
    /\ rq = 0 /\ waiting = 0 /\ read = 0
    /\ requests = {} /\ finish = "none" /\ calls = 0

\* ReadableStreamDefaultControllerShouldCallPull: the readable side wants a
\* chunk.
ShouldPull(s, q, w) == s /\ "cancel" \notin requests /\ (w > 0 \/ q < HWM)

\* The pull after an event of the readable side
\* (TransformStreamDefaultSourcePullAlgorithm): it sets "off" in one atomic
\* step. A pull that finds "held" sends the message.
PullIfNeeded(s, q, w) ==
    IF ShouldPull(s, q, w) /\ cell # "off"
    THEN /\ cell' = "off"
         /\ released' = IF cell = "held" /\ Bug # "no_release"
                        THEN released + 1 ELSE released
    ELSE UNCHANGED <<cell, released>>

\* No operation ended the stream.
Open == requests = {}

\* The writer writes a chunk.
Write ==
    /\ Open /\ written < Writes
    /\ written' = written + 1 /\ queued' = queued + 1
    /\ UNCHANGED <<flight, cell, released, started, rq, waiting, read, requests,
                   finish, calls>>

\* The next write is in flight (TransformStreamDefaultSinkWriteAlgorithm). With
\* "on", the writable side sets "held" in the same atomic step, and holds the
\* write. The bug "check_then_mark" does the check and the change in two
\* steps. The bug "no_mark" holds the write with no change of the cell.
Start ==
    /\ Open /\ flight = "none" /\ queued > 0
    /\ queued' = queued - 1
    /\ IF cell = "off"
       THEN /\ flight' = "transform" /\ UNCHANGED cell
       ELSE IF Bug = "check_then_mark"
       THEN /\ flight' = "check" /\ UNCHANGED cell
       ELSE IF Bug = "no_mark"
       THEN /\ flight' = "held" /\ UNCHANGED cell
       ELSE /\ flight' = "held" /\ cell' = "held"
    /\ UNCHANGED <<written, released, started, rq, waiting, read, requests, finish,
                   calls>>

\* The second step of the bug "check_then_mark": the writable side sets
\* "held" with no new check.
Mark ==
    /\ flight = "check"
    /\ flight' = "held" /\ cell' = "held"
    /\ UNCHANGED <<written, queued, released, started, rq, waiting, read, requests,
                   finish, calls>>

\* The writable side gets the message of a pull: the held write continues.
Release ==
    /\ released > 0
    /\ released' = released - 1
    /\ flight' = IF flight = "held" THEN "transform" ELSE flight
    /\ UNCHANGED <<written, queued, cell, started, rq, waiting, read, requests,
                   finish, calls>>

\* The worker enqueues one chunk. A read that waits gets it. After the
\* enqueue, the readable side pulls when it wants a chunk, and else it turns
\* the backpressure on (TransformStreamDefaultControllerEnqueue).
Transform ==
    /\ flight = "transform"
    /\ LET w == IF waiting > 0 THEN waiting - 1 ELSE 0
           q == IF waiting > 0 THEN rq ELSE rq + 1
       IN /\ rq' = q /\ waiting' = w
          /\ read' = IF waiting > 0 THEN read + 1 ELSE read
          /\ IF ShouldPull(started, q, w)
             THEN PullIfNeeded(started, q, w)
             ELSE /\ cell' = IF cell = "off" /\ Bug # "no_backpressure_on"
                             THEN "on" ELSE cell
                  /\ UNCHANGED released
    /\ flight' = "result"
    /\ UNCHANGED <<written, queued, started, requests, finish, calls>>

\* The writable side gets the result of the worker.
Result ==
    /\ flight = "result"
    /\ flight' = "none"
    /\ UNCHANGED <<written, queued, cell, released, started, rq, waiting, read,
                   requests, finish, calls>>

\* The reader reads a chunk, or waits for one. It reads one chunk at a time.
Read ==
    /\ waiting = 0 /\ read < Writes /\ "cancel" \notin requests
    /\ LET q == IF rq > 0 THEN rq - 1 ELSE 0
           w == IF rq > 0 THEN 0 ELSE 1
       IN /\ rq' = q /\ waiting' = w
          /\ read' = IF rq > 0 THEN read + 1 ELSE read
          /\ PullIfNeeded(started, q, w)
    /\ UNCHANGED <<written, queued, flight, started, requests, finish, calls>>

\* The function start is complete on the readable side.
Started ==
    /\ ~started
    /\ started' = TRUE
    /\ PullIfNeeded(TRUE, rq, waiting)
    /\ UNCHANGED <<written, queued, flight, rq, waiting, read, requests, finish,
                   calls>>

\* An operation ends the stream. A close waits for the writes, and an abort
\* waits for the write in flight. The writes that wait reject. Only the
\* first request calls the transformer.
Request(e) ==
    /\ e \notin requests
    /\ e = "close" => (written = Writes /\ queued = 0 /\ flight = "none")
    /\ e = "abort" => flight \in {"none", "check", "held"}
    /\ requests' = requests \cup {e}
    /\ IF finish = "none" \/ Bug = "no_finish_promise"
       THEN /\ calls' = calls + 1 /\ finish' = "running"
       ELSE UNCHANGED <<calls, finish>>
    /\ queued' = 0
    /\ flight' = IF flight \in {"check", "held"} THEN "none" ELSE flight
    /\ UNCHANGED <<written, cell, released, started, rq, waiting, read>>

\* The callback of the transformer is complete.
Settle ==
    /\ finish = "running" /\ finish' = "settled"
    /\ UNCHANGED <<written, queued, flight, cell, released, started, rq, waiting,
                   read, requests, calls>>

Next ==
    \/ Write \/ Start \/ Mark \/ Release \/ Transform \/ Result \/ Read
    \/ Started
    \/ \E e \in Ends : Request(e)
    \/ Settle
    \/ UNCHANGED vars

\* The processes do their steps, the writer writes, and the reader reads.
Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(Write) /\ WF_vars(Start) /\ WF_vars(Mark) /\ WF_vars(Release)
    /\ WF_vars(Transform) /\ WF_vars(Result) /\ WF_vars(Read)
    /\ WF_vars(Started) /\ WF_vars(Settle)

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ written \in 0..Writes /\ queued \in 0..Writes
    /\ flight \in {"none", "check", "held", "transform", "result"}
    /\ cell \in {"off", "on", "held"} /\ released \in 0..1
    /\ started \in BOOLEAN
    /\ rq \in 0..(Writes + 1) /\ waiting \in 0..1 /\ read \in 0..Writes
    /\ requests \subseteq Ends
    /\ finish \in {"none", "running", "settled"}
    /\ calls \in 0..3

\* [[finishPromise]]: the transformer gets one call at most.
FinishOnce == calls <= 1

\* The transform of a chunk runs only when the readable side wants it: its
\* queue stays at its limit.
QueueBound == rq <= Limit

\* The backpressure is off when the readable side wants a chunk. Only the
\* readable side turns the backpressure on, thus no step of the writable
\* side stops a pull.
OffWhenWanted == ShouldPull(started, rq, waiting) => cell = "off"

\* The reader gets each chunk, unless an operation ends the stream.
Progress == <>(read = Writes \/ requests # {})
=============================================================================
