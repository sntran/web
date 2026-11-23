---------------------------- MODULE AsyncFlatMap ----------------------------
(* The concurrent calls of next() on a helper of `flatMap`: see             *)
(* Web.Internal.AsyncIteratorHelper and Web.AsyncIterator.flat_map/2.       *)
(*                                                                          *)
(* Each call of next() is an entry of `waiting`, in the sequence of the     *)
(* calls. A job reads an iterator one time, and the jobs are in the         *)
(* sequence of their reads. An "outer" job reads the source, runs the       *)
(* mapper, and gives the next inner iterator: a generation. Only one outer  *)
(* job runs at a time, and only when no inner iterator is open. When an     *)
(* inner iterator is open, each entry with no job gets an "inner" job: a    *)
(* read of that iterator, at the same time as the other reads.              *)
(*                                                                          *)
(* An inner read that gives the end removes its job, and each later job of  *)
(* its generation: their entries get later values. An inner read that      *)
(* fails waits ("deferred") while a read of the same generation before it  *)
(* can still give the end. The first job gives its result to the first     *)
(* entry. An error closes the source before its entry gets it. return()    *)
(* closes the open inner iterator and the source when the calls before it  *)
(* have their results.                                                      *)
(*                                                                          *)
(* The iterators answer each read with each outcome, in each sequence. The *)
(* module shows that each call gets the result of a sequential run on the   *)
(* same answers (SeqRun), that the reads of one inner iterator run at the same *)
(* time, that the source is read only after the end of the inner iterator, *)
(* and that return() closes the inner iterator of the last value.          *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design. The value "one_at_a_time" is the behavior before    *)
(* this design: one read at a time.                                         *)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Calls,      \* the calls of the users: each is one next() or one return()
    Inners,     \* the number of the inner iterators that the source can give
    MaxJobs,    \* a bound of the jobs of the model
    Bug         \* "none", or the name of a rule to remove

JobIds == 1..MaxJobs

VARIABLES
    called,     \* called[c]: "none", "next", or "return"
    answer,     \* answer[c]: "none", "value", "done", or "error"
    got,        \* got[c]: <<generation, index>> of the value that the call got
    pos,        \* pos[c]: the position of a call of next() among those calls
    nexts,      \* the number of the calls of next()
    retPos,     \* the calls of next() before the first return(), or -1
    waiting,    \* the calls of next() with no result, in their sequence
    jobs,       \* the jobs of the first entries, in the sequence of their reads
    st,         \* st[j] of a job in `jobs`: "running", "value", "error", "deferred"
    kind,       \* kind[j]: "none", "outer", or "inner"
    gen,        \* gen[j]: the generation that an outer job gives, or that an inner job reads
    idx,        \* idx[j]: the index of the read of an inner job in its generation
    ans,        \* ans[j]: "none", or the answer of the iterator to the job
    njobs,      \* the number of the jobs that started
    outers,     \* the number of the reads of the source
    pulls,      \* pulls[g]: the number of the reads of the inner iterator g
    inner,      \* the open inner iterator, or 0
    failed,     \* TRUE when the open inner iterator has a deferred error
    pending,    \* the return() that waits for the calls before it, or "none"
    closer,     \* the call that waits for the close, or "none"
    closeKind,  \* "none", "reject" (an error), or "return"
    closeInner, \* the inner iterator that the close closes, or 0
    closes,     \* the number of the closes of the source
    innerCloses, \* the number of the closes of the inner iterators
    accepting,  \* FALSE after return() and after the end
    completed,  \* TRUE after the end of the source, or an error
    alive       \* TRUE while the process of the helper runs

vars == <<called, answer, got, pos, nexts, retPos, waiting, jobs, st, kind, gen, idx, ans,
          njobs, outers, pulls, inner, failed, pending, closer, closeKind, closeInner,
          closes, innerCloses, accepting, completed, alive>>

jobVars == <<jobs, st, kind, gen, idx, njobs, outers, pulls>>

Init ==
    /\ called = [c \in Calls |-> "none"]
    /\ answer = [c \in Calls |-> "none"]
    /\ got = [c \in Calls |-> <<0, 0>>]
    /\ pos = [c \in Calls |-> 0]
    /\ nexts = 0
    /\ retPos = -1
    /\ waiting = <<>>
    /\ jobs = <<>>
    /\ st = [j \in JobIds |-> "none"]
    /\ kind = [j \in JobIds |-> "none"]
    /\ gen = [j \in JobIds |-> 0]
    /\ idx = [j \in JobIds |-> 0]
    /\ ans = [j \in JobIds |-> "none"]
    /\ njobs = 0
    /\ outers = 0
    /\ pulls = [g \in 1..Inners |-> 0]
    /\ inner = 0
    /\ failed = FALSE
    /\ pending = "none"
    /\ closer = "none"
    /\ closeKind = "none"
    /\ closeInner = 0
    /\ closes = 0
    /\ innerCloses = 0
    /\ accepting = TRUE
    /\ completed = FALSE
    /\ alive = TRUE

Range(s) == {s[i] : i \in 1..Len(s)}

Position(s, x) == CHOOSE i \in 1..Len(s) : s[i] = x

Started == 1..njobs

Unstarted == Len(waiting) - Len(jobs)

OuterRunning == \E j \in Range(jobs) : kind[j] = "outer"

-----------------------------------------------------------------------------
\* The result of a sequential run on the same answers

\* The inner job of the generation g with the index m, or 0.
PullOf(g, m) ==
    IF \E j \in Started : kind[j] = "inner" /\ gen[j] = g /\ idx[j] = m
    THEN CHOOSE j \in Started : kind[j] = "inner" /\ gen[j] = g /\ idx[j] = m
    ELSE 0

\* The answer of a read: "none" while it runs, "missing" for a read that
\* did not start.
InnerAns(g, m) == IF PullOf(g, m) = 0 THEN "missing" ELSE ans[PullOf(g, m)]

\* The answer of the n-th read of the source.
OuterAns(n) ==
    IF \E j \in Started : kind[j] = "outer" /\ gen[j] = n
    THEN ans[CHOOSE j \in Started : kind[j] = "outer" /\ gen[j] = n]
    ELSE "missing"

\* The result of the k-th call of next() of a sequential run, from the read
\* m of the inner iterator g (g = 0 before the first read of the source).
RECURSIVE SeqRun(_, _, _)
SeqRun(g, m, k) ==
    LET a == IF g = 0 THEN "done" ELSE InnerAns(g, m)
    IN CASE a = "value" -> IF k = 1 THEN <<"value", g, m>> ELSE SeqRun(g, m + 1, k - 1)
         [] a = "error" -> IF k = 1 THEN <<"error", 0, 0>> ELSE <<"done", 0, 0>>
         [] a = "done" ->
              LET o == OuterAns(g + 1)
              IN CASE o = "inner" -> SeqRun(g + 1, 1, k)
                   [] o = "end" -> <<"done", 0, 0>>
                   [] o = "error" -> IF k = 1 THEN <<"error", 0, 0>> ELSE <<"done", 0, 0>>
                   [] o = "none" -> <<"unknown", 0, 0>>
                   [] OTHER -> <<"missing", 0, 0>>
         [] a = "none" -> <<"unknown", 0, 0>>
         [] OTHER -> <<"missing", 0, 0>>

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
    /\ inner' = 0
    /\ failed' = FALSE

\* The job at the position p fails: the entries after it end, and it gives
\* the error when it is the first job.
EndWithError(p) ==
    /\ Complete(p + 1)
    /\ jobs' = SubSeq(jobs, 1, p)
    /\ st' = [st EXCEPT ![jobs[p]] = "error"]

\* TRUE when a job of the same inner iterator before the position p can
\* still give the end.
PendingBefore(p) ==
    /\ kind[jobs[p]] = "inner"
    /\ \E i \in 1..(p - 1) : gen[jobs[i]] = gen[jobs[p]] /\ st[jobs[i]] \in {"running", "deferred"}

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
    /\ UNCHANGED <<got, retPos, jobVars, ans, inner, failed, pending, closer, closeKind,
                   closeInner, closes, innerCloses, accepting, completed, alive>>

\* A call of return(). It waits for the calls before it.
CallReturn(c) ==
    /\ called[c] = "none"
    /\ called' = [called EXCEPT ![c] = "return"]
    /\ retPos' = IF retPos = -1 THEN nexts ELSE retPos
    /\ IF alive /\ accepting
       THEN /\ accepting' = FALSE
            /\ pending' = c
            /\ UNCHANGED answer
       ELSE /\ answer' = [answer EXCEPT ![c] = "done"]
            /\ UNCHANGED <<accepting, pending>>
    /\ UNCHANGED <<got, pos, nexts, waiting, jobVars, ans, inner, failed, closer, closeKind,
                   closeInner, closes, innerCloses, completed, alive>>

-----------------------------------------------------------------------------
\* The steps of the process of the helper

\* A read of the source, when no inner iterator is open.
StartOuter ==
    /\ alive /\ ~completed
    /\ Unstarted > 0
    /\ ~OuterRunning
    /\ inner = 0
    /\ njobs < MaxJobs
    /\ njobs' = njobs + 1
    /\ outers' = outers + 1
    /\ jobs' = Append(jobs, njobs + 1)
    /\ st' = [st EXCEPT ![njobs + 1] = "running"]
    /\ kind' = [kind EXCEPT ![njobs + 1] = "outer"]
    /\ gen' = [gen EXCEPT ![njobs + 1] = outers + 1]
    /\ UNCHANGED <<called, answer, got, pos, nexts, retPos, waiting, idx, ans, pulls, inner,
                   failed, pending, closer, closeKind, closeInner, closes, innerCloses,
                   accepting, completed, alive>>

\* A read of the open inner iterator for the first entry with no job, at
\* the same time as the other reads.
StartPull ==
    /\ alive /\ ~completed
    /\ Unstarted > 0
    /\ ~OuterRunning
    /\ inner # 0 /\ ~failed
    /\ Bug = "one_at_a_time" => \A j \in Range(jobs) : kind[j] # "inner" \/ gen[j] # inner
    /\ njobs < MaxJobs
    /\ njobs' = njobs + 1
    /\ jobs' = Append(jobs, njobs + 1)
    /\ st' = [st EXCEPT ![njobs + 1] = "running"]
    /\ kind' = [kind EXCEPT ![njobs + 1] = "inner"]
    /\ gen' = [gen EXCEPT ![njobs + 1] = inner]
    /\ idx' = [idx EXCEPT ![njobs + 1] = pulls[inner] + 1]
    /\ pulls' = [pulls EXCEPT ![inner] = @ + 1]
    /\ UNCHANGED <<called, answer, got, pos, nexts, retPos, waiting, ans, outers, inner,
                   failed, pending, closer, closeKind, closeInner, closes, innerCloses,
                   accepting, completed, alive>>

\* The inner iterator answers the read of the job j. A job that is not in
\* `jobs` has no effect.
AnswerInner(j, o) ==
    /\ j \in Started /\ kind[j] = "inner" /\ ans[j] = "none"
    /\ o \in {"value", "done", "error"}
    /\ ans' = [ans EXCEPT ![j] = o]
    /\ IF j \notin Range(jobs)
       THEN UNCHANGED <<answer, waiting, jobs, st, inner, failed, pending, accepting, completed>>
       ELSE LET p == Position(jobs, j) IN
            CASE o = "value" ->
                   /\ st' = [st EXCEPT ![j] = "value"]
                   /\ UNCHANGED <<answer, waiting, jobs, inner, failed, pending, accepting,
                                  completed>>
              [] o = "done" ->
                   /\ jobs' = IF Bug = "no_discard"
                              THEN SubSeq(jobs, 1, p - 1) \o SubSeq(jobs, p + 1, Len(jobs))
                              ELSE SubSeq(jobs, 1, p - 1)
                                   \o SelectSeq(SubSeq(jobs, p, Len(jobs)),
                                                LAMBDA x : gen[x] # gen[j] \/ kind[x] # "inner")
                   /\ IF inner = gen[j]
                      THEN inner' = 0 /\ failed' = FALSE
                      ELSE UNCHANGED <<inner, failed>>
                   /\ UNCHANGED <<answer, waiting, st, pending, accepting, completed>>
              [] o = "error" ->
                   IF PendingBefore(p) /\ Bug # "error_at_once"
                   THEN /\ st' = [st EXCEPT ![j] = "deferred"]
                        /\ IF inner = gen[j] /\ Bug = "read_on_error"
                           THEN inner' = 0 /\ UNCHANGED failed
                           ELSE IF inner = gen[j] /\ Bug # "pull_after_error"
                           THEN failed' = TRUE /\ UNCHANGED inner
                           ELSE UNCHANGED <<inner, failed>>
                        /\ UNCHANGED <<answer, waiting, jobs, pending, accepting, completed>>
                   ELSE EndWithError(p)
    /\ UNCHANGED <<called, got, pos, nexts, retPos, kind, gen, idx, njobs, outers, pulls,
                   closer, closeKind, closeInner, closes, innerCloses, alive>>

\* The source and the mapper answer the outer job j: an inner iterator, the
\* end of the source, or an error of the mapper.
AnswerOuter(j, o) ==
    /\ j \in Started /\ kind[j] = "outer" /\ ans[j] = "none"
    /\ o \in {"inner", "end", "error"}
    /\ o = "inner" => gen[j] <= Inners
    /\ ans' = [ans EXCEPT ![j] = o]
    /\ IF j \notin Range(jobs)
       THEN UNCHANGED <<answer, waiting, jobs, st, inner, failed, pending, accepting, completed>>
       ELSE LET p == Position(jobs, j) IN
            CASE o = "inner" ->
                   /\ jobs' = SubSeq(jobs, 1, p - 1) \o SubSeq(jobs, p + 1, Len(jobs))
                   /\ inner' = gen[j]
                   /\ failed' = FALSE
                   /\ UNCHANGED <<answer, waiting, st, pending, accepting, completed>>
              [] o = "end" ->
                   /\ Complete(p)
                   /\ jobs' = SubSeq(jobs, 1, p - 1)
                   /\ UNCHANGED st
              [] o = "error" -> EndWithError(p)
    /\ UNCHANGED <<called, got, pos, nexts, retPos, kind, gen, idx, njobs, outers, pulls,
                   closer, closeKind, closeInner, closes, innerCloses, alive>>

\* A deferred error stays when the reads before it of its inner iterator
\* gave values.
Finalize ==
    /\ \E p \in 1..Len(jobs) :
         /\ st[jobs[p]] = "deferred"
         /\ \A i \in 1..(p - 1) : st[jobs[i]] # "deferred"
         /\ ~PendingBefore(p)
         /\ EndWithError(p)
    /\ UNCHANGED <<called, got, pos, nexts, retPos, kind, gen, idx, ans, njobs, outers, pulls,
                   closer, closeKind, closeInner, closes, innerCloses, alive>>

\* After the end, an entry with no job gets done.
EndUnmatched ==
    /\ completed
    /\ Len(waiting) > Len(jobs)
    /\ answer' = [c \in Calls |->
                    IF c \in Range(SubSeq(waiting, Len(jobs) + 1, Len(waiting)))
                    THEN "done" ELSE answer[c]]
    /\ waiting' = SubSeq(waiting, 1, Len(jobs))
    /\ UNCHANGED <<called, got, pos, nexts, retPos, jobVars, ans, inner, failed, pending, closer,
                   closeKind, closeInner, closes, innerCloses, accepting, completed, alive>>

\* The first entry gets the result of the first job: a value, or, for an
\* error, the close of the source first.
Deliver ==
    /\ closer = "none"
    /\ jobs # <<>> /\ waiting # <<>>
    /\ st[Head(jobs)] \in {"value", "error"}
    /\ LET c == Head(waiting)
           j == Head(jobs)
       IN /\ waiting' = Tail(waiting)
          /\ jobs' = Tail(jobs)
          /\ IF st[j] = "value"
             THEN /\ answer' = [answer EXCEPT ![c] = "value"]
                  /\ got' = [got EXCEPT ![c] = <<gen[j], idx[j]>>]
                  /\ UNCHANGED <<closer, closeKind, closeInner, closes>>
             ELSE /\ closer' = c
                  /\ closeKind' = "reject"
                  /\ closeInner' = inner
                  /\ closes' = closes + 1
                  /\ UNCHANGED <<answer, got>>
    /\ UNCHANGED <<called, pos, nexts, retPos, st, kind, gen, idx, ans, njobs, outers, pulls,
                   inner, failed, pending, innerCloses, accepting, completed, alive>>

\* A return() that waits closes the open inner iterator and the source when
\* the calls before it have their results.
StartClose ==
    /\ pending # "none"
    /\ closer = "none"
    /\ waiting = <<>>
    /\ closer' = pending
    /\ closeKind' = "return"
    /\ closeInner' = IF Bug = "close_source_only" THEN 0 ELSE inner
    /\ closes' = closes + 1
    /\ innerCloses' = innerCloses + (IF closeInner' > 0 THEN 1 ELSE 0)
    /\ pending' = "none"
    /\ UNCHANGED <<called, answer, got, pos, nexts, retPos, waiting, jobVars, ans, inner, failed,
                   accepting, completed, alive>>

\* The close ends. The call that waits gets its result: the error, or the
\* result of return().
CloseEnd(o) ==
    /\ closer # "none"
    /\ o \in {"ok", "fail"}
    /\ answer' = [answer EXCEPT ![closer] =
                    IF closeKind = "return" /\ o = "ok" THEN "done" ELSE "error"]
    /\ closer' = "none"
    /\ closeKind' = "none"
    /\ closeInner' = 0
    /\ UNCHANGED <<called, got, pos, nexts, retPos, waiting, jobVars, ans, inner, failed,
                   pending, closes, innerCloses, accepting, completed, alive>>

CloseEnds == \E o \in {"ok", "fail"} : CloseEnd(o)

\* The process stops when it is done and no job runs.
Stop ==
    /\ alive
    /\ ~accepting
    /\ waiting = <<>>
    /\ pending = "none"
    /\ closer = "none"
    /\ \A j \in Started : ans[j] # "none"
    /\ alive' = FALSE
    /\ UNCHANGED <<called, answer, got, pos, nexts, retPos, waiting, jobVars, ans, inner, failed,
                   pending, closer, closeKind, closeInner, closes, innerCloses, accepting,
                   completed>>

InnerAnswers(j) == \E o \in {"value", "done", "error"} : AnswerInner(j, o)

OuterAnswers(j) == \E o \in {"inner", "end", "error"} : AnswerOuter(j, o)

Next ==
    \/ \E c \in Calls : CallNext(c) \/ CallReturn(c)
    \/ \E j \in JobIds : InnerAnswers(j) \/ OuterAnswers(j)
    \/ StartOuter \/ StartPull \/ Finalize \/ EndUnmatched \/ Deliver \/ StartClose \/ Stop
    \/ CloseEnds
    \/ UNCHANGED vars

Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(StartOuter) /\ WF_vars(StartPull) /\ WF_vars(Finalize)
    /\ WF_vars(EndUnmatched) /\ WF_vars(Deliver) /\ WF_vars(StartClose) /\ WF_vars(Stop)
    /\ WF_vars(CloseEnds)
    /\ \A j \in JobIds : WF_vars(InnerAnswers(j)) /\ WF_vars(OuterAnswers(j))

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ called \in [Calls -> {"none", "next", "return"}]
    /\ answer \in [Calls -> {"none", "value", "done", "error"}]
    /\ st \in [JobIds -> {"none", "running", "value", "error", "deferred"}]
    /\ kind \in [JobIds -> {"none", "outer", "inner"}]
    /\ ans \in [JobIds -> {"none", "value", "done", "error", "inner", "end"}]
    /\ inner \in 0..Inners
    /\ pending \in Calls \cup {"none"}
    /\ closer \in Calls \cup {"none"}
    /\ closeKind \in {"none", "reject", "return"}
    /\ failed \in BOOLEAN /\ accepting \in BOOLEAN /\ completed \in BOOLEAN /\ alive \in BOOLEAN

NextCall(c) == called[c] = "next"

\* A call of next() before the first return().
Counted(c) == NextCall(c) /\ (retPos = -1 \/ pos[c] <= retPos)

\* Each call gets the result of a sequential run on the same answers. A
\* call can get done before the answers of the reads before it ("unknown"):
\* the property examines it when they come. A result that needs a read that
\* did not start ("missing") is not the result of a sequential run.
RaceFree ==
    \A c \in Calls :
        (Counted(c) /\ answer[c] # "none")
            => LET s == SeqRun(0, 1, pos[c])
               IN s[1] # "unknown"
                     => /\ s[1] = answer[c]
                        /\ answer[c] = "value" => got[c] = <<s[2], s[3]>>

\* A call gets a value only after each call of next() before it has its
\* result.
InOrder ==
    \A c, d \in Calls :
        (NextCall(c) /\ NextCall(d) /\ pos[d] < pos[c] /\ answer[c] = "value")
            => answer[d] # "none"

\* The reads of an open inner iterator run at the same time: an entry with
\* no job can get a read at once.
Eager ==
    (alive /\ ~completed /\ Unstarted > 0 /\ ~OuterRunning /\ inner # 0 /\ ~failed
     /\ njobs < MaxJobs)
        => ENABLED StartPull

\* The source is read again only after an end of the inner iterator before.
SourceLazy ==
    \A j \in Started :
        (kind[j] = "outer" /\ gen[j] > 1)
            => \E p \in Started : kind[p] = "inner" /\ gen[p] = gen[j] - 1 /\ ans[p] = "done"

\* return() closes the inner iterator of the last value, and the source.
LastGen ==
    IF \E c \in Calls : NextCall(c) /\ pos[c] = retPos /\ answer[c] = "value"
    THEN got[CHOOSE c \in Calls : NextCall(c) /\ pos[c] = retPos /\ answer[c] = "value"][1]
    ELSE 0

CloseRight == closeKind = "return" => closeInner = LastGen

\* The helper closes its source one time only.
CloseOnce == closes <= 1

\* No read of an inner iterator with a deferred error starts.
Failed(g) == \E j \in Range(jobs) : kind[j] = "inner" /\ gen[j] = g /\ st[j] = "deferred"

NoReadAfterError == [][\A g \in 1..Inners : Failed(g) => pulls'[g] = pulls[g]]_vars

\* No read starts after the end of the iteration.
NoReadAfterEnd == [][completed => njobs' = njobs]_vars

\* Each call gets its result.
AllAnswered == \A c \in Calls : called[c] # "none" ~> answer[c] # "none"

\* A helper that is done stops.
Stops == ~accepting ~> ~alive
=============================================================================
