-------------------------- MODULE SharedConnection --------------------------
(* The shared HTTP/2 connection of an origin, for the setting `[:http2]`:  *)
(* see Web.Dispatcher.HTTP.Multiplex and Web.Dispatcher.HTTP.Exchange.     *)
(*                                                                          *)
(* The requests of an origin use the current connection. A request waits in *)
(* the queue of its connection, and gets a stream when the server allows    *)
(* one more. The server processes the request of a stream, and the         *)
(* response comes.                                                          *)
(*                                                                          *)
(* The server can close a connection for new streams (GOAWAY): it tells     *)
(* the streams that it did not process. The connection can also fail. Its  *)
(* socket can close before the client knows it: the write of the next      *)
(* stream then fails, and the server did not get that request. The         *)
(* next requests then use a new connection. A request that did not go to   *)
(* the server, or that the server did not process, goes again on the new    *)
(* connection. A request that can have run gives an error, only when the   *)
(* connection failed.                                                       *)
(*                                                                          *)
(* The module shows that the server processes each request one time at     *)
(* most, that a connection has no more streams than the server allows,     *)
(* that a request gives an error only after a failure of a connection, and  *)
(* that each request ends.                                                  *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design.                                                      *)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Requests,     \* the requests
    MaxStreams,   \* the streams that the server allows on one connection
    MaxConns,     \* the number of the last connection: it does not close
    Bug           \* "none", or the name of a rule to remove

Conns == 0..MaxConns

VARIABLES
    req,      \* each request: "new", "queued", "open", "processed", "done", "error"
    on,       \* the connection of each request
    runs,     \* the number of times that the server processed each request
    conn,     \* each connection: "none", "open", "broken", "goaway", or "closed".
              \* "broken": the socket closed, and the client does not know it.
    current,  \* the connection that new requests use
    failed    \* TRUE after a connection failed

vars == <<req, on, runs, conn, current, failed>>

Init ==
    /\ req = [r \in Requests |-> "new"]
    /\ on = [r \in Requests |-> 0]
    /\ runs = [r \in Requests |-> 0]
    /\ conn = [c \in Conns |-> IF c = 0 THEN "open" ELSE "none"]
    /\ current = 0
    /\ failed = FALSE

Streams(c) == {r \in Requests : on[r] = c /\ req[r] \in {"open", "processed"}}

\* A request goes to the queue of the current connection. The client does
\* not see a socket that closed.
Submit(r) ==
    /\ req[r] = "new" /\ conn[current] \in {"open", "broken"}
    /\ req' = [req EXCEPT ![r] = "queued"]
    /\ on' = [on EXCEPT ![r] = current]
    /\ UNCHANGED <<runs, conn, current, failed>>

\* A request in the queue gets a stream when the server allows one more.
Start(r) ==
    /\ req[r] = "queued" /\ conn[on[r]] = "open"
    /\ Cardinality(Streams(on[r])) < MaxStreams \/ Bug = "no_limit"
    /\ req' = [req EXCEPT ![r] = "open"]
    /\ UNCHANGED <<on, runs, conn, current, failed>>

\* The server processes the request of a stream.
Process(r) ==
    /\ req[r] = "open" /\ conn[on[r]] \in {"open", "goaway"}
    /\ req' = [req EXCEPT ![r] = "processed"]
    /\ runs' = [runs EXCEPT ![r] = @ + 1]
    /\ UNCHANGED <<on, conn, current, failed>>

\* The response comes.
Respond(r) ==
    /\ req[r] = "processed" /\ conn[on[r]] \in {"open", "goaway"}
    /\ req' = [req EXCEPT ![r] = "done"]
    /\ UNCHANGED <<on, runs, conn, current, failed>>

\* The socket of a connection closes, and the client does not know it yet.
SocketCloses(c) ==
    /\ conn[c] = "open" /\ c < MaxConns
    /\ conn' = [conn EXCEPT ![c] = "broken"]
    /\ UNCHANGED <<req, on, runs, current, failed>>

\* The next request starts a new connection when the current one takes no
\* new streams.
NewConnection ==
    /\ conn[current] \in {"goaway", "closed"} /\ current < MaxConns
    /\ current' = current + 1
    /\ conn' = [conn EXCEPT ![current + 1] = "open"]
    /\ UNCHANGED <<req, on, runs, failed>>

\* The next state of a request on a connection that closes for new streams.
\* A request in the queue did not go to the server, and the server tells
\* the streams that it did not process: the two go again.
AtGoAway(r, c) ==
    IF on[r] # c THEN req[r]
    ELSE CASE req[r] = "queued" -> IF Bug = "fail_queued" THEN "error" ELSE "new"
           [] req[r] = "open" -> "new"
           [] req[r] = "processed" -> IF Bug = "retry_processed" THEN "new" ELSE "processed"
           [] OTHER -> req[r]

GoAway(c) ==
    /\ conn[c] = "open" /\ c < MaxConns
    /\ conn' = [conn EXCEPT ![c] = "goaway"]
    /\ req' = [r \in Requests |-> AtGoAway(r, c)]
    /\ UNCHANGED <<on, runs, current, failed>>

\* The next state of a request on a connection that fails. A stream can
\* have run on the server: it gives an error.
AtFailure(r, c) ==
    IF on[r] # c THEN req[r]
    ELSE CASE req[r] = "queued" -> IF Bug = "fail_queued" THEN "error" ELSE "new"
           [] req[r] \in {"open", "processed"} -> "error"
           [] OTHER -> req[r]

Fail(c) ==
    /\ conn[c] \in {"open", "goaway"} /\ c < MaxConns
    /\ conn' = [conn EXCEPT ![c] = "closed"]
    /\ req' = [r \in Requests |-> AtFailure(r, c)]
    /\ failed' = TRUE
    /\ UNCHANGED <<on, runs, current>>

\* The client reads the close of a socket that closed: the connection fails.
Notice(c) ==
    /\ conn[c] = "broken"
    /\ conn' = [conn EXCEPT ![c] = "closed"]
    /\ req' = [r \in Requests |-> AtFailure(r, c)]
    /\ failed' = TRUE
    /\ UNCHANGED <<on, runs, current>>

\* The write of a request in the queue fails on a socket that closed. The
\* server did not get the request: it goes again, and the connection fails
\* for the other requests. With the Bug "fail_written", the request gives
\* the error of the write, and the connection takes the next requests.
WriteFails(r) ==
    /\ req[r] = "queued" /\ conn[on[r]] = "broken"
    /\ Cardinality(Streams(on[r])) < MaxStreams
    /\ IF Bug = "fail_written"
         THEN /\ req' = [req EXCEPT ![r] = "error"]
              /\ UNCHANGED <<conn, failed>>
         ELSE /\ conn' = [conn EXCEPT ![on[r]] = "closed"]
              /\ req' = [q \in Requests |-> IF q = r THEN "new" ELSE AtFailure(q, on[r])]
              /\ failed' = TRUE
    /\ UNCHANGED <<on, runs, current>>

\* Each request ended: nothing more occurs.
Done ==
    /\ \A r \in Requests : req[r] \in {"done", "error"}
    /\ UNCHANGED vars

Next ==
    \/ \E r \in Requests : Submit(r) \/ Start(r) \/ Process(r) \/ Respond(r) \/ WriteFails(r)
    \/ \E c \in Conns : GoAway(c) \/ Fail(c) \/ SocketCloses(c) \/ Notice(c)
    \/ NewConnection
    \/ Done

Fairness ==
    /\ \A r \in Requests :
        /\ WF_vars(Submit(r)) /\ WF_vars(Start(r)) /\ WF_vars(Process(r))
        /\ WF_vars(Respond(r)) /\ WF_vars(WriteFails(r))
    /\ \A c \in Conns : WF_vars(Notice(c))
    /\ WF_vars(NewConnection)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ req \in [Requests -> {"new", "queued", "open", "processed", "done", "error"}]
    /\ on \in [Requests -> Conns]
    /\ runs \in [Requests -> 0..2]
    /\ conn \in [Conns -> {"none", "open", "broken", "goaway", "closed"}]
    /\ current \in Conns
    /\ failed \in BOOLEAN

\* The server processes each request one time at most: a request goes
\* again only when the server did not process it.
AtMostOnce == \A r \in Requests : runs[r] <= 1

\* A connection has no more streams than the server allows.
StreamsBounded == \A c \in Conns : Cardinality(Streams(c)) <= MaxStreams

\* A request gives an error only after a failure of a connection: a
\* connection that closes for new streams gives no error.
ErrorOnlyAfterFailure == \A r \in Requests : req[r] = "error" => failed

\* Each request ends.
EachRequestEnds == \A r \in Requests : <>(req[r] \in {"done", "error"})
=============================================================================
