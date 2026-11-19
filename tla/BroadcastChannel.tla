--------------------------- MODULE BroadcastChannel ---------------------------
(* The channels of Web.BroadcastChannel that have one name.                  *)
(*                                                                           *)
(* Each channel has its own processes. A channel sends a message to the      *)
(* mailbox of each other open channel, and does not wait. The listener       *)
(* process of a channel takes the messages of its mailbox one at a time.     *)
(*                                                                           *)
(* The listener of a channel in the set Slow does not return. The module     *)
(* shows that such a channel does not stop the other channels.               *)
(*                                                                           *)
(* The constant Bug is "none" for the design. Each other value removes one   *)
(* rule of the design. The value "one_dispatcher" is the first design of     *)
(* the library: one process delivered each message to one channel at a       *)
(* time, and waited for that channel.                                        *)
EXTENDS Naturals, Sequences

CONSTANTS
    Channels,  \* the channels
    Senders,   \* the channels that send messages
    MaxPosts,  \* the largest number of messages that one channel sends
    Slow,      \* the channels whose listener does not return
    Bug        \* "none", or the name of a rule to remove

VARIABLES
    open,    \* open[c] is TRUE while channel c is open
    posted,  \* posted[c] is the number of messages that channel c sent
    box,     \* box[c] is the sequence of messages that channel c did not
             \* deliver
    got      \* got[c] is the sequence of messages that the listeners of
             \* channel c got

vars == <<open, posted, box, got>>

\* A message is the channel that sent it, and its number for that channel.
Message(c, n) == <<c, n>>
Sender(m) == m[1]
Number(m) == m[2]

Init ==
    /\ open = [c \in Channels |-> TRUE]
    /\ posted = [c \in Channels |-> 0]
    /\ box = [c \in Channels |-> <<>>]
    /\ got = [c \in Channels |-> <<>>]

\* The channels that get a message of channel c.
Destinations(c) ==
    {d \in Channels : open[d] /\ (d # c \/ Bug = "message_to_sender")}

\* A process sends a message on channel c.
Post(c) ==
    /\ c \in Senders /\ open[c] /\ posted[c] < MaxPosts
    /\ posted' = [posted EXCEPT ![c] = @ + 1]
    /\ box' = [d \in Channels |->
                 IF d \in Destinations(c)
                 THEN Append(box[d], Message(c, posted[c] + 1))
                 ELSE box[d]]
    /\ UNCHANGED <<open, got>>

\* With one dispatcher, a message for a slow channel stops the delivery to
\* each channel.
Blocked == Bug = "one_dispatcher" /\ \E s \in Slow : box[s] # <<>>

\* The listener process of channel c takes its next message. A channel that
\* closed drops the message.
Deliver(c) ==
    /\ c \notin Slow /\ box[c] # <<>> /\ ~Blocked
    /\ box' = [box EXCEPT ![c] = Tail(@)]
    /\ got' = IF open[c] \/ Bug = "closed_channel_delivers"
              THEN [got EXCEPT ![c] = Append(@, Head(box[c]))]
              ELSE got
    /\ UNCHANGED <<open, posted>>

Close(c) ==
    /\ open[c]
    /\ open' = [open EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<posted, box, got>>

Next ==
    \/ \E c \in Channels : Post(c) \/ Deliver(c) \/ Close(c)
    \/ UNCHANGED vars

Spec == Init /\ [][Next]_vars /\ \A c \in Channels : WF_vars(Deliver(c))

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ open \in [Channels -> BOOLEAN]
    /\ posted \in [Channels -> 0..MaxPosts]

\* A channel does not get its own message.
NoMessageToSender ==
    \A c \in Channels : \A i \in 1..Len(got[c]) : Sender(got[c][i]) # c

\* A channel gets the messages of one sender in the sequence in which that
\* channel sent them, one time, and with no message left out.
SenderOrder ==
    \A c \in Channels : \A j \in 1..Len(got[c]) :
        LET m == got[c][j] IN
        /\ \A i \in 1..(j - 1) :
               Sender(got[c][i]) = Sender(m) => Number(got[c][i]) < Number(m)
        /\ Number(m) > 1 =>
               \E i \in 1..(j - 1) :
                   got[c][i] = Message(Sender(m), Number(m) - 1)

\* A channel gets only a message that a channel sent.
OnlyPostedMessages ==
    \A c \in Channels : \A i \in 1..Len(got[c]) :
        Number(got[c][i]) <= posted[Sender(got[c][i])]

\* A channel that closed delivers no message.
NoMessageAfterClose ==
    [][\A c \in Channels : ~open[c] => got'[c] = got[c]]_vars

\* A channel does not open again.
StaysClosed == [][\A c \in Channels : ~open[c] => ~open'[c]]_vars

\* A channel whose listeners return delivers each message that it has. A
\* slow channel does not change this.
NoWaitForSlowChannel ==
    \A c \in Channels \ Slow : []<>(box[c] = <<>>)
=============================================================================
