----------------------------- MODULE EventTarget ------------------------------
(* The listener steps of an event target, and the dispatch of one event.    *)
(*                                                                          *)
(* Each event target of the library has these steps: a target of            *)
(* Web.EventTarget.new/0, a signal, a message port, and a broadcast         *)
(* channel.                                                                 *)
(* A process, the store, keeps the event listener list and answers each     *)
(* request at once: it never runs the code of a user. The store of a        *)
(* target of new/0 is its process, and the lifetime of that store is in     *)
(* this module too: a listener belongs to the process that added it, and    *)
(* when that process stops, the store removes its listeners.                *)
(*                                                                          *)
(* The dispatch runs in the process that calls dispatch_event/2, Main. It   *)
(* has two passes at the target: the capturing pass calls the listeners     *)
(* with capture, and the bubbling pass calls the others. Each pass takes a  *)
(* clone of the list. Before the call of a listener of the clone, the       *)
(* dispatch asks the store if the listener is still there (the flag         *)
(* "removed"); the store removes a listener with once at that time, before  *)
(* the call. A listener runs in Main: it can add and remove listeners,      *)
(* cancel the event, dispatch the same event again, which raises an         *)
(* InvalidStateError, and dispatch a new event to the target. A listener    *)
(* with passive cannot cancel the event. The result of the dispatch is      *)
(* "false" when a listener canceled the event. A dispatch of an event that  *)
(* is not initialized raises an InvalidStateError.                          *)
(*                                                                          *)
(* The store of a target of new/0 stops when its owner stopped and it has   *)
(* no listener, after the linger time. A request to a store that stopped    *)
(* has no effect: the target has no listener.                               *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design. The values "no_removed_check", "one_pass",           *)
(* "no_dispatch_flag", "once_after_call", "passive_ignored", and            *)
(* "result_always_true" are also the old steps of a message port and a      *)
(* broadcast channel. The value "no_initialized_check" is the old step of   *)
(* each target.                                                             *)
EXTENDS Naturals, Sequences

CONSTANTS
    Procs,      \* the processes that add listeners and can stop
    Main,       \* the process that dispatches; it does not stop
    Listeners,  \* the listeners: a type, a callback, and a capture
    Capture,    \* the listeners with capture
    Once,       \* the listeners with once
    Passive,    \* the listeners with passive
    Owned,      \* the listeners that the processes of Procs add
    Again,      \* the listeners that can be added a second time
    Bug         \* "none", or the name of a rule to remove

VARIABLES
    running,      \* TRUE while the store is alive
    owner_alive,  \* TRUE while the owner of the target is alive
    live,         \* the processes of Procs that are alive
    list,         \* the event listener list, in the sequence of the adds
    owner,        \* owner[l] is the process that added listener l
    gen,          \* gen[l] is the number of adds of listener l: each add
                  \* makes a new entry of the list
    phase,        \* the dispatch: "idle", "capturing", or "bubbling"
    clone,        \* the entries of the clone that the pass did not visit:
                  \* records with the listener and its add
    flag,         \* the dispatch flag of the event
    raw,          \* TRUE when the event of the dispatch is not initialized
    in_call,      \* the listener that runs now, or "none"
    called,       \* the listeners that the dispatch called
    bubbled,      \* TRUE after the dispatch called a listener with no capture
    added,        \* the listeners that came into the list during the pass
    once_calls,   \* once_calls[l] is the number of calls of a listener with
                  \* once since its last add
    cancels,      \* the listeners that canceled the event of the dispatch
    result,       \* the result of the last dispatch: "none", "true", "false"
    inner,        \* the listeners that the last new event of the listener
                  \* that runs now called, in their sequence
    errors        \* the rules that the dispatch broke

vars == <<running, owner_alive, live, list, owner, gen, phase, clone, flag, raw, in_call,
          called, bubbled, added, once_calls, cancels, result, inner, errors>>

\* The largest number of adds of a listener of Again.
MaxAdds == 2

Adders == Procs \cup {Main}

InList(l) == \E i \in 1..Len(list) : list[i] = l
Without(s, l) == SelectSeq(s, LAMBDA x : x # l)

\* The clone of the list: each entry with its add.
Entries == [i \in 1..Len(list) |-> [l |-> list[i], g |-> gen[list[i]]]]

Init ==
    /\ running = TRUE
    /\ owner_alive = TRUE
    /\ live = Procs
    /\ list = <<>>
    /\ owner = [l \in Listeners |-> Main]
    /\ gen = [l \in Listeners |-> 0]
    /\ phase = "idle"
    /\ clone = <<>>
    /\ flag = FALSE
    /\ raw = FALSE
    /\ in_call = "none"
    /\ called = {}
    /\ bubbled = FALSE
    /\ added = {}
    /\ once_calls = [l \in Listeners |-> 0]
    /\ cancels = {}
    /\ result = "none"
    /\ inner = <<>>
    /\ errors = {}

-----------------------------------------------------------------------------
\* The requests to the store

\* Process p adds listener l. A listener with the same type, callback, and
\* capture is not added again. With the bug "no_clone", the pass sees the
\* listener that comes into the list.
Add(p, l) ==
    /\ running /\ ~InList(l)
    /\ p = Main \/ (p \in live /\ l \in Owned)
    /\ gen[l] < (IF l \in Again THEN MaxAdds ELSE 1)
    /\ list' = Append(list, l)
    /\ owner' = [owner EXCEPT ![l] = p]
    /\ gen' = [gen EXCEPT ![l] = @ + 1]
    /\ once_calls' = [once_calls EXCEPT ![l] = 0]
    /\ added' = IF phase # "idle" THEN added \cup {l} ELSE added
    /\ clone' = IF phase # "idle" /\ Bug = "no_clone"
                   THEN Append(clone, [l |-> l, g |-> gen[l] + 1]) ELSE clone
    /\ UNCHANGED <<running, owner_alive, live, phase, flag, raw, in_call, called, bubbled,
                   cancels, result, inner, errors>>

\* A remove, or the abort of the signal of the listener.
Remove(l) ==
    /\ running /\ InList(l)
    /\ list' = Without(list, l)
    /\ UNCHANGED <<running, owner_alive, live, owner, gen, phase, clone, flag, raw, in_call,
                   called, bubbled, added, once_calls, cancels, result, inner, errors>>

\* Process p stops. The store removes its listeners.
ProcStop(p) ==
    /\ p \in live
    /\ live' = live \ {p}
    /\ list' = IF Bug = "keep_dead_listeners" THEN list
               ELSE SelectSeq(list, LAMBDA x : owner[x] # p)
    /\ UNCHANGED <<running, owner_alive, owner, gen, phase, clone, flag, raw, in_call,
                   called, bubbled, added, once_calls, cancels, result, inner, errors>>

OwnerStop ==
    /\ owner_alive
    /\ owner_alive' = FALSE
    /\ UNCHANGED <<running, live, list, owner, gen, phase, clone, flag, raw, in_call,
                   called, bubbled, added, once_calls, cancels, result, inner, errors>>

\* The linger time of a target with no use is complete: the store stops.
Expire ==
    /\ running /\ ~owner_alive
    /\ (list = <<>> \/ Bug = "no_listener_rule")
    /\ Bug # "stays_unused"
    /\ running' = FALSE
    /\ UNCHANGED <<owner_alive, live, list, owner, gen, phase, clone, flag, raw, in_call,
                   called, bubbled, added, once_calls, cancels, result, inner, errors>>

-----------------------------------------------------------------------------
\* The dispatch in Main

\* The start of a dispatch: the clone of the capturing pass. A store that
\* stopped gives no listener. With the bug "one_pass", the only pass calls
\* all the listeners.
Start(r) ==
    /\ phase' = IF Bug = "one_pass" THEN "bubbling" ELSE "capturing"
    /\ clone' = IF running THEN Entries ELSE <<>>
    /\ flag' = TRUE
    /\ raw' = r
    /\ called' = {}
    /\ bubbled' = FALSE
    /\ added' = {}
    /\ cancels' = {}
    /\ result' = "none"
    /\ inner' = <<>>
    /\ UNCHANGED <<running, owner_alive, live, list, owner, gen, in_call, once_calls,
                   errors>>

Begin ==
    /\ phase = "idle" /\ ~flag
    /\ Start(FALSE)

\* A dispatch of an event that is not initialized raises an
\* InvalidStateError, and calls no listener. With the bug
\* "no_initialized_check", the dispatch starts.
BeginRaw ==
    /\ phase = "idle" /\ ~flag
    /\ IF Bug = "no_initialized_check" THEN Start(TRUE) ELSE UNCHANGED vars

InPass(l) ==
    IF Bug = "one_pass" THEN TRUE
    ELSE IF phase = "capturing" THEN l \in Capture ELSE l \notin Capture

\* The dispatch visits the next listener of the clone. It skips a listener
\* of the other pass. It asks the store for the listener: a listener that
\* was removed is not called, and a listener with once is removed now,
\* before its call. With the bug "once_after_call", the dispatch removes it
\* after the call.
Visit ==
    /\ phase # "idle" /\ clone # <<>> /\ in_call = "none"
    /\ LET l == Head(clone).l
           present == running /\ InList(l) /\ gen[l] = Head(clone).g
           call == InPass(l) /\ (present \/ Bug = "no_removed_check")
       IN /\ clone' = Tail(clone)
          /\ IF call
                THEN /\ in_call' = l
                     /\ list' = IF l \in Once /\ present
                                   /\ Bug \notin {"once_kept", "once_after_call"}
                                   THEN Without(list, l) ELSE list
                     /\ once_calls' = IF l \in Once
                                         THEN [once_calls EXCEPT ![l] = @ + 1]
                                         ELSE once_calls
                     /\ called' = called \cup {l}
                     /\ bubbled' = (bubbled \/ l \notin Capture)
                     /\ errors' = errors
                                  \cup (IF present THEN {} ELSE {"removed_called"})
                                  \cup (IF l \in added THEN {"added_called"} ELSE {})
                                  \cup (IF l \in called THEN {"called_twice"} ELSE {})
                                  \cup (IF l \in Capture /\ bubbled
                                           THEN {"capture_late"} ELSE {})
                ELSE UNCHANGED <<in_call, list, once_calls, called, bubbled, errors>>
    /\ UNCHANGED <<running, owner_alive, live, owner, gen, phase, flag, raw, added, cancels,
                   result, inner>>

\* The listener returns.
Return ==
    /\ in_call # "none"
    /\ in_call' = "none"
    /\ list' = IF Bug = "once_after_call" /\ in_call \in Once
                  THEN Without(list, in_call) ELSE list
    /\ inner' = <<>>
    /\ UNCHANGED <<running, owner_alive, live, owner, gen, phase, clone, flag, raw,
                   called, bubbled, added, once_calls, cancels, result, errors>>

\* The listener cancels the event. A listener with passive cannot cancel
\* it: its call has the flag "in passive listener". With the bug
\* "passive_ignored", it can.
Cancel ==
    /\ in_call # "none"
    /\ cancels' = IF in_call \notin Passive \/ Bug = "passive_ignored"
                     THEN cancels \cup {in_call} ELSE cancels
    /\ UNCHANGED <<running, owner_alive, live, list, owner, gen, phase, clone, flag, raw,
                   in_call, called, bubbled, added, once_calls, result, inner, errors>>

\* A listener dispatches the same event. The dispatch flag gives an
\* InvalidStateError. With the bug "no_dispatch_flag", the dispatch starts
\* again in the dispatch.
Nested ==
    /\ in_call # "none"
    /\ IF Bug = "no_dispatch_flag"
          THEN /\ phase' = "capturing"
               /\ clone' = IF running THEN Entries ELSE <<>>
               /\ in_call' = "none"
               /\ added' = {}
               /\ UNCHANGED <<running, owner_alive, live, list, owner, gen, flag, raw,
                              called, bubbled, once_calls, cancels, result, inner, errors>>
          ELSE UNCHANGED vars

\* The listeners that a new event calls: those with capture first, each
\* group in the sequence of the list.
Inner ==
    IF running
       THEN SelectSeq(list, LAMBDA x : x \in Capture) \o SelectSeq(list, LAMBDA x : x \notin Capture)
       ELSE <<>>

\* A listener dispatches a new event to the target. The dispatch of the new
\* event runs to its end before the listener continues, and its listeners
\* change nothing. It removes each listener with once before its call. A
\* listener with once that runs now is not in the list: the new event does
\* not call it again.
NestedNew ==
    /\ in_call # "none"
    /\ inner' = Inner
    /\ list' = IF running THEN SelectSeq(list, LAMBDA x : x \notin Once) ELSE list
    /\ once_calls' = [l \in Listeners |->
                         IF l \in Once /\ running /\ InList(l)
                            THEN once_calls[l] + 1 ELSE once_calls[l]]
    /\ UNCHANGED <<running, owner_alive, live, owner, gen, phase, clone, flag, raw, in_call,
                   called, bubbled, added, cancels, result, errors>>

\* The end of the capturing pass: the bubbling pass takes a new clone.
NextPass ==
    /\ phase = "capturing" /\ clone = <<>> /\ in_call = "none"
    /\ phase' = "bubbling"
    /\ clone' = IF running THEN Entries ELSE <<>>
    /\ added' = {}
    /\ UNCHANGED <<running, owner_alive, live, list, owner, gen, flag, raw, in_call,
                   called, bubbled, once_calls, cancels, result, inner, errors>>

\* The end of the dispatch. The result is "false" when a listener canceled
\* the event. With the bug "result_always_true", it is always "true".
End ==
    /\ phase = "bubbling" /\ clone = <<>> /\ in_call = "none"
    /\ phase' = "idle"
    /\ flag' = FALSE
    /\ added' = {}
    /\ result' = IF cancels = {} \/ Bug = "result_always_true" THEN "true" ELSE "false"
    /\ UNCHANGED <<running, owner_alive, live, list, owner, gen, clone, raw, in_call,
                   called, bubbled, once_calls, cancels, inner, errors>>

Next ==
    \/ \E p \in Adders, l \in Listeners : Add(p, l)
    \/ \E l \in Listeners : Remove(l)
    \/ \E p \in Procs : ProcStop(p)
    \/ OwnerStop \/ Expire
    \/ Begin \/ BeginRaw \/ Visit \/ Return \/ Cancel \/ Nested \/ NestedNew \/ NextPass
    \/ End
    \/ UNCHANGED vars

Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(Expire) /\ WF_vars(Visit) /\ WF_vars(Return) /\ WF_vars(NextPass)
    /\ WF_vars(End)

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ running \in BOOLEAN
    /\ owner_alive \in BOOLEAN
    /\ live \subseteq Procs
    /\ \A i \in 1..Len(list) : list[i] \in Listeners
    /\ owner \in [Listeners -> Adders]
    /\ phase \in {"idle", "capturing", "bubbling"}
    /\ gen \in [Listeners -> 0..MaxAdds]
    /\ \A i \in 1..Len(clone) : clone[i].l \in Listeners /\ clone[i].g \in 1..MaxAdds
    /\ flag \in BOOLEAN
    /\ raw \in BOOLEAN
    /\ in_call \in Listeners \cup {"none"}
    /\ called \subseteq Listeners
    /\ bubbled \in BOOLEAN
    /\ added \subseteq Listeners
    /\ once_calls \in [Listeners -> 0..3]
    /\ cancels \subseteq Listeners
    /\ result \in {"none", "true", "false"}
    /\ \A i \in 1..Len(inner) : inner[i] \in Listeners
    /\ errors \subseteq {"removed_called", "added_called", "called_twice", "capture_late"}

\* A listener that was removed is not called.
RemovedNotCalled == "removed_called" \notin errors

\* A listener that comes into the list during a pass is not called in that
\* pass.
ClonedOnly == "added_called" \notin errors

\* The dispatch calls each listener one time at most.
CalledOnce == "called_twice" \notin errors

\* The listeners with capture run before the others.
CaptureFirst == "capture_late" \notin errors

\* A listener with once runs one time at most after its add, also when it
\* dispatches a new event to its target.
OnceOnce == \A l \in Once : once_calls[l] <= 1

\* A listener with passive does not cancel the event.
PassiveNoCancel == cancels \cap Passive = {}

\* The result of a dispatch is "false" if, and only if, a listener canceled
\* the event.
ResultTells == result # "none" => ((result = "true") <=> (cancels = {}))

\* Only an event that is initialized is dispatched.
InitializedOnly == ~(flag /\ raw)

\* Each listener of the list belongs to a process that is alive.
ListenersOfLive == \A i \in 1..Len(list) : owner[list[i]] \in live \cup {Main}

\* The target stays while its owner is alive, and while it has a listener.
KeptForUse == (owner_alive \/ list # <<>>) => running

\* A target with no owner and no listener stops, if no listener comes.
NoInterest == ~owner_alive /\ list = <<>>
UnusedStops == NoInterest ~> (~running \/ ~NoInterest)

\* Each dispatch ends.
DispatchEnds == flag ~> ~flag
=============================================================================
