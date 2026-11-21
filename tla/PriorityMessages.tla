--------------------------- MODULE PriorityMessages ---------------------------
(* The priority messages of Web.Stream: an abort, a cancel, or an error.     *)
(*                                                                          *)
(* Process S writes to the stream, and then aborts it. Process O writes to   *)
(* the stream two times. The abort is a priority message: it goes before the *)
(* usual messages that wait in the mailbox, also before the earlier messages *)
(* of S. Thus S sends a usual fence before the abort. The stream that gets   *)
(* the abort handles the usual messages of S up to the fence first, then the *)
(* abort, and then the messages of O. A fence that the stream handles before *)
(* the abort comes tells it that it handled the messages of S before it.     *)
(*                                                                          *)
(* Each sender has a channel that keeps the sequence of its messages. A     *)
(* message of a channel comes to the mailbox at a time that the model does  *)
(* not fix. S can stop at each step.                                        *)
(*                                                                          *)
(* Each usual message tells its sender: the stream finds the messages of S  *)
(* by their sender. A message with no sender comes from a process that sends *)
(* no priority message to the stream, and the stream handles it after the    *)
(* abort.                                                                    *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design. "no_fence" is the design before the fence.           *)
EXTENDS Naturals, Sequences

CONSTANTS
    Bug     \* "none", or the name of a rule to remove

VARIABLES
    pc,       \* the step of S: "write", "abort", "fence", "done", or "stopped"
    sent,     \* the number of writes that O sent
    fromS,    \* the messages of S that did not come to the mailbox
    fromO,    \* the messages of O that did not come to the mailbox
    box,      \* the mailbox of the stream
    passed,   \* TRUE after the stream handled the fence before the abort
    ahead,    \* the writes of O in the mailbox when the abort came
    log       \* the events that the stream handled, in their sequence

vars == <<pc, sent, fromS, fromO, box, passed, ahead, log>>

Writes == {"S1", "O1", "O2"}

Init ==
    /\ pc = "write" /\ sent = 0
    /\ fromS = <<>> /\ fromO = <<>> /\ box = <<>>
    /\ passed = FALSE /\ ahead = {} /\ log = <<>>

Has(s, m) == \E i \in 1..Len(s) : s[i] = m
Index(s, m) == CHOOSE i \in 1..Len(s) : s[i] = m

\* The subsequence of s with the elements that `keep` accepts.
RECURSIVE Select(_, _)
Select(s, keep(_)) ==
    IF s = <<>> THEN <<>>
    ELSE (IF keep(Head(s)) THEN <<Head(s)>> ELSE <<>>) \o Select(Tail(s), keep)

SWrite ==
    /\ pc = "write"
    /\ fromS' = Append(fromS, "S1") /\ pc' = "abort"
    /\ UNCHANGED <<sent, fromO, box, passed, ahead, log>>

\* S aborts the stream: the fence, and then the abort.
SAbort ==
    /\ pc = "abort"
    /\ CASE Bug = "no_fence" -> fromS' = Append(fromS, "P") /\ pc' = "done"
         [] Bug = "usual_abort" -> fromS' = Append(fromS, "U") /\ pc' = "done"
         [] Bug = "fence_after" -> fromS' = Append(fromS, "P") /\ pc' = "fence"
         [] OTHER -> fromS' = fromS \o <<"F", "P">> /\ pc' = "done"
    /\ UNCHANGED <<sent, fromO, box, passed, ahead, log>>

\* The fence after the abort (Bug "fence_after").
SFence ==
    /\ pc = "fence"
    /\ fromS' = Append(fromS, "F") /\ pc' = "done"
    /\ UNCHANGED <<sent, fromO, box, passed, ahead, log>>

SStop ==
    /\ pc \in {"write", "abort", "fence"}
    /\ pc' = "stopped"
    /\ UNCHANGED <<sent, fromS, fromO, box, passed, ahead, log>>

OWrite ==
    /\ sent < 2
    /\ fromO' = Append(fromO, IF sent = 0 THEN "O1" ELSE "O2")
    /\ sent' = sent + 1
    /\ UNCHANGED <<pc, fromS, box, passed, ahead, log>>

\* A message comes to the mailbox. The abort goes first: no other priority
\* message is in the model. The usual abort (Bug "usual_abort") goes last.
Comes(m) ==
    /\ box' = IF m = "P" THEN <<"P">> \o box ELSE Append(box, m)
    /\ ahead' = IF m \in {"P", "U"} THEN {x \in {"O1", "O2"} : Has(box, x)} ELSE ahead

SComes ==
    /\ fromS # <<>>
    /\ fromS' = Tail(fromS) /\ Comes(Head(fromS))
    /\ UNCHANGED <<pc, sent, fromO, passed, log>>

OComes ==
    /\ fromO # <<>>
    /\ fromO' = Tail(fromO) /\ Comes(Head(fromO))
    /\ UNCHANGED <<pc, sent, fromS, passed, log>>

\* The messages that the stream handles before the abort.
IsS(x) == x = "S1"
Any(x) == x # "F"
Before == SubSeq(box, 2, Index(box, "F") - 1)
\* With Bug "no_sender", the write of S does not tell its sender: the stream
\* cannot find it, and handles it after the abort.
Earlier == CASE Bug = "take_all" -> Select(Before, Any)
             [] Bug = "no_sender" -> <<>>
             [] OTHER -> Select(Before, IsS)
Rest == Select(Tail(box), LAMBDA x : x # "F" /\ ~Has(Earlier, x))

\* The stream handles the first message of its mailbox. For the abort, it
\* waits until the fence is in the mailbox, unless it handled the fence.
Take ==
    /\ box # <<>>
    /\ LET m == Head(box) IN
       CASE m \in Writes ->
              log' = Append(log, m) /\ box' = Tail(box) /\ UNCHANGED passed
         [] m = "F" ->
              /\ box' = Tail(box) /\ log' = log
              /\ passed' = (Bug # "forget_fence")
         [] m = "U" \/ (m = "P" /\ (passed \/ Bug = "no_fence")) ->
              log' = Append(log, "A") /\ box' = Tail(box) /\ passed' = FALSE
         [] m = "P" /\ Has(box, "F") ->
              /\ log' = log \o Earlier \o <<"A">>
              /\ box' = Rest
              /\ UNCHANGED passed
         [] OTHER -> FALSE
    /\ UNCHANGED <<pc, sent, fromS, fromO, ahead>>

Next ==
    \/ SWrite \/ SAbort \/ SFence \/ SStop \/ OWrite \/ SComes \/ OComes \/ Take
    \/ UNCHANGED vars

Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(SWrite) /\ WF_vars(SAbort) /\ WF_vars(OWrite)
    /\ WF_vars(SComes) /\ WF_vars(OComes) /\ WF_vars(Take)

-----------------------------------------------------------------------------
\* Properties

Messages == Writes \cup {"F", "P", "U"}

TypeOK ==
    /\ pc \in {"write", "abort", "fence", "done", "stopped"}
    /\ sent \in 0..2
    /\ \A i \in 1..Len(fromS) : fromS[i] \in Messages
    /\ \A i \in 1..Len(fromO) : fromO[i] \in Messages
    /\ \A i \in 1..Len(box) : box[i] \in Messages
    /\ passed \in BOOLEAN /\ ahead \subseteq {"O1", "O2"}
    /\ \A i \in 1..Len(log) : log[i] \in Writes \cup {"A"}

\* The stream handles the write of S before the abort of S: the sequence of
\* one sender.
SenderOrder == Has(log, "A") => (Has(log, "S1") /\ Index(log, "S1") < Index(log, "A"))

\* The abort comes before the writes of O that wait in the mailbox.
AbortPasses ==
    \A o \in ahead : Has(log, o) => (Has(log, "A") /\ Index(log, "A") < Index(log, o))

\* The stream handles each message that comes.
Progress == <>[](fromS = <<>> /\ fromO = <<>> /\ box = <<>>)
=============================================================================
