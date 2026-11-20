----------------------------- MODULE SocketFlow -----------------------------
(* How the process of a request of Web.Dispatcher.HTTP reads its socket:  *)
(* see Web.Dispatcher.HTTP.Exchange.                                       *)
(*                                                                          *)
(* The server sends the chunks of a body. The socket keeps them until the   *)
(* process asks for one message: the socket then sends one message to the  *)
(* mailbox of the process, and waits again. The process keeps its own flag *)
(* `asked`: it sets the flag when it asks, and clears it when it handles   *)
(* the message. It asks again after a message only while its buffer is     *)
(* below its limit, and not after the last chunk of the response. A reader *)
(* takes the chunks of the buffer, and then the process asks again.        *)
(*                                                                          *)
(* The module shows that the mailbox has one message of the socket at       *)
(* most, that the buffer and the mailbox stay at the limit, that no chunk  *)
(* is lost, and that the reader gets the full body.                        *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design.                                                      *)
EXTENDS Naturals

CONSTANTS
    Chunks,   \* the number of chunks of the body
    Limit,    \* the number of chunks that the process keeps
    Bug       \* "none", or the name of a rule to remove

VARIABLES
    sent,       \* the chunks that the server sent
    kernel,     \* the chunks in the socket, not yet in a message
    active,     \* TRUE while the socket can send one message
    mailbox,    \* the messages of the socket in the mailbox of the process
    asked,      \* the flag of the process: it asked, and has no message yet
    handled,    \* the chunks that the process handled
    buffer,     \* the chunks that the process keeps for the reader
    got         \* the chunks that the reader has

vars == <<sent, kernel, active, mailbox, asked, handled, buffer, got>>

\* After the request, the process asks for the first message.
Init ==
    /\ sent = 0
    /\ kernel = 0
    /\ active = TRUE
    /\ mailbox = 0
    /\ asked = TRUE
    /\ handled = 0
    /\ buffer = 0
    /\ got = 0

\* The server sends the next chunk.
ServerSend ==
    /\ sent < Chunks
    /\ sent' = sent + 1
    /\ kernel' = kernel + 1
    /\ UNCHANGED <<active, mailbox, asked, handled, buffer, got>>

\* The socket sends one message, and waits until the process asks again.
Deliver ==
    /\ active /\ kernel > 0
    /\ kernel' = kernel - 1
    /\ mailbox' = mailbox + 1
    /\ active' = FALSE
    /\ UNCHANGED <<sent, asked, handled, buffer, got>>

\* The process may ask: it asks only when it has no message on its way,
\* below its limit, and before the end of the response.
MayAsk(b, h) ==
    /\ b < Limit \/ Bug = "no_backpressure"
    /\ h < Chunks \/ Bug = "ask_after_end"

\* The process handles the message, and asks for the next one when it may.
Handle ==
    /\ mailbox > 0
    /\ mailbox' = mailbox - 1
    /\ handled' = handled + 1
    /\ buffer' = buffer + 1
    /\ IF MayAsk(buffer + 1, handled + 1)
       THEN active' = TRUE /\ asked' = TRUE
       ELSE active' = active /\ asked' = FALSE
    /\ UNCHANGED <<sent, kernel, got>>

\* The reader takes the chunks of the buffer. The process asks again when it
\* has no message on its way. With the bug, the process looks at the socket
\* instead of its own flag: a message in the mailbox is not on its way for
\* the socket.
Read ==
    /\ buffer > 0
    /\ got' = got + buffer
    /\ buffer' = 0
    /\ LET waiting == IF Bug = "ask_with_message" THEN active ELSE asked
       IN IF ~waiting /\ MayAsk(0, handled)
          THEN active' = TRUE /\ asked' = TRUE
          ELSE UNCHANGED <<active, asked>>
    /\ UNCHANGED <<sent, kernel, mailbox, handled>>

\* The reader has the full body: nothing more occurs.
Done == got = Chunks /\ UNCHANGED vars

Next == ServerSend \/ Deliver \/ Handle \/ Read \/ Done

Fairness ==
    /\ WF_vars(ServerSend)
    /\ WF_vars(Deliver)
    /\ WF_vars(Handle)
    /\ WF_vars(Read)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ sent \in 0..Chunks
    /\ kernel \in 0..Chunks
    /\ active \in BOOLEAN
    /\ mailbox \in 0..Chunks
    /\ asked \in BOOLEAN
    /\ handled \in 0..Chunks
    /\ buffer \in 0..Chunks
    /\ got \in 0..Chunks

\* The mailbox has one message of the socket at most.
MailboxBounded == mailbox <= 1

\* The process keeps the limit, with the message on its way.
BufferBounded == buffer + mailbox <= Limit

\* No chunk is lost, and no chunk comes two times.
NoLoss ==
    /\ sent = kernel + mailbox + handled
    /\ handled = buffer + got

\* The process does not read its socket after the end of the response: the
\* server can close it at that time.
NoReadAfterEnd == handled = Chunks => ~active

\* The reader gets the full body.
FullBody == <>(got = Chunks)
=============================================================================
