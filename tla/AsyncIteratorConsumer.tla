------------------------ MODULE AsyncIteratorConsumer ------------------------
(* The process of a method of Web.AsyncIterator that consumes an iterator:  *)
(* see Web.Internal.AsyncIteratorConsumer. The module shows `find`, with a  *)
(* concurrency argument of Capacity permits.                                *)
(*                                                                          *)
(* The process starts a job for each permit. A job reads one value of the   *)
(* source and runs the predicate. Its permit goes back when the process     *)
(* takes its result, and a new read starts only after the decisions that    *)
(* the result permits. A read that gives the end or an error stops the      *)
(* reads.                                                                   *)
(* The process decides on the jobs in the sequence of their                 *)
(* reads: a value that the predicate selects, the end of the source, an     *)
(* error of the source, or an error of the predicate. At the decision, it   *)
(* reads no more. A selected value and an error of the predicate close the  *)
(* source, and the promise settles after the close. The process waits for   *)
(* its jobs before it stops, and it stops when its owner stops.             *)
(*                                                                          *)
(* The module shows that the result is the first selected value in the      *)
(* sequence, that with one permit the reads are the reads of the steps of   *)
(* the proposal, that the source is closed one time only, that the promise  *)
(* settles after the close, and that the process gives each permit back.    *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design. The value "release_before_failure" is a defect that  *)
(* a test found: a job that a different process killed gave its permit     *)
(* back before its failure, and a new read started before the decision.    *)
(* The value "read_after_end" is a defect that the conformance test found:  *)
(* the process read again after the end of the source, while a decision    *)
(* before the end waited.                                                   *)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Reads,      \* the reads of the model; the last read gives the end
    Capacity,   \* the permits of the concurrency argument
    Bug         \* "none", or the name of a rule to remove

Jobs == 1..Reads

VARIABLES
    phase,      \* phase[j] of a job: see Phases
    held,       \* the jobs that hold a permit
    reads,      \* the number of the reads of the source
    decide,     \* the job of the next decision
    stopping,   \* TRUE after the decision: no more reads
    closing,    \* "none", or the close that runs: "normal" or "throw"
    closes,     \* the number of the closes of the source
    result,     \* "none", "value", "nil" (the end), or "error"
    found,      \* the job of the selected value, or 0
    working,    \* TRUE while the process does its work
    ownerAlive  \* TRUE while the owner runs

vars == <<phase, held, reads, decide, stopping, closing, closes, result, found, working,
          ownerAlive>>

\* "read": the job reads. "check": the predicate runs. "yes" and "no": the
\* result of the predicate. "end" and "error": the answer of the source.
\* "throw": an error of the predicate. "killed": a job that stopped with no
\* result. "ended": a job with no work.
Phases == {"none", "read", "check", "yes", "no", "end", "error", "throw", "killed", "ended"}

Finished == {"yes", "no", "end", "error", "throw"}

Init ==
    /\ phase = [j \in Jobs |-> "none"]
    /\ held = {}
    /\ reads = 0
    /\ decide = 1
    /\ stopping = FALSE
    /\ closing = "none"
    /\ closes = 0
    /\ result = "none"
    /\ found = 0
    /\ working = TRUE
    /\ ownerAlive = TRUE

Running(j) == phase[j] \in {"read", "check"}

InUse == Cardinality(held)

-----------------------------------------------------------------------------
\* The source, the predicate, and the close

\* The source answers the read of the job j. The last read of the model
\* gives the end.
Answer(j, o) ==
    /\ phase[j] = "read"
    /\ o \in IF j = Reads THEN {"end"} ELSE {"value", "end", "error"}
    /\ phase' = [phase EXCEPT ![j] = IF o = "value" THEN "check" ELSE o]
    /\ UNCHANGED <<held, reads, decide, stopping, closing, closes, result, found, working,
                   ownerAlive>>

SourceAnswers(j) == \E o \in {"value", "end", "error"} : Answer(j, o)

\* The predicate of the job j ends.
Check(j, o) ==
    /\ phase[j] = "check"
    /\ o \in {"yes", "no", "throw"}
    /\ phase' = [phase EXCEPT ![j] = o]
    /\ UNCHANGED <<held, reads, decide, stopping, closing, closes, result, found, working,
                   ownerAlive>>

PredicateEnds(j) == \E o \in {"yes", "no", "throw"} : Check(j, o)

\* A different process kills the job of a predicate. The job fails with no
\* result, before its permit goes back. With the defect, the permit goes
\* back at once.
Kill(j) ==
    /\ phase[j] = "check"
    /\ IF Bug = "release_before_failure"
       THEN /\ phase' = [phase EXCEPT ![j] = "killed"]
            /\ held' = held \ {j}
       ELSE /\ phase' = [phase EXCEPT ![j] = "throw"]
            /\ UNCHANGED held
    /\ UNCHANGED <<reads, decide, stopping, closing, closes, result, found, working,
                   ownerAlive>>

\* With the defect: the failure of a killed job comes after its permit.
RecordKill(j) ==
    /\ phase[j] = "killed"
    /\ phase' = [phase EXCEPT ![j] = "throw"]
    /\ UNCHANGED <<held, reads, decide, stopping, closing, closes, result, found, working,
                   ownerAlive>>

\* The close of the source ends. A selected value is the result, and a close
\* that fails rejects. After an error of the predicate, the error stays.
CloseEnd(o) ==
    /\ closing # "none"
    /\ o \in {"ok", "fail"}
    /\ result' = IF closing = "normal" /\ o = "ok" THEN "value" ELSE "error"
    /\ closing' = "none"
    /\ UNCHANGED <<phase, held, reads, decide, stopping, closes, found, working, ownerAlive>>

CloseEnds == \E o \in {"ok", "fail"} : CloseEnd(o)

-----------------------------------------------------------------------------
\* The steps of the process

Exhausted == \E j \in Jobs : phase[j] \in {"end", "error"}

\* A job starts with a permit, before the decision, and before a read that
\* gives the end or an error.
StartRead ==
    /\ working
    /\ ~stopping \/ Bug = "read_after_decision"
    /\ ~Exhausted \/ Bug = "read_after_end"
    /\ reads < Reads
    /\ InUse < Capacity
    /\ reads' = reads + 1
    /\ phase' = [phase EXCEPT ![reads + 1] = "read"]
    /\ held' = held \cup {reads + 1}
    /\ UNCHANGED <<decide, stopping, closing, closes, result, found, working, ownerAlive>>

\* The decision on the job `decide`, when it has its result. With the Bug
\* "unordered", each selected value is the result at once.
Decide ==
    /\ working
    /\ ~stopping
    /\ \E j \in Jobs :
         /\ j = decide \/ (Bug = "unordered" /\ phase[j] = "yes")
         /\ phase[j] \in Finished
         /\ phase[j] # "end" \/ Bug # "no_end_decision"
         /\ CASE phase[j] = "no" ->
                   /\ decide' = decide + 1
                   /\ UNCHANGED <<stopping, closing, closes, result, found>>
              [] phase[j] = "yes" ->
                   /\ stopping' = TRUE
                   /\ found' = j
                   /\ closing' = "normal"
                   /\ closes' = closes + 1
                   /\ IF Bug = "settle_before_close" THEN result' = "value" ELSE UNCHANGED result
                   /\ UNCHANGED decide
              [] phase[j] = "end" ->
                   /\ stopping' = TRUE
                   /\ result' = "nil"
                   /\ UNCHANGED <<decide, closing, closes, found>>
              [] phase[j] = "error" ->
                   /\ stopping' = TRUE
                   /\ result' = "error"
                   /\ UNCHANGED <<decide, closing, closes, found>>
              [] phase[j] = "throw" ->
                   /\ stopping' = TRUE
                   /\ closing' = "throw"
                   /\ closes' = closes + 1
                   /\ UNCHANGED <<decide, result, found>>
    /\ UNCHANGED <<phase, held, reads, working, ownerAlive>>

\* The permit of a job goes back at the end of its work, after the process
\* took its result: a result of the job `decide` first gets its decision.
Release(j) ==
    /\ j \in held
    /\ phase[j] \in Finished
    /\ j # decide \/ stopping
    /\ held' = held \ {j}
    /\ UNCHANGED <<phase, reads, decide, stopping, closing, closes, result, found, working,
                   ownerAlive>>

\* After the result, the process waits for its jobs, and then it stops its
\* work: the promise keeps the result.
Stop ==
    /\ working
    /\ result # "none"
    /\ (held = {} /\ \A j \in Jobs : phase[j] # "killed") \/ Bug = "stop_with_jobs"
    /\ working' = FALSE
    /\ UNCHANGED <<phase, held, reads, decide, stopping, closing, closes, result, found, ownerAlive>>

\* The owner stops. The process stops, and stops its jobs.
OwnerStop ==
    /\ ownerAlive
    /\ ownerAlive' = FALSE
    /\ working' = FALSE
    /\ phase' = [j \in Jobs |-> IF Running(j) \/ phase[j] = "killed" THEN "ended" ELSE phase[j]]
    /\ held' = {}
    /\ closing' = "none"
    /\ UNCHANGED <<reads, decide, stopping, closes, result, found>>

Next ==
    \/ \E j \in Jobs : SourceAnswers(j) \/ PredicateEnds(j) \/ Kill(j) \/ RecordKill(j)
    \/ \E j \in Jobs : Release(j)
    \/ CloseEnds
    \/ StartRead \/ Decide \/ Stop
    \/ OwnerStop
    \/ UNCHANGED vars

Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(StartRead) /\ WF_vars(Decide) /\ WF_vars(Stop) /\ WF_vars(CloseEnds)
    /\ \A j \in Jobs : WF_vars(SourceAnswers(j)) /\ WF_vars(PredicateEnds(j))
    /\ \A j \in Jobs : WF_vars(RecordKill(j)) /\ WF_vars(Release(j))

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ phase \in [Jobs -> Phases]
    /\ held \subseteq Jobs
    /\ reads \in 0..Reads
    /\ decide \in 1..Reads
    /\ stopping \in BOOLEAN
    /\ closing \in {"none", "normal", "throw"}
    /\ result \in {"none", "value", "nil", "error"}
    /\ found \in 0..Reads
    /\ working \in BOOLEAN /\ ownerAlive \in BOOLEAN

\* The result is the first selected value in the sequence of the reads.
FirstFound == result = "value" => \A i \in 1..(found - 1) : phase[i] = "no"

\* With one permit, a read starts only after the decision on the read
\* before it: the reads are the reads of the steps of the proposal.
SequentialReads == Capacity = 1 => reads <= decide

\* The process closes its source one time only.
CloseOnce == closes <= 1

\* The promise settles after the close.
SettleAfterClose == result # "none" => closing = "none"

\* The permits are in use only by the jobs that run, or that just ended.
Bounded == InUse <= Capacity /\ \A j \in Jobs : Running(j) => j \in held

\* A process that stopped its work has no job, and gave each permit back.
StopsWithJobs == ~working => held = {} /\ \A j \in Jobs : ~Running(j)

\* No read starts after the decision.
NoReadAfterDecision == [][stopping => reads' = reads]_vars

\* No read starts after a read that gave the end or an error.
NoReadAfterEnd == [][Exhausted => reads' = reads]_vars

\* The promise settles, unless the owner stops.
Settles == <>(result # "none" \/ ~ownerAlive)

\* After the result, the process stops its work.
Stops == result # "none" ~> ~working
=============================================================================
