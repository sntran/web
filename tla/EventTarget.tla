----------------------------- MODULE EventTarget ------------------------------
(* An event target of Web.EventTarget.new/0, and the dispatch of one event. *)
(*                                                                          *)
(* The process of the target, the store, keeps the event listener list and *)
(* answers each request at once: it never runs the code of a user. A       *)
(* listener belongs to the process that added it: when that process stops, *)
(* the store removes its listeners.                                        *)
(*                                                                          *)
(* The dispatch runs in the process that calls dispatch_event/2, Main. It   *)
(* has two passes at the target: the capturing pass calls the listeners    *)
(* with capture, and the bubbling pass calls the others. Each pass takes a *)
(* clone of the list. Before the call of a listener of the clone, the      *)
(* dispatch asks the store if the listener is still there (the flag        *)
(* "removed"); the store removes a listener with once at that time. A      *)
(* listener runs in Main: it can add and remove listeners, and dispatch    *)
(* the same event again, which raises an InvalidStateError.                *)
(*                                                                          *)
(* The store stops when its owner stopped and it has no listener, after    *)
(* the linger time. A request to a store that stopped has no effect: the   *)
(* target has no listener.                                                 *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design.                                                      *)
EXTENDS Naturals, Sequences

CONSTANTS
    Procs,      \* the processes that add listeners and can stop
    Main,       \* the process that dispatches; it does not stop
    Listeners,  \* the listeners: a type, a callback, and a capture
    Capture,    \* the listeners with capture
    Once,       \* the listeners with once
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
    in_call,      \* the listener that runs now, or "none"
    called,       \* the listeners that the dispatch called
    bubbled,      \* TRUE after the dispatch called a listener with no capture
    added,        \* the listeners that came into the list during the pass
    once_calls,   \* once_calls[l] is the number of calls of a listener with
                  \* once since its last add
    errors        \* the rules that the dispatch broke

vars == <<running, owner_alive, live, list, owner, gen, phase, clone, flag, in_call,
          called, bubbled, added, once_calls, errors>>

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
    /\ in_call = "none"
    /\ called = {}
    /\ bubbled = FALSE
    /\ added = {}
    /\ once_calls = [l \in Listeners |-> 0]
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
    /\ UNCHANGED <<running, owner_alive, live, phase, flag, in_call, called, bubbled,
                   errors>>

Remove(l) ==
    /\ running /\ InList(l)
    /\ list' = Without(list, l)
    /\ UNCHANGED <<running, owner_alive, live, owner, gen, phase, clone, flag, in_call,
                   called, bubbled, added, once_calls, errors>>

\* Process p stops. The store removes its listeners.
ProcStop(p) ==
    /\ p \in live
    /\ live' = live \ {p}
    /\ list' = IF Bug = "keep_dead_listeners" THEN list
               ELSE SelectSeq(list, LAMBDA x : owner[x] # p)
    /\ UNCHANGED <<running, owner_alive, owner, gen, phase, clone, flag, in_call,
                   called, bubbled, added, once_calls, errors>>

OwnerStop ==
    /\ owner_alive
    /\ owner_alive' = FALSE
    /\ UNCHANGED <<running, live, list, owner, gen, phase, clone, flag, in_call,
                   called, bubbled, added, once_calls, errors>>

\* The linger time of a target with no use is complete: the store stops.
Expire ==
    /\ running /\ ~owner_alive
    /\ (list = <<>> \/ Bug = "no_listener_rule")
    /\ Bug # "stays_unused"
    /\ running' = FALSE
    /\ UNCHANGED <<owner_alive, live, list, owner, gen, phase, clone, flag, in_call,
                   called, bubbled, added, once_calls, errors>>

-----------------------------------------------------------------------------
\* The dispatch in Main

\* The start of a dispatch: the clone of the capturing pass. A store that
\* stopped gives no listener. With the bug "one_pass", the only pass calls
\* all the listeners.
Begin ==
    /\ phase = "idle" /\ ~flag
    /\ phase' = IF Bug = "one_pass" THEN "bubbling" ELSE "capturing"
    /\ clone' = IF running THEN Entries ELSE <<>>
    /\ flag' = TRUE
    /\ called' = {}
    /\ bubbled' = FALSE
    /\ added' = {}
    /\ UNCHANGED <<running, owner_alive, live, list, owner, gen, in_call, once_calls,
                   errors>>

InPass(l) ==
    IF Bug = "one_pass" THEN TRUE
    ELSE IF phase = "capturing" THEN l \in Capture ELSE l \notin Capture

\* The dispatch visits the next listener of the clone. It skips a listener
\* of the other pass. It asks the store for the listener: a listener that
\* was removed is not called, and a listener with once is removed now.
Visit ==
    /\ phase # "idle" /\ clone # <<>> /\ in_call = "none"
    /\ LET l == Head(clone).l
           present == running /\ InList(l) /\ gen[l] = Head(clone).g
           call == InPass(l) /\ (present \/ Bug = "no_removed_check")
       IN /\ clone' = Tail(clone)
          /\ IF call
                THEN /\ in_call' = l
                     /\ list' = IF l \in Once /\ present /\ Bug # "once_kept"
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
    /\ UNCHANGED <<running, owner_alive, live, owner, gen, phase, flag, added>>

\* The listener returns.
Return ==
    /\ in_call # "none"
    /\ in_call' = "none"
    /\ UNCHANGED <<running, owner_alive, live, list, owner, gen, phase, clone, flag,
                   called, bubbled, added, once_calls, errors>>

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
               /\ UNCHANGED <<running, owner_alive, live, list, owner, gen, flag,
                              called, bubbled, once_calls, errors>>
          ELSE UNCHANGED vars

\* The end of the capturing pass: the bubbling pass takes a new clone.
NextPass ==
    /\ phase = "capturing" /\ clone = <<>> /\ in_call = "none"
    /\ phase' = "bubbling"
    /\ clone' = IF running THEN Entries ELSE <<>>
    /\ added' = {}
    /\ UNCHANGED <<running, owner_alive, live, list, owner, gen, flag, in_call,
                   called, bubbled, once_calls, errors>>

End ==
    /\ phase = "bubbling" /\ clone = <<>> /\ in_call = "none"
    /\ phase' = "idle"
    /\ flag' = FALSE
    /\ added' = {}
    /\ UNCHANGED <<running, owner_alive, live, list, owner, gen, clone, in_call,
                   called, bubbled, once_calls, errors>>

Next ==
    \/ \E p \in Adders, l \in Listeners : Add(p, l)
    \/ \E l \in Listeners : Remove(l)
    \/ \E p \in Procs : ProcStop(p)
    \/ OwnerStop \/ Expire
    \/ Begin \/ Visit \/ Return \/ Nested \/ NextPass \/ End
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
    /\ in_call \in Listeners \cup {"none"}
    /\ called \subseteq Listeners
    /\ bubbled \in BOOLEAN
    /\ added \subseteq Listeners
    /\ once_calls \in [Listeners -> 0..3]
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

\* A listener with once runs one time at most after its add.
OnceOnce == \A l \in Once : once_calls[l] <= 1

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
