---------------------------- MODULE ResponseBody ----------------------------
(* The body of a response of Web.Dispatcher.HTTP.                           *)
(*                                                                          *)
(* Three processes move the body. The worker reads the connection. The      *)
(* bridge holds one chunk at a time. The reader asks the bridge for each    *)
(* chunk. The module shows that the reader gets the full body or an error:  *)
(* a body that is not complete does not look complete.                      *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design.                                                      *)
EXTENDS Naturals

CONSTANTS
    Chunks,   \* the number of chunks of the full body
    Bug       \* "none", or the name of a rule to remove

VARIABLES
    worker,     \* "running", "done", "failed", or "crashed"
    produced,   \* the number of chunks that the worker gave to the bridge
    held,       \* TRUE while the bridge holds a chunk for the reader
    terminal,   \* what the bridge knows of the end: "none", "done", "error"
    bridge,     \* TRUE while the bridge is alive
    waiting,    \* TRUE while the reader waits for an answer
    got,        \* the number of chunks that the reader has
    result      \* the end that the reader got: "none", "done", or "error"

vars == <<worker, produced, held, terminal, bridge, waiting, got, result>>

Init ==
    /\ worker = "running"
    /\ produced = 0
    /\ held = FALSE
    /\ terminal = "none"
    /\ bridge = TRUE
    /\ waiting = FALSE
    /\ got = 0
    /\ result = "none"

\* The worker gives a chunk to the bridge, and waits until the reader takes
\* it. This is the backpressure.
WorkerData ==
    /\ worker = "running" /\ bridge /\ ~held /\ produced < Chunks
    /\ produced' = produced + 1
    /\ held' = TRUE
    /\ UNCHANGED <<worker, terminal, bridge, waiting, got, result>>

\* The worker read the full body.
WorkerDone ==
    /\ worker = "running" /\ bridge /\ ~held /\ produced = Chunks
    /\ worker' = "done"
    /\ terminal' = "done"
    /\ UNCHANGED <<produced, held, bridge, waiting, got, result>>

\* The connection fails, and the worker tells the bridge.
WorkerFail ==
    /\ worker = "running" /\ bridge
    /\ worker' = "failed"
    /\ terminal' = "error"
    /\ UNCHANGED <<produced, held, bridge, waiting, got, result>>

\* The worker stops and sends no message. The bridge sees that, and it keeps
\* an error for the reader.
WorkerCrash ==
    /\ worker = "running" /\ bridge
    /\ worker' = "crashed"
    /\ terminal' = IF Bug = "exit_on_worker_stop" THEN terminal ELSE "error"
    /\ UNCHANGED <<produced, held, bridge, waiting, got, result>>

\* The rule that the design does not have: the bridge stops when the worker
\* stops, and the reader takes that as the end of the body.
BridgeExit ==
    /\ Bug = "exit_on_worker_stop"
    /\ bridge /\ worker # "running"
    /\ bridge' = FALSE
    /\ UNCHANGED <<worker, produced, held, terminal, waiting, got, result>>

\* The reader asks for the next chunk.
ReaderAsk ==
    /\ result = "none" /\ ~waiting
    /\ waiting' = TRUE
    /\ UNCHANGED <<worker, produced, held, terminal, bridge, got, result>>

\* The bridge answers the reader. A chunk that it holds comes before the
\* end of the body.
AnswerChunk ==
    /\ bridge /\ waiting /\ held
    /\ got' = got + 1
    /\ held' = FALSE
    /\ waiting' = FALSE
    /\ UNCHANGED <<worker, produced, terminal, bridge, result>>

AnswerEnd ==
    /\ bridge /\ waiting /\ terminal # "none" /\ ~held
    /\ result' = terminal
    /\ waiting' = FALSE
    /\ UNCHANGED <<worker, produced, held, terminal, bridge, got>>

\* The reader waits, and the bridge is not alive.
ReaderSeesBridgeStop ==
    /\ ~bridge /\ waiting
    /\ result' = IF Bug = "exit_on_worker_stop" THEN "done" ELSE "error"
    /\ waiting' = FALSE
    /\ UNCHANGED <<worker, produced, held, terminal, bridge, got>>

Next ==
    \/ WorkerData \/ WorkerDone \/ WorkerFail \/ WorkerCrash \/ BridgeExit
    \/ ReaderAsk \/ AnswerChunk \/ AnswerEnd \/ ReaderSeesBridgeStop
    \/ (result # "none" /\ UNCHANGED vars)

\* The worker makes progress or stops, the bridge answers, and the reader
\* continues to ask.
Fairness ==
    /\ WF_vars(WorkerData \/ WorkerDone \/ WorkerFail \/ WorkerCrash)
    /\ WF_vars(AnswerChunk \/ AnswerEnd \/ ReaderSeesBridgeStop)
    /\ WF_vars(ReaderAsk)
    /\ WF_vars(BridgeExit)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ worker \in {"running", "done", "failed", "crashed"}
    /\ produced \in 0..Chunks
    /\ held \in BOOLEAN
    /\ terminal \in {"none", "done", "error"}
    /\ bridge \in BOOLEAN
    /\ waiting \in BOOLEAN
    /\ got \in 0..Chunks
    /\ result \in {"none", "done", "error"}

\* The reader does not get more chunks than the worker read.
NoExtraChunk == got + (IF held THEN 1 ELSE 0) = produced

\* When the reader gets the end of the body, it has all the chunks. A body
\* that is not complete gives an error.
FullBodyOrError == result = "done" => got = Chunks

\* The reader gets an end: the end of the body, or an error.
ReaderGetsAnEnd == <>(result # "none")
=============================================================================
