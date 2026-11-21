----------------------------- MODULE PublicAbort -----------------------------
(* A public abort of a Web.WritableStream whose controller has a signal.    *)
(*                                                                          *)
(* WritableStreamAbort signals abort in its step 2, and the listeners of    *)
(* the signal run at once. The caller asks the stream for its state, runs   *)
(* the listeners, waits until the stream handled the requests that the      *)
(* listeners sent, and then sends the abort. One listener closes the        *)
(* stream. The write in flight stops when the signal aborts: the worker     *)
(* gives its result. In JavaScript that result comes in a later microtask,  *)
(* after the abort. After the abort, the caller errors the controller.      *)
(*                                                                          *)
(* The mailbox of the stream keeps the sequence of the messages of each     *)
(* process. A priority message goes before the usual messages that wait,    *)
(* also before the messages of the same process.                            *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design.                                                      *)
EXTENDS Naturals, Sequences

CONSTANTS
    Bug     \* "none", or the name of a rule to remove

VARIABLES
    caller,   \* "begin", "asked", "listeners", "waits", "rest", "after",
              \* "done", or "stopped"
    box,      \* the mailbox of the stream
    asked,    \* TRUE after the stream answered the first request
    handled,  \* TRUE after the stream answered the barrier
    window,   \* "none", "open", or "closed"
    held,     \* TRUE while the stream keeps the result of the worker
    signal,   \* TRUE after the abort of the signal
    worker,   \* "writes", or "gave" after it sent its result
    log       \* the events that the stream handled, in their sequence

vars == <<caller, box, asked, handled, window, held, signal, worker, log>>

Priority == {"begin", "rest", "error"}

\* The number of priority messages at the start of the mailbox.
Front(b) == IF \E i \in 1..Len(b) : b[i] \notin Priority
               THEN CHOOSE i \in 0..Len(b) :
                       /\ \A j \in 1..i : b[j] \in Priority
                       /\ (i < Len(b) => b[i + 1] \notin Priority)
               ELSE Len(b)

\* A message comes to the mailbox.
Put(b, m) ==
    IF m \in Priority
       THEN SubSeq(b, 1, Front(b)) \o <<m>> \o SubSeq(b, Front(b) + 1, Len(b))
       ELSE Append(b, m)

Init ==
    /\ caller = "begin" /\ box = <<>> /\ asked = FALSE /\ handled = FALSE
    /\ window = "none" /\ held = FALSE /\ signal = FALSE /\ worker = "writes"
    /\ log = <<>>

\* Step 1: the caller asks for the state of the stream, and waits.
Begin ==
    /\ caller = "begin"
    /\ caller' = "asked" /\ box' = Put(box, "begin")
    /\ UNCHANGED <<asked, handled, window, held, signal, worker, log>>

\* Step 2: the caller signals abort. The listener closes the stream.
Listeners ==
    /\ caller = "asked" /\ asked
    /\ signal' = TRUE
    /\ caller' = "listeners" /\ box' = Put(box, "close")
    /\ UNCHANGED <<asked, handled, window, held, worker, log>>

\* The caller stops in a listener. The stream gets the stop of the caller
\* after its messages.
Stop ==
    /\ caller = "asked" /\ asked
    /\ signal' = TRUE
    /\ caller' = "stopped" /\ box' = Put(box, "down")
    /\ UNCHANGED <<asked, handled, window, held, worker, log>>

\* Step 3: the caller waits until the stream handled the close.
Barrier ==
    /\ caller = "listeners" /\ Bug \notin {"no_barrier", "usual_rest"}
    /\ caller' = "waits" /\ box' = Put(box, "barrier")
    /\ UNCHANGED <<asked, handled, window, held, signal, worker, log>>

\* Step 4: the caller sends the abort.
Rest ==
    /\ \/ caller = "waits" /\ handled
       \/ caller = "listeners" /\ Bug \in {"no_barrier", "usual_rest"}
    /\ caller' = "after"
    /\ box' = IF Bug = "usual_rest" THEN Append(box, "rest") ELSE Put(box, "rest")
    /\ UNCHANGED <<asked, handled, window, held, signal, worker, log>>

\* After the abort, the caller errors the controller.
After ==
    /\ caller = "after"
    /\ caller' = "done" /\ box' = Put(box, "error")
    /\ UNCHANGED <<asked, handled, window, held, signal, worker, log>>

\* The write stops when the signal aborts.
WorkerGives ==
    /\ signal /\ worker = "writes"
    /\ worker' = "gave" /\ box' = Put(box, "result")
    /\ UNCHANGED <<caller, asked, handled, window, held, signal, log>>

\* The abort, and then the result that the stream kept.
Abort(l) == IF held THEN l \o <<"abort", "result">> ELSE Append(l, "abort")

\* The stream handles the next message of its mailbox.
Handle ==
    /\ box # <<>>
    /\ box' = Tail(box)
    /\ LET m == Head(box) IN
       CASE m = "begin" ->
              /\ asked' = TRUE /\ window' = "open"
              /\ UNCHANGED <<handled, held, log>>
         [] m = "barrier" ->
              /\ handled' = TRUE
              /\ UNCHANGED <<asked, window, held, log>>
         [] m = "result" /\ window = "open" /\ Bug # "no_hold" ->
              /\ held' = TRUE
              /\ UNCHANGED <<asked, handled, window, log>>
         \* The stop of the caller: the stream does the abort with no
         \* caller.
         [] m = "rest" \/ (m = "down" /\ window = "open" /\ Bug # "keep_window") ->
              /\ log' = Abort(log) /\ held' = FALSE /\ window' = "closed"
              /\ UNCHANGED <<asked, handled>>
         [] m \in {"close", "result", "error"} ->
              /\ log' = Append(log, m)
              /\ UNCHANGED <<asked, handled, window, held>>
         [] OTHER ->
              UNCHANGED <<asked, handled, window, held, log>>
    /\ UNCHANGED <<caller, signal, worker>>

Next ==
    \/ Begin \/ Listeners \/ Stop \/ Barrier \/ Rest \/ After \/ WorkerGives
    \/ Handle
    \/ UNCHANGED vars

Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(Begin) /\ WF_vars(Listeners) /\ WF_vars(Barrier) /\ WF_vars(Rest)
    /\ WF_vars(After) /\ WF_vars(WorkerGives) /\ WF_vars(Handle)

-----------------------------------------------------------------------------
\* Properties

Messages == {"begin", "close", "barrier", "rest", "error", "result", "down"}

TypeOK ==
    /\ caller \in {"begin", "asked", "listeners", "waits", "after", "done", "stopped"}
    /\ \A i \in 1..Len(box) : box[i] \in Messages
    /\ asked \in BOOLEAN /\ handled \in BOOLEAN /\ held \in BOOLEAN
    /\ window \in {"none", "open", "closed"}
    /\ signal \in BOOLEAN /\ worker \in {"writes", "gave"}
    /\ \A i \in 1..Len(log) : log[i] \in {"close", "abort", "result", "error"}

\* The event e comes after the abort in the log.
AfterAbort(e) ==
    \A i \in 1..Len(log) : log[i] = e => \E j \in 1..(i - 1) : log[j] = "abort"

\* The stream handles the close of the listener before the abort.
CloseFirst ==
    \A i \in 1..Len(log) : log[i] = "abort" => ~\E j \in (i + 1)..Len(log) : log[j] = "close"

\* The result of the write comes after the abort, as in JavaScript.
ResultAfter == AfterAbort("result")

\* A request that the caller sends after the abort comes after it.
ErrorAfter == AfterAbort("error")

\* The stream aborts, and it handles the result of the write, also when the
\* caller stops.
Progress ==
    <>(/\ \E i \in 1..Len(log) : log[i] = "abort"
       /\ \E i \in 1..Len(log) : log[i] = "result")
=============================================================================
