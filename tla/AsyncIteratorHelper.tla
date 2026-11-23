------------------------- MODULE AsyncIteratorHelper -------------------------
(* The process of a helper of Web.AsyncIterator: see                        *)
(* Web.Internal.AsyncIteratorHelper. The module shows `map`, with the       *)
(* permits of `limit`, and concurrent calls of next() and return().         *)
(*                                                                          *)
(* Each call of next() is an entry of `waiting`, in the sequence of the     *)
(* calls. A job reads the source one time and runs the mapper. A job        *)
(* starts only with a permit, and its permit goes back at the end of its    *)
(* work. The first job gives its result to the first entry, and so on. The  *)
(* source answers the reads in each sequence. The end of the source, and an *)
(* error, end the entries after it with done. return() closes the source    *)
(* when the calls before it have their results. An error of the mapper      *)
(* closes the source when its entry is the first. The process stops when   *)
(* it is done and no job runs, and also when its owner stops.               *)
(*                                                                          *)
(* The module shows that the calls get the results of sequential calls (up  *)
(* to the first end or error), that a close never changes the result of a  *)
(* read that a call waits for, that the source is closed one time only,     *)
(* that no read starts after the end, and that each call gets a result.     *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design. The value "release_before_failure" is a defect that  *)
(* a test found: a job that a different process killed gave its permit     *)
(* back before its failure, and a new read started after that failure.     *)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Calls,      \* the calls of the users: each is one next() or one return()
    Capacity,   \* the permits of `limit`; for `map`, the number of the calls
    Bug         \* "none", or the name of a rule to remove

Jobs == 1..Cardinality(Calls)

VARIABLES
    called,     \* called[c]: "none", "next", or "return"
    answer,     \* answer[c]: "none", "value", "done", or "error"
    got,        \* got[c]: the job whose value the call got, or 0
    pos,        \* pos[c]: the position of a call of next() among those calls
    nexts,      \* the number of the calls of next()
    waiting,    \* the calls of next() with no result, in their sequence
    jobs,       \* the jobs of the first entries, in the sequence of their reads
    phase,      \* phase[j] of a job: see Phases
    reads,      \* the number of the reads of the source
    pending,    \* the return() that waits for the calls before it, or "none"
    closer,     \* the call that waits for the close of the source, or "none"
    closeKind,  \* "none", "reject" (an error of the mapper), or "return"
    closes,     \* the number of the closes of the source
    accepting,  \* FALSE after return() and after the end
    completed,  \* TRUE after the end of the source, or an error
    alive       \* TRUE while the process of the helper runs

vars == <<called, answer, got, pos, nexts, waiting, jobs, phase, reads, pending,
          closer, closeKind, closes, accepting, completed, alive>>

\* "read": the job reads the source. "map": the mapper runs. "value", "error"
\* (of the source), and "throw" (of the mapper): the result of the job.
\* "killed": a job that stopped with no result. "ended": a job with no work.
Phases == {"none", "read", "map", "value", "error", "throw", "killed", "ended"}

Init ==
    /\ called = [c \in Calls |-> "none"]
    /\ answer = [c \in Calls |-> "none"]
    /\ got = [c \in Calls |-> 0]
    /\ pos = [c \in Calls |-> 0]
    /\ nexts = 0
    /\ waiting = <<>>
    /\ jobs = <<>>
    /\ phase = [j \in Jobs |-> "none"]
    /\ reads = 0
    /\ pending = "none"
    /\ closer = "none"
    /\ closeKind = "none"
    /\ closes = 0
    /\ accepting = TRUE
    /\ completed = FALSE
    /\ alive = TRUE

Running(j) == phase[j] \in {"read", "map"}

InUse == Cardinality({j \in Jobs : Running(j)})

Range(s) == {s[i] : i \in 1..Len(s)}

Position(s, x) == CHOOSE i \in 1..Len(s) : s[i] = x

Remove(s, i) == SubSeq(s, 1, i - 1) \o SubSeq(s, i + 1, Len(s))

-----------------------------------------------------------------------------
\* The end of the iteration

\* The iteration ends at the entry p: each entry from p on, and a return()
\* that waits, get done.
Complete(p) ==
    /\ answer' = [c \in Calls |->
                    IF c \in Range(SubSeq(waiting, p, Len(waiting))) \/ c = pending
                    THEN "done" ELSE answer[c]]
    /\ waiting' = SubSeq(waiting, 1, p - 1)
    /\ pending' = "none"
    /\ accepting' = FALSE
    /\ completed' = TRUE

\* The job j ends the iteration: the end of the source ends its own entry, an
\* error ends the entries after its entry. A job that is not in `jobs` came
\* after the end, and has no effect.
EndAt(j, kind) ==
    IF j \in Range(jobs)
    THEN LET p == Position(jobs, j) IN
         IF kind = "end" /\ Bug = "end_keeps_later"
         THEN /\ Complete(Len(waiting) + 1)
              /\ waiting' = SubSeq(waiting, 1, Len(waiting))
              /\ jobs' = SubSeq(jobs, 1, p - 1)
         ELSE IF kind = "end"
         THEN /\ Complete(p)
              /\ jobs' = SubSeq(jobs, 1, p - 1)
         ELSE IF Bug = "error_keeps_later"
         THEN UNCHANGED <<answer, waiting, jobs, pending, accepting, completed>>
         ELSE /\ Complete(p + 1)
              /\ jobs' = SubSeq(jobs, 1, p)
    ELSE UNCHANGED <<answer, waiting, jobs, pending, accepting, completed>>

-----------------------------------------------------------------------------
\* The calls of the users

\* A call of next(). A helper that is done, or that stopped, gives done.
CallNext(c) ==
    /\ called[c] = "none"
    /\ called' = [called EXCEPT ![c] = "next"]
    /\ nexts' = nexts + 1
    /\ pos' = [pos EXCEPT ![c] = nexts + 1]
    /\ IF alive /\ accepting
       THEN /\ waiting' = Append(waiting, c)
            /\ UNCHANGED answer
       ELSE /\ answer' = [answer EXCEPT ![c] = "done"]
            /\ UNCHANGED waiting
    /\ UNCHANGED <<got, jobs, phase, reads, pending, closer, closeKind, closes,
                   accepting, completed, alive>>

\* A call of return(). It waits for the calls before it.
CallReturn(c) ==
    /\ called[c] = "none"
    /\ called' = [called EXCEPT ![c] = "return"]
    /\ IF alive /\ accepting
       THEN /\ accepting' = FALSE
            /\ pending' = c
            /\ UNCHANGED answer
       ELSE /\ answer' = [answer EXCEPT ![c] = "done"]
            /\ UNCHANGED <<accepting, pending>>
    /\ UNCHANGED <<got, pos, nexts, waiting, jobs, phase, reads, closer, closeKind,
                   closes, completed, alive>>

-----------------------------------------------------------------------------
\* The source, the mapper, and the close

\* The source answers the read of the job j.
Answer(j, o) ==
    /\ phase[j] = "read"
    /\ o \in {"value", "end", "error"}
    /\ CASE o = "value" ->
              /\ phase' = [phase EXCEPT ![j] = "map"]
              /\ UNCHANGED <<answer, waiting, jobs, pending, accepting, completed>>
         [] o = "end" ->
              /\ phase' = [phase EXCEPT ![j] = "ended"]
              /\ EndAt(j, "end")
         [] o = "error" ->
              /\ phase' = [phase EXCEPT ![j] = "error"]
              /\ EndAt(j, "error")
    /\ UNCHANGED <<called, got, pos, nexts, reads, closer, closeKind, closes, alive>>

SourceAnswers(j) == \E o \in {"value", "end", "error"} : Answer(j, o)

\* The mapper of the job j ends with a value, or fails. A failure ends the
\* iteration at once. The close of the source waits until the entry of the
\* job is the first.
MapEnd(j, o) ==
    /\ phase[j] = "map"
    /\ o \in {"ok", "throw"}
    /\ IF o = "ok"
       THEN /\ phase' = [phase EXCEPT ![j] = "value"]
            /\ UNCHANGED <<answer, waiting, jobs, pending, accepting, completed,
                           closer, closeKind, closes>>
       ELSE /\ phase' = [phase EXCEPT ![j] = "throw"]
            /\ EndAt(j, "error")
            /\ IF Bug = "close_at_error" /\ j \in Range(jobs) /\ closer = "none"
               THEN /\ closer' = waiting[Position(jobs, j)]
                    /\ closeKind' = "reject"
                    /\ closes' = closes + 1
               ELSE UNCHANGED <<closer, closeKind, closes>>
    /\ UNCHANGED <<called, got, pos, nexts, reads, alive>>

MapperEnds(j) == \E o \in {"ok", "throw"} : MapEnd(j, o)

\* A different process kills the job of a mapper. The job fails with no
\* result, before its permit goes back.
Kill(j) ==
    /\ phase[j] = "map"
    /\ IF Bug = "release_before_failure"
       THEN /\ phase' = [phase EXCEPT ![j] = "killed"]
            /\ UNCHANGED <<answer, waiting, jobs, pending, accepting, completed>>
       ELSE /\ phase' = [phase EXCEPT ![j] = "throw"]
            /\ EndAt(j, "error")
    /\ UNCHANGED <<called, got, pos, nexts, reads, closer, closeKind, closes, alive>>

\* With the defect: the failure of a killed job comes after its permit.
RecordKill(j) ==
    /\ phase[j] = "killed"
    /\ phase' = [phase EXCEPT ![j] = "throw"]
    /\ EndAt(j, "error")
    /\ UNCHANGED <<called, got, pos, nexts, reads, closer, closeKind, closes, alive>>

\* The close of the source ends. The call that waits gets its result: the
\* error of the mapper, or the result of return().
CloseEnd(o) ==
    /\ closer # "none"
    /\ o \in {"ok", "fail"}
    /\ answer' = [answer EXCEPT ![closer] =
                    IF closeKind = "return" /\ o = "ok" THEN "done" ELSE "error"]
    /\ closer' = "none"
    /\ closeKind' = "none"
    /\ UNCHANGED <<called, got, pos, nexts, waiting, jobs, phase, reads, pending,
                   closes, accepting, completed, alive>>

CloseEnds == \E o \in {"ok", "fail"} : CloseEnd(o)

-----------------------------------------------------------------------------
\* The steps of the process of the helper

\* A job starts for the first entry with no job, with a permit.
StartJob ==
    /\ alive
    /\ ~completed
    /\ Len(jobs) < Len(waiting)
    /\ InUse < Capacity
    /\ reads' = reads + 1
    /\ jobs' = Append(jobs, reads + 1)
    /\ phase' = [phase EXCEPT ![reads + 1] = "read"]
    /\ UNCHANGED <<called, answer, got, pos, nexts, waiting, pending, closer, closeKind,
                   closes, accepting, completed, alive>>

\* The first entry gets the result of its job: a value, the error of the
\* source, or, for an error of the mapper, the close of the source first.
\* With the Bug "unordered", each entry with a value gets it.
Deliver ==
    /\ closer = "none"
    /\ \E i \in 1..Len(jobs) :
         /\ i <= Len(waiting)
         /\ i = 1 \/ (Bug = "unordered" /\ phase[jobs[i]] = "value")
         /\ LET c == waiting[i]
                j == jobs[i]
            IN /\ phase[j] \in {"value", "error", "throw"}
               /\ waiting' = Remove(waiting, i)
               /\ jobs' = Remove(jobs, i)
               /\ phase' = [phase EXCEPT ![j] = "ended"]
               /\ CASE phase[j] = "value" ->
                         /\ answer' = [answer EXCEPT ![c] = "value"]
                         /\ got' = [got EXCEPT ![c] = j]
                         /\ UNCHANGED <<closer, closeKind, closes>>
                    [] phase[j] = "error" ->
                         /\ answer' = [answer EXCEPT ![c] = "error"]
                         /\ UNCHANGED <<got, closer, closeKind, closes>>
                    [] phase[j] = "throw" ->
                         /\ IF closes > 0 /\ Bug = "close_at_error"
                            THEN /\ answer' = [answer EXCEPT ![c] = "error"]
                                 /\ UNCHANGED <<closer, closeKind, closes>>
                            ELSE /\ closer' = c
                                 /\ closeKind' = "reject"
                                 /\ closes' = closes + 1
                                 /\ UNCHANGED answer
                         /\ UNCHANGED got
    /\ UNCHANGED <<called, pos, nexts, reads, pending, accepting, completed, alive>>

\* A return() that waits closes the source when the calls before it have
\* their results.
StartClose ==
    /\ pending # "none"
    /\ closer = "none"
    /\ waiting = <<>> \/ Bug = "return_not_queued"
    /\ closer' = pending
    /\ closeKind' = "return"
    /\ closes' = closes + 1
    /\ pending' = "none"
    /\ UNCHANGED <<called, answer, got, pos, nexts, waiting, jobs, phase, reads,
                   accepting, completed, alive>>

\* The process stops when it is done and no job runs.
Stop ==
    /\ alive
    /\ ~accepting
    /\ waiting = <<>>
    /\ pending = "none"
    /\ closer = "none"
    /\ (\A j \in Jobs : ~Running(j) /\ phase[j] # "killed") \/ Bug = "stop_with_jobs"
    /\ alive' = FALSE
    /\ UNCHANGED <<called, answer, got, pos, nexts, waiting, jobs, phase, reads, pending,
                   closer, closeKind, closes, accepting, completed>>

\* The owner stops. The process stops, and stops its jobs. Each call that
\* waits gets done: its process sees that the helper stopped.
OwnerStop ==
    /\ alive
    /\ alive' = FALSE
    /\ phase' = [j \in Jobs |-> IF Running(j) \/ phase[j] = "killed" THEN "ended" ELSE phase[j]]
    /\ answer' = [c \in Calls |->
                    IF c \in Range(waiting) \/ c = pending \/ c = closer
                    THEN "done" ELSE answer[c]]
    /\ waiting' = <<>>
    /\ jobs' = <<>>
    /\ pending' = "none"
    /\ closer' = "none"
    /\ closeKind' = "none"
    /\ accepting' = FALSE
    /\ UNCHANGED <<called, got, pos, nexts, reads, closes, completed>>

Next ==
    \/ \E c \in Calls : CallNext(c) \/ CallReturn(c)
    \/ \E j \in Jobs : SourceAnswers(j) \/ MapperEnds(j) \/ Kill(j) \/ RecordKill(j)
    \/ CloseEnds
    \/ StartJob \/ Deliver \/ StartClose \/ Stop
    \/ OwnerStop
    \/ UNCHANGED vars

Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(StartJob) /\ WF_vars(Deliver) /\ WF_vars(StartClose) /\ WF_vars(Stop)
    /\ WF_vars(CloseEnds)
    /\ \A j \in Jobs : WF_vars(SourceAnswers(j)) /\ WF_vars(MapperEnds(j))
    /\ \A j \in Jobs : WF_vars(RecordKill(j))

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ called \in [Calls -> {"none", "next", "return"}]
    /\ answer \in [Calls -> {"none", "value", "done", "error"}]
    /\ got \in [Calls -> 0..Cardinality(Calls)]
    /\ pos \in [Calls -> 0..Cardinality(Calls)]
    /\ phase \in [Jobs -> Phases]
    /\ reads \in 0..Cardinality(Calls)
    /\ pending \in Calls \cup {"none"}
    /\ closer \in Calls \cup {"none"}
    /\ closeKind \in {"none", "reject", "return"}
    /\ accepting \in BOOLEAN /\ completed \in BOOLEAN /\ alive \in BOOLEAN

NextCall(c) == called[c] = "next"

\* A call gets a value only after each call of next() before it has its
\* result.
InOrder ==
    \A c, d \in Calls :
        (NextCall(c) /\ NextCall(d) /\ pos[d] < pos[c] /\ answer[c] = "value")
            => answer[d] # "none"

\* The k-th call of next() gets the value of the k-th read, as sequential
\* calls do.
RaceFree == \A c \in Calls : answer[c] = "value" => got[c] = pos[c]

\* After the first end or error, no call gets a value.
EndIsFinal ==
    \A c, d \in Calls :
        (NextCall(c) /\ NextCall(d) /\ pos[d] < pos[c] /\ answer[d] \in {"done", "error"})
            => answer[c] # "value"

\* A close does not change the result of a read that a call waits for.
CloseSafe == closer # "none" => waiting = <<>>

\* The helper closes its source one time only.
CloseOnce == closes <= 1

\* The helper reads the source only for a call of next(), and with a permit.
Lazy == reads <= nexts /\ InUse <= Capacity

\* A process that stopped has no job.
StopsWithJobs == ~alive => \A j \in Jobs : ~Running(j)

Ended == completed \/ \E j \in Jobs : phase[j] = "killed"

\* No read starts after the end of the iteration.
NoReadAfterEnd == [][Ended => reads' = reads]_vars

\* Each call gets its result.
AllAnswered == \A c \in Calls : called[c] # "none" ~> answer[c] # "none"

\* A helper that is done stops.
Stops == ~accepting ~> ~alive
=============================================================================
