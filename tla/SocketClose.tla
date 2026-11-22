----------------------------- MODULE SocketClose -----------------------------
(* The close of a Web.Socket, as the Sockets API of WinterTC specifies:    *)
(* see Web.Socket.                                                          *)
(*                                                                          *)
(* A socket connects, and then the peer, the reader, the writer, and the   *)
(* holder of the socket do their steps in each sequence. The promise       *)
(* `closed` fulfils only at close(), or when the socket reads the end of   *)
(* the data of the peer with no allowHalfOpen. It rejects only when the    *)
(* connection fails. A cancel of the readable side and a close or an       *)
(* abort of the writable side do not close the socket. The writer sends    *)
(* the end of its data (a TCP half close). startTls() closes the first     *)
(* socket, and a second socket uses the connection.                        *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design. The values are the behavior of the library before   *)
(* version 0.5.0.                                                           *)
EXTENDS Naturals

CONSTANTS
    HalfOpen,  \* the option allowHalfOpen
    Bug        \* "none", or the name of a rule to remove

VARIABLES
    conn,         \* the transport: "connecting", "open", or "closed"
    opened,       \* the promise opened: "pending", "fulfilled", or "rejected"
    closed,       \* the promise closed: "pending", "fulfilled", or "rejected"
    readable,     \* the readable side: "readable", or "closed" (end or cancel)
    writable,     \* the writable side: "writable", "closed", or "errored"
    peerFin,      \* TRUE after the peer sent the end of its data
    finSent,      \* TRUE after the socket sent the end of its data
    why,          \* the cause of the end of the socket, or "none"
    gen,          \* 1 for the first socket, 2 for the socket of startTls()
    firstClosed,  \* the promise closed of the first socket
    upgraded      \* the attribute upgraded of the first socket

vars == <<conn, opened, closed, readable, writable, peerFin, finSent, why,
          gen, firstClosed, upgraded>>

Init ==
    /\ conn = "connecting"
    /\ opened = "pending"
    /\ closed = "pending"
    /\ readable = "readable"
    /\ writable = "writable"
    /\ peerFin = FALSE
    /\ finSent = FALSE
    /\ why = "none"
    /\ gen = 1
    /\ firstClosed = "pending"
    /\ upgraded = FALSE

\* The connect, or the TLS handshake of the second socket, is complete.
Connected ==
    /\ conn = "connecting"
    /\ conn' = "open"
    /\ opened' = "fulfilled"
    /\ UNCHANGED <<closed, readable, writable, peerFin, finSent, why, gen,
                   firstClosed, upgraded>>

\* The connection fails, at the connect or later: opened (if it is pending)
\* and closed reject, the readable side is cancelled, and the writable side
\* is aborted.
Fail ==
    /\ conn /= "closed"
    /\ conn' = "closed"
    /\ opened' = IF opened = "pending" THEN "rejected" ELSE opened
    /\ closed' = "rejected"
    /\ readable' = "closed"
    /\ writable' = IF writable = "writable" THEN "errored" ELSE writable
    /\ why' = "failure"
    /\ UNCHANGED <<peerFin, finSent, gen, firstClosed, upgraded>>

\* The peer sends the end of its data.
PeerFin ==
    /\ conn = "open"
    /\ ~peerFin
    /\ peerFin' = TRUE
    /\ UNCHANGED <<conn, opened, closed, readable, writable, finSent, why, gen,
                   firstClosed, upgraded>>

\* The socket reads the end of the data: the readable side closes. With no
\* allowHalfOpen, the writable side and the socket close too, and closed
\* fulfils. With the bug, the option has no effect.
ReadEnd ==
    /\ conn = "open"
    /\ peerFin
    /\ readable = "readable"
    /\ readable' = "closed"
    /\ IF HalfOpen /\ Bug /= "half_open_ignored"
       THEN UNCHANGED <<conn, closed, writable, why>>
       ELSE /\ conn' = "closed"
            /\ closed' = "fulfilled"
            /\ writable' = IF writable = "writable" THEN "closed" ELSE writable
            /\ why' = "eof"
    /\ UNCHANGED <<opened, peerFin, finSent, gen, firstClosed, upgraded>>

\* The reader cancels the readable side: the socket reads no more data. With
\* the bug, the cancel closes the socket and fulfils closed.
Cancel ==
    /\ conn /= "closed"
    /\ readable = "readable"
    /\ readable' = "closed"
    /\ IF Bug = "cancel_closes"
       THEN /\ conn' = "closed"
            /\ closed' = "fulfilled"
            /\ writable' = IF writable = "writable" THEN "errored" ELSE writable
            /\ why' = "cancel"
       ELSE UNCHANGED <<conn, closed, writable, why>>
    /\ UNCHANGED <<opened, peerFin, finSent, gen, firstClosed, upgraded>>

\* The writer closes the writable side: the socket sends the end of its
\* data. With the bug, the close closes the socket and fulfils closed, as
\* before version 0.5.0.
CloseWriter ==
    /\ conn = "open"
    /\ writable = "writable"
    /\ writable' = "closed"
    /\ finSent' = TRUE
    /\ IF Bug = "writer_close_closes"
       THEN /\ conn' = "closed"
            /\ closed' = "fulfilled"
            /\ readable' = "closed"
            /\ why' = "writer"
       ELSE UNCHANGED <<conn, closed, readable, why>>
    /\ UNCHANGED <<opened, peerFin, gen, firstClosed, upgraded>>

\* The writer aborts the writable side: the socket sends the end of its
\* data. With the bug, the abort closes the socket too.
AbortWriter ==
    /\ conn = "open"
    /\ writable = "writable"
    /\ writable' = "errored"
    /\ finSent' = TRUE
    /\ IF Bug = "writer_close_closes"
       THEN /\ conn' = "closed"
            /\ closed' = "fulfilled"
            /\ readable' = "closed"
            /\ why' = "writer"
       ELSE UNCHANGED <<conn, closed, readable, why>>
    /\ UNCHANGED <<opened, peerFin, gen, firstClosed, upgraded>>

\* close(reason): the readable side is cancelled, the writable side is
\* aborted, a pending opened rejects, and closed fulfils. The holder that
\* stops does the same. With the bug, a pending opened stays pending.
Close ==
    /\ conn /= "closed"
    /\ conn' = "closed"
    /\ opened' = IF opened = "pending" /\ Bug /= "close_keeps_opened"
                 THEN "rejected" ELSE opened
    /\ closed' = "fulfilled"
    /\ readable' = "closed"
    /\ writable' = IF writable = "writable" THEN "errored" ELSE writable
    /\ why' = "close"
    /\ UNCHANGED <<peerFin, finSent, gen, firstClosed, upgraded>>

\* startTls() on the first socket: the first socket is upgraded and closed,
\* and the second socket starts its handshake on the connection. With the
\* bug, the first socket stays open.
StartTls ==
    /\ gen = 1
    /\ conn = "open"
    /\ readable = "readable"
    /\ writable = "writable"
    /\ ~peerFin
    /\ gen' = 2
    /\ upgraded' = TRUE
    /\ firstClosed' = IF Bug = "upgrade_keeps_first_open" THEN "pending" ELSE "fulfilled"
    /\ conn' = "connecting"
    /\ opened' = "pending"
    /\ closed' = "pending"
    /\ readable' = "readable"
    /\ writable' = "writable"
    /\ finSent' = FALSE
    /\ why' = "none"
    /\ UNCHANGED peerFin

\* The socket is closed: nothing more occurs.
Done == conn = "closed" /\ UNCHANGED vars

Next ==
    \/ Connected \/ Fail \/ PeerFin \/ ReadEnd \/ Cancel \/ CloseWriter
    \/ AbortWriter \/ Close \/ StartTls \/ Done

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* Properties

Promises == {"pending", "fulfilled", "rejected"}

TypeOK ==
    /\ conn \in {"connecting", "open", "closed"}
    /\ opened \in Promises
    /\ closed \in Promises
    /\ readable \in {"readable", "closed"}
    /\ writable \in {"writable", "closed", "errored"}
    /\ peerFin \in BOOLEAN
    /\ finSent \in BOOLEAN
    /\ why \in {"none", "failure", "eof", "close", "cancel", "writer"}
    /\ gen \in {1, 2}
    /\ firstClosed \in Promises
    /\ upgraded \in BOOLEAN

\* closed fulfils only at close(), or at the end of the data of the peer.
ClosedFulfils == closed = "fulfilled" => why \in {"close", "eof"}

\* closed rejects only when the connection fails.
ClosedRejects == (closed = "rejected") <=> (why = "failure")

\* With allowHalfOpen, the end of the data of the peer does not close the
\* socket.
HalfOpenStays == why = "eof" => ~HalfOpen

\* The transport is closed exactly when closed is settled.
Released == (conn = "closed") <=> (closed /= "pending")

\* When closed settles, opened is settled too.
OpenedSettled == closed /= "pending" => opened /= "pending"

\* When the socket closes, its two streams end.
StreamsEnd == conn = "closed" => (readable = "closed" /\ writable /= "writable")

\* The socket sends the end of its data only after the writer ended.
FinFromWriter == finSent => writable /= "writable"

\* After startTls(), the first socket is upgraded and closed.
FirstSocketClosed == gen = 2 => (upgraded /\ firstClosed = "fulfilled")
=============================================================================
