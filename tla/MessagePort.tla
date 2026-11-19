----------------------------- MODULE MessagePort -----------------------------
(* The two ports of one channel of Web.MessageChannel.                      *)
(*                                                                          *)
(* The module shows the messages from port a to port b. Port b has the port *)
(* message queue of the HTML Standard: it keeps the messages until it       *)
(* starts. A transfer moves port b to a new holder: the port gets a new     *)
(* listener process, and it does not deliver until its new holder starts    *)
(* it.                                                                      *)
(*                                                                          *)
(* Each port has two processes. The server keeps the queue. The listener    *)
(* process runs the listeners. The server gives one item at a time to the   *)
(* listener process, and waits for its answer. A listener process that a    *)
(* transfer or a close stopped gives the item back.                         *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design.                                                      *)
EXTENDS Naturals, Sequences

CONSTANTS
    MaxMessages,   \* the largest number of messages that port a sends
    MaxTransfers,  \* the largest number of transfers of port b
    Bug            \* "none", or the name of a rule to remove

\* An item of the queue is the number of a message, or Close: the event
\* that tells the port that its peer closed.
Close == 0
Messages == 1..MaxMessages
Items == Messages \cup {Close}
\* The value of a variable that has no item.
Nil == MaxMessages + 1
\* In the list of delivered events: the event close that a port got with
\* no wait, because it did not start.
Early == MaxMessages + 2

VARIABLES
    a_open,      \* TRUE while port a is open
    a_peer,      \* TRUE while port a has its peer
    a_closes,    \* the number of events close that port a got
    sent,        \* the number of messages that port a sent
    wire,        \* the items from port a that port b did not get
    back,        \* TRUE while the notice of the close of port b goes to a
    b_open,      \* TRUE while port b is open
    b_peer,      \* TRUE while port b has its peer
    started,     \* TRUE after the holder of port b started the port
    gen,         \* the number of transfers of port b
    queue,       \* the port message queue of port b
    received,    \* the number of messages that port b got
    flight,      \* the item that the listener process has, or Nil
    task,        \* the item in the mailbox of the listener process, or Nil
    task_gen,    \* the listener process that has the task
    answer,      \* the answer of the listener process on its way to b
    direct,      \* TRUE while an event close with no wait goes to a listener
    direct_gen,  \* the listener process that gets that event
    delivered,   \* the events that the listeners of port b got
    closes       \* closes[g] is the number of events close that the
                 \* listeners of holder g got

vars == <<a_open, a_peer, a_closes, sent, wire, back, b_open, b_peer, started,
          gen, queue, received, flight, task, task_gen, answer, direct,
          direct_gen, delivered, closes>>

a_vars == <<a_open, a_peer, a_closes, sent, back>>
listener_vars == <<task, task_gen, answer, direct, direct_gen, delivered, closes>>

Init ==
    /\ a_open = TRUE /\ a_peer = TRUE /\ a_closes = 0 /\ sent = 0
    /\ wire = <<>> /\ back = FALSE
    /\ b_open = TRUE /\ b_peer = TRUE /\ started = FALSE /\ gen = 0
    /\ queue = <<>> /\ received = 0 /\ flight = Nil
    /\ task = Nil /\ task_gen = 0 /\ answer = "none"
    /\ direct = FALSE /\ direct_gen = 0
    /\ delivered = <<>> /\ closes = [g \in 0..MaxTransfers |-> 0]

InQueue(item) == \E i \in 1..Len(queue) : queue[i] = item

-----------------------------------------------------------------------------
\* Port a

\* A process sends a message on port a. A port with no peer drops it.
Post ==
    /\ a_open /\ sent < MaxMessages
    /\ sent' = sent + 1
    /\ wire' = IF a_peer THEN Append(wire, sent + 1) ELSE wire
    /\ UNCHANGED <<a_open, a_peer, a_closes, back, b_open, b_peer, started, gen,
                   queue, received, flight>>
    /\ UNCHANGED listener_vars

\* Port a closes. The notice goes to port b after the messages.
CloseA ==
    /\ a_open
    /\ a_open' = FALSE
    /\ wire' = IF a_peer THEN Append(wire, Close) ELSE wire
    /\ UNCHANGED <<a_peer, a_closes, sent, back, b_open, b_peer, started, gen,
                   queue, received, flight>>
    /\ UNCHANGED listener_vars

\* Port a gets the notice that port b closed.
ANotice ==
    /\ back
    /\ back' = FALSE
    /\ a_peer' = FALSE
    /\ a_closes' = IF a_open THEN a_closes + 1 ELSE a_closes
    /\ UNCHANGED <<a_open, sent, wire, b_open, b_peer, started, gen, queue,
                   received, flight>>
    /\ UNCHANGED listener_vars

-----------------------------------------------------------------------------
\* The server of port b

\* The server gets the next item from port a. A message goes into the queue.
\* The notice of a close goes into the queue of a port that started. A port
\* that did not start gives the event close to its listeners with no wait.
Receive ==
    /\ b_open /\ wire # <<>>
    /\ wire' = Tail(wire)
    /\ IF Head(wire) # Close
       THEN /\ queue' = Append(queue, Head(wire))
            /\ received' = received + 1
            /\ UNCHANGED <<b_peer, direct, direct_gen>>
       ELSE /\ b_peer' = FALSE
            /\ received' = received
            /\ IF started \/ Bug = "close_waits_for_start"
               THEN /\ queue' = Append(queue, Close)
                    /\ UNCHANGED <<direct, direct_gen>>
               ELSE /\ queue' = queue
                    /\ direct' = TRUE
                    /\ direct_gen' = gen
    /\ UNCHANGED <<a_open, a_peer, a_closes, sent, back, b_open, started, gen,
                   flight, task, task_gen, answer, delivered, closes>>

\* The holder of port b starts the port.
Start ==
    /\ b_open /\ ~started
    /\ started' = TRUE
    /\ UNCHANGED <<wire, b_open, b_peer, gen, queue, received, flight>>
    /\ UNCHANGED a_vars
    /\ UNCHANGED listener_vars

\* The server gives the next item to the listener process.
Pump ==
    /\ b_open /\ started /\ flight = Nil /\ queue # <<>>
    /\ flight' = Head(queue)
    /\ task' = Head(queue)
    /\ task_gen' = gen
    /\ queue' = Tail(queue)
    /\ UNCHANGED <<wire, b_open, b_peer, started, gen, received, answer, direct,
                   direct_gen, delivered, closes>>
    /\ UNCHANGED a_vars

\* The server gets the answer of the listener process. An item that came
\* back goes to the head of the queue. An event close that came back is not
\* necessary when the transfer put one in the queue.
Answer ==
    /\ b_open /\ answer # "none"
    /\ answer' = "none"
    /\ flight' = Nil
    /\ queue' =
         IF answer = "done" \/ Bug = "returned_item_is_lost" THEN queue
         ELSE IF flight = Close /\ InQueue(Close) /\ Bug # "two_closes" THEN queue
         ELSE IF Bug = "returned_item_to_tail" THEN Append(queue, flight)
         ELSE <<flight>> \o queue
    /\ UNCHANGED <<wire, b_open, b_peer, started, gen, received, task, task_gen,
                   direct, direct_gen, delivered, closes>>
    /\ UNCHANGED a_vars

\* A transfer moves port b to a new holder. The port gets a new listener
\* process, and it waits for a start. The queue stays. The new holder of a
\* port whose peer closed gets the event close.
Transfer ==
    /\ b_open /\ gen < MaxTransfers
    /\ gen' = gen + 1
    /\ started' = FALSE
    /\ queue' = IF ~b_peer /\ ~InQueue(Close) THEN Append(queue, Close) ELSE queue
    /\ UNCHANGED <<wire, b_open, b_peer, received, flight>>
    /\ UNCHANGED a_vars
    /\ UNCHANGED listener_vars

\* Port b closes. The notice goes to port a.
CloseB ==
    /\ b_open
    /\ b_open' = FALSE
    /\ back' = b_peer
    /\ UNCHANGED <<a_open, a_peer, a_closes, sent, wire, b_peer, started, gen,
                   queue, received, flight>>
    /\ UNCHANGED listener_vars

-----------------------------------------------------------------------------
\* The listener processes of port b

\* The gate of a listener process is open while its port is open and no
\* transfer moved the port.
GateOpen(g) == b_open /\ g = gen

Count(item, g) ==
    IF item \in Messages THEN closes ELSE [closes EXCEPT ![g] = @ + 1]

\* A listener process takes its task. It runs the listeners when its gate is
\* open. If not, it gives the item back.
Run ==
    /\ task # Nil
    /\ task' = Nil
    /\ IF GateOpen(task_gen) \/ Bug = "no_gate"
       THEN /\ delivered' = Append(delivered, task)
            /\ closes' = Count(task, task_gen)
            /\ answer' = "done"
       ELSE /\ answer' = IF Bug = "no_answer_at_closed_gate" THEN answer ELSE "returned"
            /\ UNCHANGED <<delivered, closes>>
    /\ UNCHANGED <<wire, b_open, b_peer, started, gen, queue, received, flight,
                   task_gen, direct, direct_gen>>
    /\ UNCHANGED a_vars

\* A listener process takes the event close that came with no wait.
RunDirect ==
    /\ direct
    /\ direct' = FALSE
    /\ IF GateOpen(direct_gen)
       THEN /\ delivered' = Append(delivered, Early)
            /\ closes' = Count(Close, direct_gen)
       ELSE UNCHANGED <<delivered, closes>>
    /\ UNCHANGED <<wire, b_open, b_peer, started, gen, queue, received, flight,
                   task, task_gen, answer, direct_gen>>
    /\ UNCHANGED a_vars

Next ==
    \/ Post \/ CloseA \/ ANotice
    \/ Receive \/ Start \/ Pump \/ Answer \/ Transfer \/ CloseB
    \/ Run \/ RunDirect
    \/ UNCHANGED vars

\* The processes do their work. A user does an operation or does not.
Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(ANotice) /\ WF_vars(Receive) /\ WF_vars(Pump) /\ WF_vars(Answer)
    /\ WF_vars(Run) /\ WF_vars(RunDirect)

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ a_open \in BOOLEAN /\ a_peer \in BOOLEAN /\ back \in BOOLEAN
    /\ a_closes \in 0..1
    /\ sent \in 0..MaxMessages
    /\ b_open \in BOOLEAN /\ b_peer \in BOOLEAN /\ started \in BOOLEAN
    /\ gen \in 0..MaxTransfers
    /\ received \in 0..MaxMessages
    /\ flight \in Items \cup {Nil}
    /\ task \in Items \cup {Nil}
    /\ task_gen \in 0..MaxTransfers
    /\ answer \in {"none", "done", "returned"}
    /\ direct \in BOOLEAN
    /\ direct_gen \in 0..MaxTransfers

DeliveredMessages == SelectSeq(delivered, LAMBDA item : item \in Messages)
QueuedMessages == SelectSeq(queue, LAMBDA item : item \in Messages)

\* The listeners get the messages one time, in the sequence in which port a
\* sent them, and with no message left out.
MessagesInOrder ==
    \A i \in 1..Len(DeliveredMessages) : DeliveredMessages[i] = i

\* While port b is open, each message that it got is in one place: in the
\* queue, with the listener process, or delivered. Thus a transfer loses no
\* message.
NothingLost ==
    b_open =>
        received = Len(DeliveredMessages) + Len(QueuedMessages)
                   + (IF flight \in Messages /\ answer # "done" THEN 1 ELSE 0)

\* The event close that came through the queue is the last event: no
\* message comes after it.
CloseIsLast ==
    \A i \in 1..Len(delivered) : \A j \in 1..Len(delivered) :
        (delivered[i] = Close /\ i < j) => delivered[j] \notin Messages

\* The listeners of one holder get the event close one time at most.
OneClosePerHolder == \A g \in 0..MaxTransfers : closes[g] <= 1

\* The event close does not wait in the queue of a port that did not start.
\* Thus a port that only sends learns that its peer closed.
CloseDoesNotWaitForStart ==
    (b_open /\ ~b_peer /\ gen = 0 /\ ~started) => ~InQueue(Close)

\* A port gets the event close only after its peer closed.
CloseHasCause ==
    /\ (\E g \in 0..MaxTransfers : closes[g] > 0) => ~a_open
    /\ a_closes > 0 => ~b_open

\* A port that closed delivers no event.
NoEventAfterClose == [][~b_open => delivered' = delivered]_vars

\* The listeners get a message only from a port that started.
MessageOnlyAfterStart ==
    [][(Len(delivered') > Len(delivered) /\ delivered'[Len(delivered')] \in Messages)
          => started]_vars

\* A port that started, and that stays with its holder, delivers each
\* message that it got.
Idle == wire = <<>> /\ queue = <<>> /\ flight = Nil
Drains == []<>(~b_open \/ ~started \/ Idle)

\* A port that started gets the event close after its peer closed.
CloseArrives == (~a_open /\ a_peer /\ b_open /\ started) ~> (~b_open \/ ~started \/ closes[gen] = 1)

\* Port a learns that port b closed.
PeerLearnsClose == (~b_open /\ b_peer) ~> ~a_peer
=============================================================================
