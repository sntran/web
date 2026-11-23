---------------------------- MODULE SyncIterator ----------------------------
(* The calls of the processes of Web.Iterator: see                          *)
(* Web.Internal.SyncIterator.                                               *)
(*                                                                          *)
(* The iterator 1 is the iterator of an enumerable. The iterator 2 is a     *)
(* helper of the iterator 1, and the iterator 3 is a helper of the          *)
(* iterator 2. A call is a message to the process of the iterator, and the  *)
(* caller waits for the reply. The process takes one call at a time: the    *)
(* other calls wait in its mailbox. A step of a helper reads its source,    *)
(* and then runs its callback. The callback can call each iterator.         *)
(*                                                                          *)
(* A call carries the chain of its caller: the iterators that run a step   *)
(* and wait for it. A process puts itself at the head of the chain of its   *)
(* step. A call of an iterator that is in the chain of the caller fails at  *)
(* once with TypeError (GeneratorValidate: the generator is "executing"),   *)
(* and the step of the caller fails. An error of a call fails the step of   *)
(* the caller.                                                              *)
(*                                                                          *)
(* The module shows that each call of a user gets its result: a call that   *)
(* would wait for itself fails. With two users, a call of an iterator that  *)
(* runs for the other user waits, and it does not fail. (Two users whose    *)
(* callbacks call the iterators of each other in a cycle can wait for each  *)
(* other, as two processes that call each other. ECMAScript has one thread, *)
(* thus no such case. The configuration with two users has callbacks that   *)
(* call only the iterators before them: Acyclic.)                           *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design.                                                      *)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Users,      \* the processes that call the iterators, one call each: numbers above 3
    Acyclic,    \* TRUE: a callback calls only the iterators before it
    Bug         \* "none", or the name of a rule to remove

Iters == {1, 2, 3}

\* The source of each iterator, or 0.
Src == [i \in Iters |-> i - 1]

Processes == Users \cup Iters

\* The iterators that the callback of the iterator i can call.
Targets(i) == IF i = 1 THEN {} ELSE IF Acyclic THEN 1..(i - 1) ELSE Iters

VARIABLES
    called,     \* called[u]: TRUE after the call of the user u
    answer,     \* answer[u]: "none", "value", or "error"
    waitingOn,  \* waitingOn[p]: the iterator that the process p waits for, or 0
    queue,      \* queue[i]: the calls that wait in the mailbox of the iterator i
    serving,    \* serving[i]: the caller of the step that runs, or 0
    phase,      \* phase[i]: "idle", "source", "callback", or "reply"
    chain,      \* chain[p]: the chain of the process p
    failed,     \* failed[i]: TRUE when the step of i failed
    wrongErrors \* the TypeErrors of calls of iterators that are not in the chain

vars == <<called, answer, waitingOn, queue, serving, phase, chain, failed, wrongErrors>>

Init ==
    /\ called = [u \in Users |-> FALSE]
    /\ answer = [u \in Users |-> "none"]
    /\ waitingOn = [p \in Processes |-> 0]
    /\ queue = [i \in Iters |-> <<>>]
    /\ serving = [i \in Iters |-> 0]
    /\ phase = [i \in Iters |-> "idle"]
    /\ chain = [p \in Processes |-> <<>>]
    /\ failed = [i \in Iters |-> FALSE]
    /\ wrongErrors = 0

Range(s) == {s[k] : k \in 1..Len(s)}

\* A user calls the iterator i, and waits.
UserCall(u, i) ==
    /\ ~called[u]
    /\ called' = [called EXCEPT ![u] = TRUE]
    /\ queue' = [queue EXCEPT ![i] = Append(@, u)]
    /\ waitingOn' = [waitingOn EXCEPT ![u] = i]
    /\ UNCHANGED <<answer, serving, phase, chain, failed, wrongErrors>>

\* The process takes the first call of its mailbox, when no step runs.
Serve(i) ==
    /\ serving[i] = 0
    /\ queue[i] # <<>>
    /\ LET c == Head(queue[i])
       IN /\ serving' = [serving EXCEPT ![i] = c]
          /\ chain' = [chain EXCEPT ![i] =
                         IF Bug = "no_propagation" THEN <<i>> ELSE <<i>> \o chain[c]]
    /\ queue' = [queue EXCEPT ![i] = Tail(@)]
    /\ phase' = [phase EXCEPT ![i] = IF Src[i] # 0 THEN "source" ELSE "reply"]
    /\ failed' = [failed EXCEPT ![i] = FALSE]
    /\ UNCHANGED <<called, answer, waitingOn, wrongErrors>>

\* The step of i calls the iterator t, and goes on with `after`.
CallFrom(i, t, after) ==
    IF (t \in Range(chain[i]) /\ Bug # "no_chain")
       \/ (Bug = "error_on_busy" /\ serving[t] # 0)
    THEN /\ failed' = [failed EXCEPT ![i] = TRUE]
         /\ phase' = [phase EXCEPT ![i] = "reply"]
         /\ wrongErrors' = wrongErrors + (IF t \in Range(chain[i]) THEN 0 ELSE 1)
         /\ UNCHANGED <<queue, waitingOn>>
    ELSE /\ queue' = [queue EXCEPT ![t] = Append(@, i)]
         /\ waitingOn' = [waitingOn EXCEPT ![i] = t]
         /\ phase' = [phase EXCEPT ![i] = after]
         /\ UNCHANGED <<failed, wrongErrors>>

Running(i) == serving[i] # 0 /\ waitingOn[i] = 0

\* A helper reads its source.
ReadSource(i) ==
    /\ Running(i) /\ phase[i] = "source"
    /\ CallFrom(i, Src[i], "callback")
    /\ UNCHANGED <<called, answer, serving, chain>>

\* The callback of a helper calls the iterator t, or no iterator (t = 0).
Callback(i, t) ==
    /\ Running(i) /\ phase[i] = "callback"
    /\ t \in {0} \cup Targets(i)
    /\ IF t = 0
       THEN /\ phase' = [phase EXCEPT ![i] = "reply"]
            /\ UNCHANGED <<queue, waitingOn, failed, wrongErrors>>
       ELSE CallFrom(i, t, "reply")
    /\ UNCHANGED <<called, answer, serving, chain>>

Callbacks(i) == \E t \in {0} \cup Targets(i) : Callback(i, t)

\* The step ends: the caller gets the result. An error fails the step of a
\* caller that is an iterator.
Reply(i) ==
    /\ Running(i) /\ phase[i] = "reply"
    /\ LET c == serving[i]
       IN /\ waitingOn' = [waitingOn EXCEPT ![c] = 0]
          /\ IF c \in Users
             THEN /\ answer' = [answer EXCEPT ![c] = IF failed[i] THEN "error" ELSE "value"]
                  /\ phase' = [phase EXCEPT ![i] = "idle"]
                  /\ UNCHANGED failed
             ELSE /\ phase' = [phase EXCEPT ![i] = "idle",
                                            ![c] = IF failed[i] THEN "reply" ELSE phase[c]]
                  /\ failed' = [failed EXCEPT ![c] = failed[c] \/ failed[i]]
                  /\ UNCHANGED answer
    /\ serving' = [serving EXCEPT ![i] = 0]
    /\ chain' = [chain EXCEPT ![i] = <<>>]
    /\ UNCHANGED <<called, queue, wrongErrors>>

Next ==
    \/ \E u \in Users, i \in Iters : UserCall(u, i)
    \/ \E i \in Iters : Serve(i) \/ ReadSource(i) \/ Callbacks(i) \/ Reply(i)
    \/ UNCHANGED vars

Spec ==
    /\ Init /\ [][Next]_vars
    /\ \A i \in Iters :
         WF_vars(Serve(i)) /\ WF_vars(ReadSource(i)) /\ WF_vars(Callbacks(i)) /\ WF_vars(Reply(i))

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ called \in [Users -> BOOLEAN]
    /\ answer \in [Users -> {"none", "value", "error"}]
    /\ waitingOn \in [Processes -> Iters \cup {0}]
    /\ serving \in [Iters -> Processes \cup {0}]
    /\ phase \in [Iters -> {"idle", "source", "callback", "reply"}]
    /\ failed \in [Iters -> BOOLEAN]

\* A process runs one step at a time, for the caller that it serves.
OneStep == \A i \in Iters : serving[i] # 0 => waitingOn[serving[i]] = i

\* A call fails with TypeError only when it would wait for itself.
NoFalseError == wrongErrors = 0

\* Each call of a user gets its result.
AllAnswered == \A u \in Users : called[u] ~> answer[u] # "none"
=============================================================================
