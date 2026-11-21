---------------------------- MODULE FormDataParser ----------------------------
(* The live parser of a multipart body of Web.FormData: Web.FormData.parse  *)
(* and formData() of a body with the type multipart/form-data.              *)
(*                                                                          *)
(* The parser is a process. It holds the reader lock of the source, and it  *)
(* reads the body only when a call needs more of it. The body has a file    *)
(* part and then a field. The parse found the headers of the file part      *)
(* before it gave the form: the file has its stream. The reader of the      *)
(* file stream pulls each piece from the parser, or it cancels the stream.  *)
(* A pull and a cancel are calls: the parser takes them when it has no      *)
(* other work.                                                              *)
(*                                                                          *)
(* The callers are a get of the field, an iteration with next_entry, and a  *)
(* freeze into a static form (an append, a set, a delete, or Collectable).  *)
(* A query that needs the field waits while the file part has bytes that    *)
(* its reader did not take: the parser does not read the next part before   *)
(* the file part is read or discarded. The iteration and the freeze discard *)
(* a file part that they go past. After each query, each pull, and each     *)
(* cancel of the file stream, the parser answers each call that waits and   *)
(* whose answer it has.                                                     *)
(*                                                                          *)
(* The parser stops for a cancel, an abort of its signal, a stop of its     *)
(* owner, an error of the source, a kill, and a freeze. The source can      *)
(* stall: it gives no more pieces. The parser then waits for the source,    *)
(* and it takes only a cancel, an abort, and the stop of its owner.         *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design.                                                      *)
EXTENDS Naturals, Sequences

CONSTANTS
    FileSize,  \* the number of pieces of the bytes of the file part
    Callers,   \* the callers: a subset of {"get", "iter", "freeze"}
    Bug        \* "none", or the name of a rule to remove

\* The parts of the body. Part N + 1 is the close delimiter.
Parts == <<"file", "field">>
N == Len(Parts)

\* The states of a caller. "asked": the call is in the mailbox of the
\* parser. "pending": the parser keeps the call until it has the answer.
\* "value": the answer. "error": the operation failed (a raise or an exit
\* with the reason of the failure). "gone": a TypeError for a parser that
\* stopped before it took the call. "crash": an exit of OTP that is not an
\* answer of the library. "ended": the iteration got the end.
CallStates == {"idle", "asked", "pending", "value", "error", "gone", "crash", "ended"}

\* The requests that stop the parser: a cancel and an abort of the signal are
\* messages, the stop of the owner is the exit of the parent, and a kill
\* stops the parser at once with no terminate.
StopRequests == {"none", "cancel", "abort", "owner", "kill"}

VARIABLES
    part,      \* the part that the parser reads
    off,       \* the pieces of that part that the parser read
    src,       \* "open", "stalled" (it gives no more pieces), or "errored"
    ps,        \* the parser: "run" or "stopped"
    work,      \* the work of the parser in a call: "none", "query" (it reads
               \* for the calls that wait), or "pull" (it reads a piece for
               \* the file stream)
    fs,        \* the file stream: "readable", "closed", "errored", or
               \* "canceled" (its reader cancelled it)
    fgot,      \* the pieces that the file stream got
    discard,   \* TRUE when the parser discards the bytes of the file part
    cs,        \* cs[c] is the state of caller c
    nxt,       \* the index of the entry that the iteration asks for
    seen,      \* the indexes of the entries that the iteration got
    stopReq,   \* the request that stops the parser, or "none"
    freezing,  \* TRUE after a freeze asked for all the entries
    failure,   \* TRUE after a stop that is not a freeze
    served     \* the calls that the work of the parser answers: "all", or
               \* one caller with Bug = "serve_only_caller"

posVars == <<part, off>>
fileVars == <<fs, fgot, discard>>
callVars == <<cs, nxt, seen>>
vars == <<part, off, src, ps, work, fs, fgot, discard, cs, nxt, seen, stopReq,
          freezing, failure, served>>

\* The parse is complete: the parser read the close delimiter.
Done == part = N + 1 /\ off = 1

\* The number of entries that the parser found.
Found == IF part > N THEN N ELSE IF off > 0 THEN part ELSE part - 1

\* The parser is in the bytes of the file part.
InFile == part <= N /\ Parts[part] = "file" /\ off >= 1

\* A query cannot go past a file part whose bytes its reader must take.
Blocked == InFile /\ ~discard /\ Bug # "no_discard"

\* The parser has the answer of the call of c.
Known(c) ==
    IF c = "get" THEN Found >= N
    ELSE IF c = "iter" THEN nxt <= Found \/ Done
    ELSE Done

Pending == {c \in Callers : cs[c] = "pending"}

\* The calls that wait and that the work of the parser answers.
Served == {c \in Pending : served \in {"all", c}}

\* The parser needs the next piece of the body for its work.
Wants ==
    \/ work = "pull"
    \/ work = "query" /\ ~Blocked /\ ~Done /\ \E c \in Served : ~Known(c)

\* The parser waits for the source in a call.
ReadWait == ps = "run" /\ Wants /\ src = "stalled"

\* The parser takes a stop request when it has no work, or when it waits
\* for the source.
CanTakeStop == work = "none" \/ (ReadWait /\ Bug # "blocking_read")

\* The state of the file stream after the parser ends it: an error, thus a
\* reader does not see a short file as complete.
Ended == IF fs = "readable" THEN IF Bug = "cancel_child" THEN "closed" ELSE "errored" ELSE fs

Init ==
    /\ part = 1 /\ off = 1
    /\ src = "open"
    /\ ps = "run" /\ work = "none"
    /\ fs = "readable" /\ fgot = 0 /\ discard = FALSE
    /\ cs = [c \in Callers |-> "idle"] /\ nxt = 1 /\ seen = <<>>
    /\ stopReq = "none" /\ freezing = FALSE /\ failure = FALSE /\ served = "all"

-----------------------------------------------------------------------------
\* The source, the signal, and the owner

\* The source gives each piece when the parser reads, until it stalls or
\* has an error.
Stall ==
    /\ src = "open"
    /\ src' = "stalled"
    /\ UNCHANGED <<posVars, ps, work, fileVars, callVars, stopReq, freezing, failure, served>>

SourceError ==
    /\ src = "open"
    /\ src' = "errored"
    /\ UNCHANGED <<posVars, ps, work, fileVars, callVars, stopReq, freezing, failure, served>>

\* A cancel of the form, an abort of the signal, or the stop of the owner.
Request(r) ==
    /\ stopReq = "none" /\ r \in {"cancel", "abort", "owner"}
    /\ stopReq' = r
    /\ UNCHANGED <<posVars, src, ps, work, fileVars, callVars, freezing, failure, served>>

\* The steps of a stop for reason r: the abort of the parser and its
\* terminate. Each call that waits gets the error. The file stream gets an
\* error. A kill has no terminate: it keeps the file stream, and a call in
\* flight gets a TypeError.
StopFor(r) ==
    /\ ps' = "stopped" /\ work' = "none" /\ failure' = TRUE
    /\ cs' = [c \in Callers |->
                IF cs[c] = "pending" /\ Bug = "lost_pending" THEN "pending"
                ELSE IF cs[c] \in {"asked", "pending"}
                     THEN IF r = "owner" /\ Bug = "shutdown_exit" THEN "crash" ELSE "error"
                ELSE cs[c]]
    /\ fs' = IF r = "kill" \/ (r = "owner" /\ Bug = "kill_on_owner_down") THEN fs ELSE Ended
    /\ UNCHANGED <<posVars, src, fgot, discard, nxt, seen, freezing, served>>

Kill ==
    /\ ps = "run" /\ stopReq = "none"
    /\ stopReq' = "kill"
    /\ StopFor("kill")

-----------------------------------------------------------------------------
\* The callers and the reader of the file stream

\* Caller c sends its call. A parser that stopped gives a TypeError.
Ask(c) ==
    /\ cs[c] = "idle"
    /\ cs' = [cs EXCEPT ![c] =
                IF ps = "run" THEN "asked"
                ELSE IF Bug = "noproc_exit" THEN "crash"
                ELSE "gone"]
    /\ UNCHANGED <<posVars, src, ps, work, fileVars, nxt, seen, stopReq, freezing, failure,
                   served>>

\* The reader of the file stream pulls a piece. The parser takes the pull,
\* and reads a piece for the stream. A pull of a part that the parser
\* discards has no effect. When the parser stopped, the pull gives the
\* stream an error: the parser cannot give the rest of the file.
Pull ==
    /\ fs = "readable"
    /\ IF ps = "run"
          THEN /\ work = "none"
               /\ work' = IF InFile /\ ~discard THEN "pull" ELSE "none"
               /\ served' = "all"
               /\ UNCHANGED fs
          ELSE /\ fs' = IF Bug = "close_on_lost_parser" THEN "closed" ELSE "errored"
               /\ UNCHANGED <<work, served>>
    /\ UNCHANGED <<posVars, src, ps, fgot, discard, callVars, stopReq, freezing, failure>>

\* The reader cancels the file stream. The parser takes the cancel: it
\* discards the rest of the file part, and the calls that wait continue.
CancelFile ==
    /\ fs = "readable"
    /\ fs' = "canceled"
    /\ IF ps = "run"
          THEN /\ work = "none"
               /\ discard' = (discard \/ InFile)
               /\ work' = IF Pending # {} THEN "query" ELSE "none"
               /\ served' = "all"
          ELSE UNCHANGED <<discard, work, served>>
    /\ UNCHANGED <<posVars, src, ps, fgot, callVars, stopReq, freezing, failure>>

-----------------------------------------------------------------------------
\* The parser

\* The parser takes a stop request.
TakeStop ==
    /\ ps = "run" /\ stopReq \in {"cancel", "abort", "owner"} /\ CanTakeStop
    /\ StopFor(stopReq)
    /\ UNCHANGED stopReq

\* The parser takes a query. The iteration discards a file part before the
\* entry that it asks for, and the freeze discards the file part. Then the
\* parser keeps the call until it has the answer.
TakeQuery(c) ==
    /\ ps = "run" /\ work = "none" /\ cs[c] = "asked"
    /\ LET d == InFile /\ ~discard /\ (c = "freeze" \/ (c = "iter" /\ part < nxt))
       IN /\ discard' = (discard \/ d)
          /\ fs' = IF d THEN Ended ELSE fs
          /\ nxt' = IF d /\ Bug = "discard_skips_entry" THEN nxt + 1 ELSE nxt
    /\ freezing' = (freezing \/ c = "freeze")
    /\ cs' = [cs EXCEPT ![c] = "pending"]
    /\ work' = "query"
    \* The design answers each call that waits after a query. The bug
    \* answers only the caller: a call that waits gets its answer only at a
    \* pull or a cancel of the file stream.
    /\ served' = IF Bug = "serve_only_caller" THEN c ELSE "all"
    /\ UNCHANGED <<posVars, src, ps, fgot, seen, stopReq, failure>>

\* The parser reads the next piece of the body. A piece of the file part
\* goes to the file stream, or the parser drops it.
Read ==
    /\ ps = "run" /\ Wants /\ src = "open"
    /\ IF InFile
          THEN /\ IF discard \/ work = "query"
                     THEN UNCHANGED <<fgot, fs>>
                     ELSE /\ fgot' = fgot + 1
                          /\ fs' = IF off = FileSize THEN "closed" ELSE fs
               \* A query goes past a file part only with Bug = "no_discard".
               /\ IF off = FileSize \/ (work = "query" /\ ~discard)
                     THEN part' = part + 1 /\ off' = 0
                     ELSE off' = off + 1 /\ UNCHANGED part
               \* The end of the file part lets the calls that wait continue.
               /\ work' = IF work = "query" \/ (off = FileSize /\ Pending # {})
                             THEN "query" ELSE "none"
          ELSE /\ IF part <= N
                     THEN part' = part + 1 /\ off' = 0
                     ELSE off' = 1 /\ UNCHANGED part
               /\ UNCHANGED <<fgot, fs, work>>
    /\ UNCHANGED <<src, ps, discard, callVars, stopReq, freezing, failure, served>>

\* The source has an error: the read of the parser fails.
ReadError ==
    /\ ps = "run" /\ Wants /\ src = "errored"
    /\ StopFor("error")
    /\ UNCHANGED stopReq

\* The answer of a query that waits: the value, the next entry of the
\* iteration, or the end of the iteration.
AnswerOf(c) ==
    IF c = "iter" THEN IF nxt <= Found THEN "idle" ELSE "ended" ELSE "value"

\* The iteration gets its entry when its answer is not the end.
IterGets(c) == c = "iter" /\ nxt <= Found

\* The parser gives its answer to a call that waits. The freeze stops the
\* parser: each other call that waits gets its answer, and a call in the
\* mailbox gets a TypeError.
Answer(c) ==
    /\ ps = "run" /\ work = "query" /\ c \in Served /\ Known(c)
    /\ IF c = "freeze"
          THEN /\ ps' = "stopped" /\ work' = "none"
               /\ cs' = [o \in Callers |->
                           IF o = "freeze" THEN "value"
                           ELSE IF cs[o] = "pending"
                                THEN IF Bug = "freeze_drops_pending" THEN "error" ELSE AnswerOf(o)
                           ELSE IF cs[o] = "asked" THEN "gone"
                           ELSE cs[o]]
               /\ IF "iter" \in Pending /\ IterGets("iter") /\ Bug # "freeze_drops_pending"
                     THEN seen' = Append(seen, nxt) /\ nxt' = nxt + 1
                     ELSE UNCHANGED <<seen, nxt>>
          ELSE /\ cs' = [cs EXCEPT ![c] = AnswerOf(c)]
               /\ IF IterGets(c)
                     THEN seen' = Append(seen, nxt) /\ nxt' = nxt + 1
                     ELSE UNCHANGED <<seen, nxt>>
               /\ UNCHANGED <<ps, work>>
    /\ UNCHANGED <<posVars, src, fileVars, stopReq, freezing, failure, served>>

\* The parser has no answer that it can give, and it cannot read for the
\* calls that wait: it waits for a message.
Rest ==
    /\ ps = "run" /\ work = "query" /\ ~Wants
    /\ ~(\E c \in Served : Known(c))
    /\ work' = "none"
    /\ UNCHANGED <<posVars, src, ps, fileVars, callVars, stopReq, freezing, failure, served>>

Next ==
    \/ Stall \/ SourceError \/ Kill
    \/ \E r \in StopRequests : Request(r)
    \/ \E c \in Callers : Ask(c) \/ TakeQuery(c) \/ Answer(c)
    \/ Pull \/ CancelFile
    \/ TakeStop \/ Read \/ ReadError \/ Rest
    \* The parser stopped, and no process has a step: the system rests.
    \/ (ps = "stopped" /\ UNCHANGED vars)

\* The reader of the file stream reads to the end, and the parser does each
\* step that it can do.
Fairness ==
    /\ WF_vars(Pull)
    /\ WF_vars(TakeStop)
    /\ WF_vars(Read)
    /\ WF_vars(ReadError)
    /\ WF_vars(Rest)
    /\ \A c \in Callers : WF_vars(TakeQuery(c)) /\ WF_vars(Answer(c))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ part \in 1..N + 1 /\ off \in 0..FileSize
    /\ src \in {"open", "stalled", "errored"}
    /\ ps \in {"run", "stopped"} /\ work \in {"none", "query", "pull"}
    /\ fs \in {"readable", "closed", "errored", "canceled"}
    /\ fgot \in 0..FileSize /\ discard \in BOOLEAN
    /\ cs \in [Callers -> CallStates]
    /\ nxt \in 1..N + 2 /\ seen \in Seq(1..N)
    /\ stopReq \in StopRequests
    /\ freezing \in BOOLEAN /\ failure \in BOOLEAN
    /\ served \in {"all"} \cup Callers

\* The iteration gets the entries in the sequence of the body, and each
\* entry before its end.
EntriesInOrder ==
    /\ \A k \in 1..Len(seen) : seen[k] = k
    /\ ("iter" \in Callers /\ cs["iter"] = "ended") => Len(seen) = N

\* The parser reads the next part only after the file part is read or
\* discarded.
FileBeforeNext == part > 1 => (fgot = FileSize \/ discard)

\* A file stream that closes has each byte of its part. A stream that does
\* not get each byte gets an error, or its reader cancelled it.
FileIntegrity == fs = "closed" => fgot = FileSize

\* Each call gets an answer of the library: no caller gets an exit of OTP.
NoCrash == \A c \in Callers : cs[c] # "crash"

\* A call gets an error only from a parse that failed.
NoWrongError == \A c \in Callers : cs[c] = "error" => failure

\* A stop of the parser with its terminate ends the file stream: a reader
\* does not wait for bytes that no process will give.
StreamEndsWithParser == (ps = "stopped" /\ stopReq # "kill") => fs # "readable"

\* Each call gets an answer. Only a source that stalls keeps a query.
NoLostReply ==
    \A c \in Callers :
        cs[c] \in {"asked", "pending"} ~> (cs[c] \notin {"asked", "pending"} \/ src = "stalled")

\* A cancel, an abort, and the stop of the owner stop the parser, also when
\* the source stalls.
PromptStop == stopReq # "none" ~> ps = "stopped"

\* A parser that stopped does not start again.
StaysStopped == [][ps = "stopped" => ps' = "stopped"]_vars
=============================================================================
