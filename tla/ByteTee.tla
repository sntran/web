------------------------------- MODULE ByteTee -------------------------------
(* The tee of a byte stream: Web.Internal.ReadableByteStreamTee, the       *)
(* algorithm ReadableByteStreamTee of the Streams Standard.                *)
(*                                                                          *)
(* One process, the tee, holds the reader of the source. The two branches  *)
(* are byte streams. A read of a branch that finds no bytes in its queue    *)
(* waits, and the branch pulls: it sends a pull message to the tee. The    *)
(* tee does one read of the source at a time: a default read, or a BYOB    *)
(* read into the view of the branch, with the buffer of that view. The     *)
(* bytes of a read go to the two branches. A pull that comes during a read *)
(* sets the flag readAgainForBranch1 or readAgainForBranch2: after the     *)
(* read, the first branch with the flag that still wants bytes pulls       *)
(* again.                                                                  *)
(*                                                                          *)
(* The branches follow ReadableByteStreamControllerCallPullIfNeeded. A     *)
(* second BYOB read that waits does not pull, as                          *)
(* ReadableByteStreamControllerPullInto specifies. The bytes of a read     *)
(* make a branch that still wants bytes pull during the read, as the chunk *)
(* steps of the Standard do. The library sends that pull after the read:   *)
(* the flag gives the same result. A branch can send more pull messages at *)
(* each time (BranchPull).                                                 *)
(*                                                                          *)
(* The end: the source closes, gets an error, or is canceled (by the tee   *)
(* after the cancel of the two branches, or by the library, for example     *)
(* when its owner stops). A cancel of the source during a BYOB read of the *)
(* tee drops the buffer of that read: the tee ends the read of the branch  *)
(* with a new buffer of the same size.                                     *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one *)
(* rule of the design. Two values are defects that tests found in the real *)
(* code:                                                                   *)
(*   "lost_pull"       the tee forgets a pull that comes during a read;    *)
(*   "respond_dropped" the tee responds with 0 bytes to the request whose  *)
(*                     buffer the cancel dropped, and the response fails.  *)
(* The property test test/tla/byte_tee_property_test.exs checks the       *)
(* properties on the real code.                                            *)
EXTENDS Naturals

CONSTANTS
    Chunks,  \* the number of chunks of the source
    Bug      \* "none", or the name of a rule to remove

Branches == {1, 2}
Other(i) == IF i = 1 THEN 2 ELSE 1

VARIABLES
    chunks,  \* the chunks that the source still has
    src,     \* the source: "readable", "closed", "errored", or "canceled"
    read,    \* the read of the tee: "none", "default", or "byob"
    lender,  \* the branch whose view the BYOB read has, or 0
    reply,   \* the answer of the source to the read, on its way to the tee:
             \* "none", "chunk", "done", "dropped", or "error"
    pulls,   \* pulls[i]: the pull messages of branch i on their way to the tee
    again,   \* readAgainForBranch1 and readAgainForBranch2: a set of branches
    kind,    \* kind[i]: the reads of branch i are "default" or "byob"
    bs,      \* bs[i]: the branch is "readable", "ended" (closed or errored), or
             \* "canceled"
    want,    \* want[i]: the reads of branch i that wait, 0 to 2
    queue,   \* queue[i]: the chunks in the queue of branch i
    buffer,  \* buffer[i]: the buffer of the first BYOB read of branch i is
             \* with the "branch", lent to the "tee", or "lost"
    done     \* TRUE when the work of the tee is complete

vars == <<chunks, src, read, lender, reply, pulls, again, kind, bs, want, queue,
          buffer, done>>

Init ==
    /\ chunks = Chunks /\ src = "readable"
    /\ read = "none" /\ lender = 0 /\ reply = "none" /\ again = {}
    /\ pulls = [i \in Branches |-> 0]
    \* The two branches have the same rules: branch 1 reads with a BYOB
    \* reader, and branch 2 with a default reader.
    /\ kind = <<"byob", "default">>
    /\ bs = [i \in Branches |-> "readable"]
    /\ want = [i \in Branches |-> 0]
    /\ queue = [i \in Branches |-> 0]
    /\ buffer = [i \in Branches |-> "branch"]
    /\ done = FALSE

\* The branch wants bytes: a read waits (the high water mark is 0).
Wants(i, w, b) == w[i] > 0 /\ b[i] = "readable"

\* The read of the tee for branch i: a BYOB read with the view of the first
\* read of the branch, or a default read.
ReadOf(i) == kind[i]
LenderOf(i) == IF kind[i] = "byob" THEN i ELSE 0
LendOf(i) == IF kind[i] = "byob" THEN [buffer EXCEPT ![i] = "tee"] ELSE buffer

\* A process reads branch i. A read finds the bytes in the queue, or it
\* waits, and the branch pulls. A second read of a BYOB reader waits for the
\* first one, with no pull. A read can wait while a read waits: a branch has
\* two reads that wait at most, thus two messages have the effect of more.
Read(i) ==
    /\ bs[i] = "readable" /\ want[i] < 2
    /\ IF queue[i] > 0 /\ want[i] = 0
       THEN /\ queue' = [queue EXCEPT ![i] = @ - 1]
            /\ UNCHANGED <<want, pulls>>
       ELSE /\ want' = [want EXCEPT ![i] = @ + 1]
            /\ pulls' = IF want[i] > 0 /\ kind[i] = "byob" THEN pulls
                        ELSE [pulls EXCEPT ![i] = IF @ < 2 THEN @ + 1 ELSE @]
            /\ UNCHANGED queue
    /\ UNCHANGED <<chunks, src, read, lender, reply, again, kind, bs, buffer, done>>

\* A branch that wants bytes, and has no pull message on its way, can pull
\* again, for example after the bytes of a read. No step needs it.
BranchPull(i) ==
    /\ Wants(i, want, bs) /\ pulls[i] = 0
    /\ pulls' = [pulls EXCEPT ![i] = @ + 1]
    /\ UNCHANGED <<chunks, src, read, lender, reply, again, kind, bs, want, queue,
                   buffer, done>>

\* The tee gets a pull. During a read, it sets the flag of the branch. Else
\* it reads for a branch that still wants bytes.
TeePull(i) ==
    /\ pulls[i] > 0 /\ ~done
    /\ pulls' = [pulls EXCEPT ![i] = @ - 1]
    /\ IF read # "none"
       THEN /\ again' = IF Bug = "lost_pull" THEN again ELSE again \cup {i}
            /\ UNCHANGED <<read, lender, buffer>>
       ELSE IF Wants(i, want, bs)
            THEN /\ read' = ReadOf(i) /\ lender' = LenderOf(i) /\ buffer' = LendOf(i)
                 /\ UNCHANGED again
            ELSE UNCHANGED <<read, lender, again, buffer>>
    /\ UNCHANGED <<chunks, src, reply, kind, bs, want, queue, done>>

\* The source answers the read of the tee.
SourceAnswer ==
    /\ read # "none" /\ reply = "none"
    /\ src # "readable" \/ chunks > 0
    /\ IF src = "readable"
       THEN reply' = "chunk" /\ chunks' = chunks - 1
       ELSE /\ reply' = IF src = "errored" THEN "error" ELSE "done"
            /\ UNCHANGED chunks
    /\ UNCHANGED <<src, read, lender, pulls, again, kind, bs, want, queue, buffer, done>>

\* The bytes of a read go to each readable branch: they end its first read
\* that waits, or go to its queue. The branch of a BYOB read gets its buffer
\* back.
Give(w, q) ==
    [i \in Branches |->
        IF bs[i] # "readable" THEN <<w[i], q[i]>>
        ELSE IF w[i] > 0 THEN <<w[i] - 1, q[i]>> ELSE <<w[i], q[i] + 1>>]

\* The end of the source ends the reads of each readable branch. A dropped
\* buffer ends the read of its branch with a new buffer, unless the bug.
EndWant(i, r) ==
    IF bs[i] # "readable" THEN want[i]
    ELSE IF r = "dropped" /\ lender = i /\ Bug = "respond_dropped" THEN want[i]
    ELSE 0

\* The tee gets the answer of the source. The bytes make each branch that
\* still wants bytes pull: the read is in progress, thus the pull sets the
\* flag. Then the first branch with the flag that still wants bytes pulls
\* again.
TeeAnswer ==
    /\ reply # "none" /\ ~done
    /\ IF reply = "chunk"
       THEN LET given == Give(want, queue)
                w == [i \in Branches |-> given[i][1]]
                q == [i \in Branches |-> given[i][2]]
                b == IF lender > 0 THEN [buffer EXCEPT ![lender] = "branch"]
                     ELSE buffer
                pulled == {i \in Branches : Wants(i, w, bs)}
                flags == IF Bug = "lost_pull" THEN again ELSE again \cup pulled
                next == {i \in flags : Wants(i, w, bs)}
                first == IF 1 \in next THEN 1 ELSE 2
            IN /\ want' = w /\ queue' = q
               /\ IF next = {}
                  THEN /\ read' = "none" /\ lender' = 0 /\ again' = {} /\ buffer' = b
                  ELSE /\ read' = ReadOf(first) /\ lender' = LenderOf(first)
                       /\ again' = flags \ {first}
                       /\ buffer' = IF kind[first] = "byob"
                                    THEN [b EXCEPT ![first] = "tee"] ELSE b
               /\ UNCHANGED <<bs, done>>
       ELSE /\ want' = [i \in Branches |-> EndWant(i, reply)]
            /\ bs' = [i \in Branches |->
                        IF bs[i] = "readable" THEN "ended" ELSE bs[i]]
            /\ buffer' = IF lender = 0 THEN buffer
                         ELSE [buffer EXCEPT ![lender] =
                                 IF reply = "dropped" /\ Bug = "respond_dropped"
                                 THEN "lost" ELSE "branch"]
            /\ read' = "none" /\ lender' = 0 /\ done' = TRUE
            /\ UNCHANGED <<queue, again>>
    /\ reply' = "none"
    /\ UNCHANGED <<chunks, src, pulls, kind>>

\* The source closes after its chunks.
SourceClose ==
    /\ src = "readable" /\ chunks = 0
    /\ src' = "closed"
    /\ UNCHANGED <<chunks, read, lender, reply, pulls, again, kind, bs, want, queue,
                   buffer, done>>

\* The source gets an error.
SourceError ==
    /\ src = "readable"
    /\ src' = "errored"
    /\ UNCHANGED <<chunks, read, lender, reply, pulls, again, kind, bs, want, queue,
                   buffer, done>>

\* The tee gets the error of the source with no read: the answer to its
\* request for the end of the reader.
TeeError ==
    /\ src = "errored" /\ read = "none" /\ ~done
    /\ bs' = [i \in Branches |-> IF bs[i] = "readable" THEN "ended" ELSE bs[i]]
    /\ want' = [i \in Branches |-> IF bs[i] = "readable" THEN 0 ELSE want[i]]
    /\ done' = TRUE
    /\ UNCHANGED <<chunks, src, read, lender, reply, pulls, again, kind, queue, buffer>>

\* The library cancels the source, for example when its owner stops. A read
\* of the tee that waits ends: a BYOB read loses its buffer.
SourceCancel ==
    /\ src = "readable"
    /\ src' = "canceled" /\ chunks' = 0
    /\ reply' = IF read # "none" /\ reply = "none"
                THEN IF read = "byob" THEN "dropped" ELSE "done"
                ELSE reply
    /\ UNCHANGED <<read, lender, pulls, again, kind, bs, want, queue, buffer,
                   done>>

\* A branch is canceled: its reads end. After the cancel of the two
\* branches, the tee cancels the source, and its work is complete.
Cancel(i) ==
    /\ bs[i] = "readable"
    /\ bs' = [bs EXCEPT ![i] = "canceled"]
    /\ want' = [want EXCEPT ![i] = 0]
    /\ IF bs[Other(i)] = "canceled"
       THEN /\ src' = IF src = "readable" THEN "canceled" ELSE src
            /\ done' = TRUE
       ELSE UNCHANGED <<src, done>>
    /\ UNCHANGED <<chunks, read, lender, reply, pulls, again, kind, queue, buffer>>

Next ==
    \/ \E i \in Branches : Read(i) \/ BranchPull(i) \/ TeePull(i) \/ Cancel(i)
    \/ SourceAnswer \/ TeeAnswer \/ SourceClose \/ SourceError \/ TeeError
    \/ SourceCancel
    \/ UNCHANGED vars

\* The tee and the source do their steps. A process that uses a branch, an
\* error, and a cancel do not need to come.
Spec ==
    /\ Init /\ [][Next]_vars
    /\ \A i \in Branches : WF_vars(TeePull(i))
    /\ WF_vars(SourceAnswer) /\ WF_vars(TeeAnswer) /\ WF_vars(SourceClose)
    /\ WF_vars(TeeError)

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ chunks \in 0..Chunks
    /\ src \in {"readable", "closed", "errored", "canceled"}
    /\ read \in {"none", "default", "byob"}
    /\ lender \in 0..2 /\ (lender > 0) = (read = "byob")
    /\ reply \in {"none", "chunk", "done", "dropped", "error"}
    /\ again \subseteq Branches
    /\ \A i \in Branches :
          /\ kind[i] \in {"default", "byob"}
          /\ bs[i] \in {"readable", "ended", "canceled"}
          /\ want[i] \in 0..2 /\ pulls[i] \in 0..2 /\ queue[i] \in 0..Chunks
          /\ buffer[i] \in {"branch", "tee", "lost"}
    /\ done \in BOOLEAN

\* Only the branch of the BYOB read of the tee lends its buffer.
OneLender == \A i \in Branches : buffer[i] = "tee" => lender = i

\* A read of a branch that waits has a buffer: the cancel of the source does
\* not lose it.
NoLostBuffer == \A i \in Branches : want[i] > 0 => buffer[i] # "lost"

\* Each read of a branch ends.
ReadsEnd == \A i \in Branches : want[i] > 0 ~> want[i] = 0
=============================================================================
