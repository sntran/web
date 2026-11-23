---------------------------- MODULE ResponseBody ----------------------------
(* The body of a response of Web.Dispatcher.HTTP that the process of the  *)
(* request holds.                                                          *)
(*                                                                          *)
(* The process of the request, the holder, owns the socket of its           *)
(* connection. It reads the socket only while its buffer is below its       *)
(* limit: each read gives one chunk. This is the backpressure. It keeps     *)
(* the chunks in its buffer until a reader starts a stream read. Then it    *)
(* gives each chunk to the stream when the queue of the stream has space,   *)
(* and the chunk leaves the buffer. The stream monitors the holder, and     *)
(* the socket closes when the holder stops.                                 *)
(*                                                                          *)
(* A chunk is also a piece of the content decoder: the decoder gives a      *)
(* piece only while the buffer is below its limit.                          *)
(*                                                                          *)
(* A body that is complete 1 ms after its headers has no process: it is in  *)
(* the struct of the response, and this module does not apply to it.       *)
(*                                                                          *)
(* The module shows that the reader gets the full body or an error, also    *)
(* when the holder stops with no message, and that a cancel closes the      *)
(* connection.                                                              *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design.                                                      *)
EXTENDS Naturals

CONSTANTS
    Chunks,   \* the number of chunks of the full body
    Limit,    \* the number of chunks that the buffer and the queue keep
    Bug       \* "none", or the name of a rule to remove

VARIABLES
    conn,       \* the connection: "open", "done", "failed", or "closed"
    holder,     \* "alive", "crashed", or "stopped"
    ended,      \* the end that the holder knows: "no", "done", or "error"
    produced,   \* the number of chunks that the holder read
    buffer,     \* the number of chunks in the buffer of the holder
    queue,      \* the number of chunks in the queue of the stream
    stream,     \* "none", "readable", "closed", "errored", or "cancelled"
    got,        \* the number of chunks that the reader has
    result      \* the end that the reader got: "none", "done", or "error"

vars == <<conn, holder, ended, produced, buffer, queue, stream, got, result>>

Init ==
    /\ conn = "open"
    /\ holder = "alive"
    /\ ended = "no"
    /\ produced = 0
    /\ buffer = 0
    /\ queue = 0
    /\ stream = "none"
    /\ got = 0
    /\ result = "none"

\* The holder reads a chunk while its buffer is below its limit. This is the
\* backpressure.
Read ==
    /\ conn = "open" /\ holder = "alive" /\ produced < Chunks
    /\ buffer < Limit \/ Bug = "no_backpressure"
    /\ produced' = produced + 1
    /\ buffer' = buffer + 1
    /\ UNCHANGED <<conn, holder, ended, queue, stream, got, result>>

\* The holder read the full body.
ConnDone ==
    /\ conn = "open" /\ holder = "alive" /\ produced = Chunks
    /\ conn' = "done"
    /\ ended' = "done"
    /\ UNCHANGED <<holder, produced, buffer, queue, stream, got, result>>

\* The connection fails, or the body cannot be decoded. The socket gives
\* the failure to the holder as a message.
ConnFail ==
    /\ conn = "open" /\ holder = "alive"
    /\ conn' = "failed"
    /\ ended' = IF Bug = "failure_ignored" THEN ended ELSE "error"
    /\ UNCHANGED <<holder, produced, buffer, queue, stream, got, result>>

\* The holder stops with no message, for example because a different
\* process kills it. The socket closes with its owner.
HolderCrash ==
    /\ holder = "alive"
    /\ holder' = "crashed"
    /\ conn' = IF conn = "open" THEN "closed" ELSE conn
    /\ UNCHANGED <<ended, produced, buffer, queue, stream, got, result>>

\* The reader starts a stream read: the stream exists from this time.
ReaderStart ==
    /\ stream = "none" /\ result = "none"
    /\ stream' = "readable"
    /\ UNCHANGED <<conn, holder, ended, produced, buffer, queue, got, result>>

\* The holder gives a chunk to the stream when the queue has space. The
\* chunk leaves the buffer: the holder can read one more.
HolderForward ==
    /\ holder = "alive" /\ stream = "readable" /\ buffer > 0 /\ queue < Limit
    /\ buffer' = buffer - 1
    /\ queue' = queue + 1
    /\ UNCHANGED <<conn, holder, ended, produced, stream, got, result>>

\* At the end of the body, the holder closes the stream, and stops. A
\* stream that closes with chunks in its queue stays readable until a read
\* takes the last chunk.
HolderClose ==
    /\ holder = "alive" /\ stream = "readable" /\ buffer = 0
    /\ ended = "done" \/ (Bug = "close_on_failure" /\ ended = "error")
    /\ stream' = "closed"
    /\ holder' = "stopped"
    /\ UNCHANGED <<conn, ended, produced, buffer, queue, got, result>>

\* A failure of the body puts the stream in the errored state.
HolderFail ==
    /\ Bug # "close_on_failure"
    /\ holder = "alive" /\ stream = "readable" /\ ended = "error"
    /\ stream' = "errored"
    /\ queue' = 0
    /\ holder' = "stopped"
    /\ UNCHANGED <<conn, ended, produced, buffer, got, result>>

\* The stream monitors the holder. A holder that stops before the end of
\* the stream puts the stream in the errored state.
StreamSeesHolderCrash ==
    /\ Bug # "no_source_watch"
    /\ holder = "crashed" /\ stream = "readable"
    /\ stream' = "errored"
    /\ queue' = 0
    /\ UNCHANGED <<conn, holder, ended, produced, buffer, got, result>>

\* The reader takes a chunk from the queue.
ReaderRead ==
    /\ result = "none" /\ stream \in {"readable", "closed"} /\ queue > 0
    /\ got' = got + 1
    /\ queue' = queue - 1
    /\ UNCHANGED <<conn, holder, ended, produced, buffer, stream, result>>

\* The reader gets the end of the stream.
ReaderEnd ==
    /\ result = "none" /\ queue = 0 /\ stream \in {"closed", "errored"}
    /\ result' = IF stream = "closed" THEN "done" ELSE "error"
    /\ UNCHANGED <<conn, holder, ended, produced, buffer, queue, stream, got>>

\* The reader stops. The stream is cancelled.
ReaderStop ==
    /\ result = "none" /\ stream = "readable"
    /\ stream' = "cancelled"
    /\ queue' = 0
    /\ result' = "error"
    /\ UNCHANGED <<conn, holder, ended, produced, buffer, got>>

\* The cancel callback of the stream stops the holder, and the holder
\* closes the connection.
CancelStopsHolder ==
    /\ Bug # "cancel_ignored"
    /\ stream = "cancelled" /\ holder = "alive"
    /\ holder' = "stopped"
    /\ conn' = IF conn = "open" THEN "closed" ELSE conn
    /\ UNCHANGED <<ended, produced, buffer, queue, stream, got, result>>

Next ==
    \/ Read \/ ConnDone \/ ConnFail \/ HolderCrash
    \/ ReaderStart \/ HolderForward \/ HolderClose
    \/ HolderFail \/ StreamSeesHolderCrash \/ CancelStopsHolder
    \/ ReaderRead \/ ReaderEnd \/ ReaderStop
    \/ UNCHANGED vars

\* The connection makes progress, the holder and the stream act, and the
\* reader starts a read and continues to read. The reader does not have to
\* stop.
Fairness ==
    /\ WF_vars(Read \/ ConnDone)
    /\ WF_vars(HolderForward \/ HolderClose \/ HolderFail)
    /\ WF_vars(StreamSeesHolderCrash)
    /\ WF_vars(CancelStopsHolder)
    /\ WF_vars(ReaderStart)
    /\ WF_vars(ReaderRead \/ ReaderEnd)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ conn \in {"open", "done", "failed", "closed"}
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

\* The reader does not get more chunks than the holder read.
NoExtraChunk == got + queue + buffer <= produced

\* When the reader gets the end of the body, it has all the chunks. A body
\* that is not complete gives an error.
FullBodyOrError == result = "done" => got = Chunks

\* The reader gets an end: the end of the body, or an error.
ReaderGetsAnEnd == <>(result # "none")

\* After a cancel, the connection closes: it does not stay.
CancelClosesConnection == (stream = "cancelled") ~> (conn # "open")
=============================================================================
