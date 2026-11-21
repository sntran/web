--------------------------- MODULE TransformStream ---------------------------
(* The two sides of one Web.TransformStream.                                *)
(*                                                                          *)
(* A transform stream has two processes, as the two sides of the Streams    *)
(* Standard: the writable side and the readable side. The readable side has *)
(* [[backpressure]]. A pull turns it off, and an enqueue that fills the     *)
(* queue turns it on. The readable side tells each change to the writable   *)
(* side. The writable side keeps a copy: its write in flight waits ("held") *)
(* while the copy is on. The worker of the writable side runs the transform:*)
(* it enqueues one chunk on the readable side, and then it gives its result *)
(* to the writable side.                                                    *)
(*                                                                          *)
(* A process gets the messages of a different process in their sequence.    *)
(* The readable side sends its message before its answer to the enqueue,    *)
(* and the worker sends the result after that answer. Thus the module has   *)
(* one inbox for the writable side.                                         *)
(*                                                                          *)
(* A close (flush), an abort, and a cancel ask for [[finishPromise]]. Only   *)
(* the first request calls the transformer.                                 *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design. The property tests of transform_stream_test.exs check *)
(* the properties on the real code: the limit of the queue with no chunk    *)
(* lost, and the one call of the transformer.                               *)
EXTENDS Naturals, Sequences

CONSTANTS
    HWM,     \* the high water mark of the readable side
    Writes,  \* the number of chunks that the writer writes
    Bug      \* "none", or the name of a rule to remove

VARIABLES
    written,   \* the chunks that the writer gave to the writable side
    queued,    \* the writes in the queue of the writable side
    flight,    \* the write in flight: "none", "held", "transform", or "result"
    copy,      \* the copy of the backpressure on the writable side
    inbox,     \* the messages to the writable side: "on", "off", or "result"
    bp,        \* [[backpressure]] on the readable side
    rq,        \* the chunks in the queue of the readable side
    waiting,   \* the reads that wait on the readable side
    read,      \* the chunks that the reader got
    requests,  \* the operations that asked for [[finishPromise]]
    finish,    \* [[finishPromise]]: "none", "running", or "settled"
    calls      \* the calls of the transformer for a close, an abort, or a cancel

vars == <<written, queued, flight, copy, inbox, bp, rq, waiting, read,
          requests, finish, calls>>

Ends == {"close", "abort", "cancel"}

\* The limit of the queue of the readable side: one transform gives one chunk.
Limit == IF HWM > 1 THEN HWM ELSE 1

Init ==
    /\ written = 0 /\ queued = 0 /\ flight = "none"
    /\ copy = TRUE /\ inbox = <<>> /\ bp = TRUE
    /\ rq = 0 /\ waiting = 0 /\ read = 0
    /\ requests = {} /\ finish = "none" /\ calls = 0

\* ReadableStreamDefaultControllerShouldCallPull.
Wants(q, w) == w > 0 \/ q < HWM

\* No operation ended the stream.
Open == requests = {}

\* The writer writes a chunk.
Write ==
    /\ Open /\ written < Writes
    /\ written' = written + 1 /\ queued' = queued + 1
    /\ UNCHANGED <<flight, copy, inbox, bp, rq, waiting, read, requests, finish, calls>>

\* The next write is in flight. It waits while the copy of the backpressure
\* is on (TransformStreamDefaultSinkWriteAlgorithm).
Start ==
    /\ Open /\ flight = "none" /\ queued > 0
    /\ queued' = queued - 1
    /\ flight' = IF copy THEN "held" ELSE "transform"
    /\ UNCHANGED <<written, copy, inbox, bp, rq, waiting, read, requests, finish, calls>>

\* The end of the backpressure lets the write in flight continue.
Release ==
    /\ flight = "held" /\ ~copy /\ Bug # "no_release"
    /\ flight' = "transform"
    /\ UNCHANGED <<written, queued, copy, inbox, bp, rq, waiting, read, requests, finish, calls>>

\* The worker enqueues one chunk. A read that waits gets it. The readable
\* side turns the backpressure on when it wants no more chunks
\* (TransformStreamDefaultControllerEnqueue), and sends the change before the
\* result of the worker.
Transform ==
    /\ flight = "transform"
    /\ LET w == IF waiting > 0 THEN waiting - 1 ELSE 0
           q == IF waiting > 0 THEN rq ELSE rq + 1
           on == ~Wants(q, w) /\ Bug # "no_backpressure_on"
       IN /\ rq' = q /\ waiting' = w
          /\ read' = IF waiting > 0 THEN read + 1 ELSE read
          /\ bp' = (bp \/ on)
          /\ inbox' = IF on /\ ~bp THEN inbox \o <<"on", "result">>
                      ELSE Append(inbox, "result")
    /\ flight' = "result"
    /\ UNCHANGED <<written, queued, copy, requests, finish, calls>>

\* A pull of the readable side ends the backpressure
\* (TransformStreamDefaultSourcePullAlgorithm).
Pull ==
    /\ bp /\ Wants(rq, waiting) /\ "cancel" \notin requests
    /\ bp' = FALSE /\ inbox' = Append(inbox, "off")
    /\ UNCHANGED <<written, queued, flight, copy, rq, waiting, read, requests, finish, calls>>

\* The writable side gets its next message.
Deliver ==
    /\ inbox # <<>>
    /\ LET m == Head(inbox)
       IN /\ copy' = IF m = "result" THEN copy ELSE m = "on"
          /\ flight' = IF m = "result" THEN "none" ELSE flight
    /\ inbox' = Tail(inbox)
    /\ UNCHANGED <<written, queued, bp, rq, waiting, read, requests, finish, calls>>

\* The reader reads a chunk, or waits for one. It reads one chunk at a time.
Read ==
    /\ waiting = 0 /\ read < Writes /\ "cancel" \notin requests
    /\ IF rq > 0
       THEN /\ rq' = rq - 1 /\ read' = read + 1 /\ UNCHANGED waiting
       ELSE /\ waiting' = 1 /\ UNCHANGED <<rq, read>>
    /\ UNCHANGED <<written, queued, flight, copy, inbox, bp, requests, finish, calls>>

\* An operation ends the stream. A close waits for the writes, and an abort
\* waits for the write in flight. The writes that wait reject. Only the
\* first request calls the transformer.
Request(e) ==
    /\ e \notin requests
    /\ e = "close" => (written = Writes /\ queued = 0 /\ flight = "none")
    /\ e = "abort" => flight \in {"none", "held"}
    /\ requests' = requests \cup {e}
    /\ IF finish = "none" \/ Bug = "no_finish_promise"
       THEN /\ calls' = calls + 1 /\ finish' = "running"
       ELSE UNCHANGED <<calls, finish>>
    /\ queued' = 0
    /\ flight' = IF flight = "held" THEN "none" ELSE flight
    /\ UNCHANGED <<written, copy, inbox, bp, rq, waiting, read>>

\* The callback of the transformer is complete.
Settle ==
    /\ finish = "running" /\ finish' = "settled"
    /\ UNCHANGED <<written, queued, flight, copy, inbox, bp, rq, waiting, read, requests, calls>>

Next ==
    \/ Write \/ Start \/ Release \/ Transform \/ Pull \/ Deliver \/ Read
    \/ \E e \in Ends : Request(e)
    \/ Settle
    \/ UNCHANGED vars

\* The processes do their steps, the writer writes, and the reader reads.
Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(Write) /\ WF_vars(Start) /\ WF_vars(Release) /\ WF_vars(Transform)
    /\ WF_vars(Pull) /\ WF_vars(Deliver) /\ WF_vars(Read) /\ WF_vars(Settle)

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ written \in 0..Writes /\ queued \in 0..Writes
    /\ flight \in {"none", "held", "transform", "result"}
    /\ copy \in BOOLEAN /\ bp \in BOOLEAN
    /\ \A i \in 1..Len(inbox) : inbox[i] \in {"on", "off", "result"}
    /\ rq \in 0..(Writes + 1) /\ waiting \in 0..1 /\ read \in 0..Writes
    /\ requests \subseteq Ends
    /\ finish \in {"none", "running", "settled"}
    /\ calls \in 0..3

\* [[finishPromise]]: the transformer gets one call at most.
FinishOnce == calls <= 1

\* The transform of a chunk runs only when the readable side wants it: its
\* queue stays at its limit.
QueueBound == rq <= Limit

\* With no change of the backpressure in the inbox, the copy is correct.
CopyAgrees == (\A i \in 1..Len(inbox) : inbox[i] = "result") => copy = bp

\* The reader gets each chunk, unless an operation ends the stream.
Progress == <>(read = Writes \/ requests # {})
=============================================================================
