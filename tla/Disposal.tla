------------------------------- MODULE Disposal -------------------------------
(* The disposal of the resources of Web.using.                               *)
(*                                                                           *)
(* The blocks of `using` are one in a different one. Level 1 is the outer    *)
(* block. Each block has one value: a resource, the value nil, or a value    *)
(* that is not disposable. The inner block ends, then each block releases    *)
(* its resource, from the inner block to the outer block.                    *)
(*                                                                           *)
(* The module shows the rules of ECMAScript: each resource is released one   *)
(* time, in the opposite sequence, and no error is lost.                     *)
(*                                                                           *)
(* The constant Bug is "none" for the design. Each other value removes one   *)
(* rule of the design.                                                       *)
EXTENDS Naturals, Sequences

CONSTANTS
    Depth,  \* the largest number of blocks
    Bug     \* "none", or the name of a rule to remove

\* The values that a block can have.
Kinds == {"resource", "nil", "other"}

VARIABLES
    phase,     \* "enter" while blocks start, "exit" while they end, "done"
    level,     \* the number of blocks that started
    kind,      \* kind[i] is the value of block i, or "nil"
    live,      \* the blocks whose resource is not released
    released,  \* the blocks that released their resource, in sequence
    error,     \* "none", or the error that the code after the blocks gets
    depth,     \* the number of SuppressedError in that error
    failures   \* the number of errors that occurred

vars == <<phase, level, kind, live, released, error, depth, failures>>

Init ==
    /\ phase = "enter"
    /\ level = 0
    /\ kind = [i \in 1..Depth |-> "nil"]
    /\ live = {}
    /\ released = <<>>
    /\ error = "none"
    /\ depth = 0
    /\ failures = 0

\* A block starts with a value. A value that is not disposable, and not nil,
\* gives a TypeError: the block does not start, and the blocks around it end.
Declare(k) ==
    /\ phase = "enter" /\ level < Depth /\ k \in Kinds
    /\ IF k = "other" /\ Bug # "value_is_not_examined"
       THEN /\ phase' = "exit"
            /\ error' = "type"
            /\ failures' = failures + 1
            /\ UNCHANGED <<level, kind, live>>
       ELSE /\ level' = level + 1
            /\ kind' = [kind EXCEPT ![level + 1] = k]
            /\ live' = IF k = "resource" THEN live \cup {level + 1} ELSE live
            /\ UNCHANGED <<phase, error, failures>>
    /\ UNCHANGED <<released, depth>>

\* The code of the inner block ends. It fails or it does not.
EndBlock(ok) ==
    /\ phase = "enter" /\ ok \in BOOLEAN
    /\ phase' = IF ~ok /\ Bug = "no_disposal_after_error" THEN "done" ELSE "exit"
    /\ error' = IF ok THEN error ELSE "block"
    /\ failures' = IF ok THEN failures ELSE failures + 1
    /\ UNCHANGED <<level, kind, live, released, depth>>

\* The inner block that did not end releases its resource, and ends. The
\* disposal fails or it does not. The error of a disposal that fails goes
\* around the error that is there, in a SuppressedError.
Release(ok) ==
    /\ phase = "exit" /\ level > 0 /\ ok \in BOOLEAN
    /\ level' = level - 1
    /\ IF kind[level] = "resource"
       THEN /\ live' = live \ {level}
            /\ released' = Append(released, level)
            /\ IF ok
               THEN UNCHANGED <<error, depth, failures>>
               ELSE /\ failures' = failures + 1
                    /\ error' = IF error = "none" \/ Bug = "disposal_error_replaces"
                                THEN "disposal" ELSE "suppressed"
                    /\ depth' = IF error = "none" \/ Bug = "disposal_error_replaces"
                                THEN depth ELSE depth + 1
       ELSE UNCHANGED <<live, released, error, depth, failures>>
    /\ UNCHANGED <<phase, kind>>

\* All the blocks ended.
Finish ==
    /\ phase = "exit" /\ level = 0
    /\ phase' = "done"
    /\ UNCHANGED <<level, kind, live, released, error, depth, failures>>

Next ==
    \/ \E k \in Kinds : Declare(k)
    \/ \E ok \in BOOLEAN : EndBlock(ok) \/ Release(ok)
    \/ Finish
    \/ (phase = "done" /\ UNCHANGED vars)

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ phase \in {"enter", "exit", "done"}
    /\ level \in 0..Depth
    /\ kind \in [1..Depth -> Kinds]
    /\ live \subseteq 1..Depth
    /\ error \in {"none", "type", "block", "disposal", "suppressed"}
    /\ depth \in 0..Depth
    /\ failures \in 0..(Depth + 1)

\* A block starts only with a resource or with nil.
BlockHasDisposableValue == \A i \in 1..level : kind[i] # "other"

\* After the blocks, no resource is left.
AllReleased == phase = "done" => live = {}

\* Each block releases its resource one time, and the inner block is first.
OppositeSequence ==
    \A i \in 1..Len(released) : \A j \in 1..Len(released) :
        i < j => released[i] > released[j]

\* Only a resource is released.
OnlyResources == \A i \in 1..Len(released) : kind[released[i]] = "resource"

\* No error is lost: the code after the blocks gets one error that has each
\* error that occurred.
NoErrorIsLost ==
    /\ (error = "none") = (failures = 0)
    /\ failures > 0 => depth = failures - 1

\* The blocks end.
Ends == <>(phase = "done")
=============================================================================
