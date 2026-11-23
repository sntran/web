---------------------------- MODULE AsyncBuffered ----------------------------
(* The helper `buffered(limit, prepopulate)` of Web.AsyncIterator: see      *)
(* Web.Internal.AsyncIteratorHelper and Web.AsyncIterator.buffered/3.       *)
(*                                                                          *)
(* The helper starts its reads at the first next(), or at once with         *)
(* Prepopulate. Then it keeps its buffer full: it starts a read ahead for   *)
(* each free permit of the Capacity. A read keeps its permit until its      *)
(* value goes to a call: a call that waits counts towards the buffer. A     *)
(* call with no read gets one at once, with no permit. The reads are in     *)
(* their sequence, and the first read gives its result to the first call.   *)
(* After the end of the source, the calls still get the values before the  *)
(* end. return() drops the reads that no call took, waits for the calls    *)
(* before it, and closes the source. A dropped read gives its permit back   *)
(* when it settles.                                                         *)
(*                                                                          *)
(* The source answers the reads in each sequence. The module shows that    *)
(* each call gets the result of a sequential run, that the reads ahead and  *)
(* the calls that wait are never more than the Capacity, that the helper    *)
(* keeps its buffer full, that it reads nothing before the first next()    *)
(* (with no Prepopulate), and that it gives each permit back.              *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design.                                                      *)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Calls,       \* the calls of the users: each is one next() or one return()
    Capacity,    \* the permits of the limit
    Prepopulate, \* TRUE: the helper starts its reads at once
    MaxReads,    \* a bound of the reads of the model
    Bug          \* "none", or the name of a rule to remove

Reads == 1..MaxReads

VARIABLES
    called,     \* called[c]: "none", "next", or "return"
    answer,     \* answer[c]: "none", "value", "done", or "error"
    got,        \* got[c]: the read whose value the call got, or 0
    pos,        \* pos[c]: the position of a call of next() among those calls
    nexts,      \* the number of the calls of next()
    retPos,     \* the calls of next() before the first return(), or -1
    waiting,    \* the calls of next() with no result, in their sequence
    jobs,       \* the reads of the first entries and the reads ahead, in sequence
    res,        \* res[r]: "none" while the read runs, or the answer of the source
    permitted,  \* permitted[r]: TRUE for a read that started with a permit
    held,       \* held[r]: TRUE while the read holds its permit
    given,      \* given[r]: TRUE when the result of the read went to a call
    reads,      \* the number of the reads of the source
    started,    \* TRUE after the first next(), or with Prepopulate
    pending,    \* the return() that waits for the calls before it, or "none"
    closer,     \* the call that waits for the close of the source, or "none"
    closeKind,  \* "none", or "return"
    closes,     \* the number of the closes of the source
    accepting,  \* FALSE after return()
    completed,  \* TRUE after the end of the source, or an error
    alive       \* TRUE while the process of the helper runs

vars == <<called, answer, got, pos, nexts, retPos, waiting, jobs, res, permitted, held, given,
          reads, started, pending, closer, closeKind, closes, accepting, completed, alive>>

Init ==
    /\ called = [c \in Calls |-> "none"]
    /\ answer = [c \in Calls |-> "none"]
    /\ got = [c \in Calls |-> 0]
    /\ pos = [c \in Calls |-> 0]
    /\ nexts = 0
    /\ retPos = -1
    /\ waiting = <<>>
    /\ jobs = <<>>
    /\ res = [r \in Reads |-> "none"]
    /\ permitted = [r \in Reads |-> FALSE]
    /\ held = [r \in Reads |-> FALSE]
    /\ given = [r \in Reads |-> FALSE]
    /\ reads = 0
    /\ started = (Prepopulate \/ Bug = "eager")
    /\ pending = "none"
    /\ closer = "none"
    /\ closeKind = "none"
    /\ closes = 0
    /\ accepting = TRUE
    /\ completed = FALSE
    /\ alive = TRUE

Range(s) == {s[i] : i \in 1..Len(s)}

Position(s, x) == CHOOSE i \in 1..Len(s) : s[i] = x

Unstarted == Len(waiting) - Len(jobs)

Min(a, b) == IF a < b THEN a ELSE b

HeldCount == Cardinality({r \in Reads : held[r]})

\* The permits that count towards the buffer. With the Bug
\* "vended_not_counted", a read that a call waits for does not count.
Counted ==
    IF Bug = "vended_not_counted"
    THEN Cardinality({r \in Reads :
                        held[r] /\ r \notin Range(SubSeq(jobs, 1, Min(Len(waiting), Len(jobs))))})
    ELSE HeldCount

-----------------------------------------------------------------------------
\* The end of the iteration, and the reads that give no result

\* Keeps the first n reads. A dropped read that settled (also the read s
\* that settles in this step) gives its permit back; a dropped read that
\* runs keeps it until it settles.
Truncate(n, s) ==
    /\ jobs' = SubSeq(jobs, 1, Min(n, Len(jobs)))
    /\ held' = [r \in Reads |->
                  IF r \in Range(SubSeq(jobs, Min(n, Len(jobs)) + 1, Len(jobs)))
                     /\ (res[r] # "none" \/ r = s \/ Bug = "release_dropped_at_once")
                  THEN FALSE ELSE held[r]]

\* The iteration ends at the entry p: each entry from p on, and a return()
\* that waits, get done. The calls after them still get the values before
\* the end.
Complete(p) ==
    /\ answer' = [c \in Calls |->
                    IF (c \in Range(waiting) /\ Position(waiting, c) >= p) \/ c = pending
                    THEN "done" ELSE answer[c]]
    /\ waiting' = SubSeq(waiting, 1, Min(p - 1, Len(waiting)))
    /\ pending' = "none"
    /\ accepting' = (accepting /\ Bug # "end_drops_buffer")
    /\ completed' = TRUE

-----------------------------------------------------------------------------
\* The calls of the users

\* A call of next(). A helper that stopped, or after return(), gives done.
CallNext(c) ==
    /\ called[c] = "none"
    /\ called' = [called EXCEPT ![c] = "next"]
    /\ nexts' = nexts + 1
    /\ pos' = [pos EXCEPT ![c] = nexts + 1]
    /\ IF alive /\ accepting
       THEN /\ waiting' = Append(waiting, c)
            /\ started' = TRUE
            /\ UNCHANGED answer
       ELSE /\ answer' = [answer EXCEPT ![c] = "done"]
            /\ UNCHANGED <<waiting, started>>
    /\ UNCHANGED <<got, retPos, jobs, res, permitted, held, given, reads, pending, closer,
                   closeKind, closes, accepting, completed, alive>>

\* A call of return(). It drops the reads that no call can take, and waits
\* for the calls before it. After the end of the source, it gives done at
\* once.
CallReturn(c) ==
    /\ called[c] = "none"
    /\ called' = [called EXCEPT ![c] = "return"]
    /\ retPos' = IF retPos = -1 THEN nexts ELSE retPos
    /\ IF alive /\ accepting /\ ~completed
       THEN /\ accepting' = FALSE
            /\ pending' = c
            /\ IF Bug = "return_keeps_buffer"
               THEN UNCHANGED <<jobs, held>>
               ELSE Truncate(Len(waiting), 0)
            /\ UNCHANGED answer
       ELSE IF alive /\ accepting
       THEN /\ answer' = [answer EXCEPT ![c] = "done"]
            /\ accepting' = FALSE
            /\ Truncate(Len(waiting), 0)
            /\ UNCHANGED pending
       ELSE /\ answer' = [answer EXCEPT ![c] = "done"]
            /\ UNCHANGED <<accepting, pending, jobs, held>>
    /\ UNCHANGED <<got, pos, nexts, waiting, res, permitted, given, reads, started, closer,
                   closeKind, closes, completed, alive>>

-----------------------------------------------------------------------------
\* The source and the close

\* The source answers the read r. A read that no call can take gives its
\* permit back when it settles.
Answer(r, o) ==
    /\ r \in 1..reads /\ res[r] = "none"
    /\ o \in {"value", "end", "error"}
    /\ res' = [res EXCEPT ![r] = o]
    /\ IF r \notin Range(jobs)
       THEN /\ held' = [held EXCEPT ![r] = FALSE]
            /\ UNCHANGED <<answer, waiting, jobs, pending, accepting, completed>>
       ELSE LET p == Position(jobs, r) IN
            CASE o = "value" ->
                   UNCHANGED <<answer, waiting, jobs, held, pending, accepting, completed>>
              [] o = "end" ->
                   /\ Complete(p)
                   /\ Truncate(p - 1, r)
              [] o = "error" ->
                   /\ Complete(p + 1)
                   /\ Truncate(p, r)
    /\ UNCHANGED <<called, got, pos, nexts, retPos, permitted, given, reads, started, closer,
                   closeKind, closes, alive>>

SourceAnswers(r) == \E o \in {"value", "end", "error"} : Answer(r, o)

\* The close of the source ends. The call that waits gets its result.
CloseEnd(o) ==
    /\ closer # "none"
    /\ o \in {"ok", "fail"}
    /\ answer' = [answer EXCEPT ![closer] =
                    IF closeKind = "return" /\ o = "ok" THEN "done" ELSE "error"]
    /\ closer' = "none"
    /\ closeKind' = "none"
    /\ UNCHANGED <<called, got, pos, nexts, retPos, waiting, jobs, res, permitted, held, given,
                   reads, started, pending, closes, accepting, completed, alive>>

CloseEnds == \E o \in {"ok", "fail"} : CloseEnd(o)

-----------------------------------------------------------------------------
\* The steps of the process of the helper

\* A read ahead, with a free permit.
StartAhead ==
    /\ alive /\ ~completed /\ accepting
    /\ started
    /\ Counted < Capacity
    /\ Bug = "no_refill" => reads < Capacity
    /\ reads < MaxReads
    /\ reads' = reads + 1
    /\ jobs' = Append(jobs, reads + 1)
    /\ permitted' = [permitted EXCEPT ![reads + 1] = TRUE]
    /\ held' = [held EXCEPT ![reads + 1] = TRUE]
    /\ UNCHANGED <<called, answer, got, pos, nexts, retPos, waiting, res, given, started,
                   pending, closer, closeKind, closes, accepting, completed, alive>>

\* A read with no permit, for a call with no read, when no permit is free.
StartForward ==
    /\ alive /\ ~completed
    /\ Unstarted > 0
    /\ ~(started /\ accepting /\ Counted < Capacity)
    /\ Bug # "no_forward"
    /\ reads < MaxReads
    /\ reads' = reads + 1
    /\ jobs' = Append(jobs, reads + 1)
    /\ UNCHANGED <<called, answer, got, pos, nexts, retPos, waiting, res, permitted, held, given,
                   started, pending, closer, closeKind, closes, accepting, completed, alive>>

\* After the end, an entry with no read gets done.
EndUnmatched ==
    /\ completed
    /\ Len(waiting) > Len(jobs)
    /\ answer' = [c \in Calls |->
                    IF c \in Range(SubSeq(waiting, Len(jobs) + 1, Len(waiting)))
                    THEN "done" ELSE answer[c]]
    /\ waiting' = SubSeq(waiting, 1, Len(jobs))
    /\ UNCHANGED <<called, got, pos, nexts, retPos, jobs, res, permitted, held, given, reads,
                   started, pending, closer, closeKind, closes, accepting, completed, alive>>

\* The first entry gets the result of the first read, and the read gives
\* its permit back. An error of the source does not close it.
Deliver ==
    /\ closer = "none"
    /\ jobs # <<>> /\ waiting # <<>>
    /\ res[Head(jobs)] \in {"value", "error"}
    /\ LET c == Head(waiting)
           r == Head(jobs)
       IN /\ waiting' = Tail(waiting)
          /\ jobs' = Tail(jobs)
          /\ held' = [held EXCEPT ![r] = FALSE]
          /\ given' = [given EXCEPT ![r] = TRUE]
          /\ answer' = [answer EXCEPT ![c] = res[r]]
          /\ got' = [got EXCEPT ![c] = IF res[r] = "value" THEN r ELSE 0]
    /\ UNCHANGED <<called, pos, nexts, retPos, res, permitted, reads, started, pending, closer,
                   closeKind, closes, accepting, completed, alive>>

\* A return() that waits closes the source when the calls before it have
\* their results.
StartClose ==
    /\ pending # "none"
    /\ closer = "none"
    /\ waiting = <<>>
    /\ closer' = pending
    /\ closeKind' = "return"
    /\ closes' = closes + 1
    /\ pending' = "none"
    /\ UNCHANGED <<called, answer, got, pos, nexts, retPos, waiting, jobs, res, permitted, held,
                   given, reads, started, accepting, completed, alive>>

\* The process stops when it is done and no read runs.
Stop ==
    /\ alive
    /\ ~accepting \/ (completed /\ jobs = <<>>)
    /\ waiting = <<>>
    /\ pending = "none"
    /\ closer = "none"
    /\ \A r \in 1..reads : res[r] # "none"
    /\ alive' = FALSE
    /\ UNCHANGED <<called, answer, got, pos, nexts, retPos, waiting, jobs, res, permitted, held,
                   given, reads, started, pending, closer, closeKind, closes, accepting,
                   completed>>

Next ==
    \/ \E c \in Calls : CallNext(c) \/ CallReturn(c)
    \/ \E r \in Reads : SourceAnswers(r)
    \/ StartAhead \/ StartForward \/ EndUnmatched \/ Deliver \/ StartClose \/ Stop
    \/ CloseEnds
    \/ UNCHANGED vars

Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(StartAhead) /\ WF_vars(StartForward) /\ WF_vars(EndUnmatched)
    /\ WF_vars(Deliver) /\ WF_vars(StartClose) /\ WF_vars(Stop) /\ WF_vars(CloseEnds)
    /\ \A r \in Reads : WF_vars(SourceAnswers(r))

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ called \in [Calls -> {"none", "next", "return"}]
    /\ answer \in [Calls -> {"none", "value", "done", "error"}]
    /\ got \in [Calls -> 0..MaxReads]
    /\ res \in [Reads -> {"none", "value", "end", "error"}]
    /\ permitted \in [Reads -> BOOLEAN] /\ held \in [Reads -> BOOLEAN]
    /\ given \in [Reads -> BOOLEAN]
    /\ pending \in Calls \cup {"none"}
    /\ closer \in Calls \cup {"none"}
    /\ closeKind \in {"none", "return"}
    /\ started \in BOOLEAN /\ accepting \in BOOLEAN /\ completed \in BOOLEAN
    /\ alive \in BOOLEAN

NextCall(c) == called[c] = "next"

\* A call of next() before the first return().
Counts(c) == NextCall(c) /\ (retPos = -1 \/ pos[c] <= retPos)

\* The result of the k-th call of next() of a sequential run: the read k, or
\* the end or the error of the first read before it that has no value.
Expected(k) ==
    IF \A i \in 1..k : res[i] = "value"
    THEN <<"value", k>>
    ELSE LET f == CHOOSE i \in 1..k : res[i] # "value" /\ \A h \in 1..(i - 1) : res[h] = "value"
         IN CASE res[f] = "none" -> <<"unknown", 0>>
              [] f < k -> <<"done", 0>>
              [] res[f] = "end" -> <<"done", 0>>
              [] OTHER -> <<"error", 0>>

\* Each call gets the result of a sequential run.
RaceFree ==
    \A c \in Calls :
        (Counts(c) /\ answer[c] # "none" /\ Expected(pos[c])[1] # "unknown")
            => /\ answer[c] = Expected(pos[c])[1]
               /\ answer[c] = "value" => got[c] = pos[c]

\* A call gets a value only after each call of next() before it has its
\* result.
InOrder ==
    \A c, d \in Calls :
        (NextCall(c) /\ NextCall(d) /\ pos[d] < pos[c] /\ answer[c] = "value")
            => answer[d] # "none"

\* The reads with a permit whose value did not go to a call, and that a call
\* can take or that run, are never more than the Capacity.
Buffer ==
    Cardinality({r \in Reads : permitted[r] /\ ~given[r] /\ (r \in Range(jobs) \/ res[r] = "none")})
        <= Capacity

\* The helper keeps its buffer full: it can start a read ahead for each free
\* permit.
Full ==
    (alive /\ started /\ accepting /\ ~completed /\ HeldCount < Capacity /\ reads < MaxReads)
        => ENABLED StartAhead

\* A call with no read gets one at once, also when no permit is free.
Forward ==
    (alive /\ ~completed /\ Unstarted > 0 /\ reads < MaxReads /\ HeldCount >= Capacity)
        => ENABLED StartForward

\* With no Prepopulate, the helper reads nothing before the first next().
Lazy == (~Prepopulate /\ nexts = 0) => reads = 0

\* A read that runs holds its permit.
HeldWhileRunning == \A r \in Reads : (permitted[r] /\ res[r] = "none") => held[r]

\* A helper that stopped holds no permit.
ReleasesAll == ~alive => \A r \in Reads : ~held[r]

\* The helper closes its source one time only.
CloseOnce == closes <= 1

\* No read starts after the end of the iteration.
NoReadAfterEnd == [][completed => reads' = reads]_vars

\* Each call gets its result.
AllAnswered == \A c \in Calls : called[c] # "none" ~> answer[c] # "none"

\* A helper that is done stops.
Stops == ~accepting ~> ~alive
=============================================================================
