----------------------------- MODULE AbortSignal -----------------------------
(* The lifetime of one signal of Web.AbortSignal.                           *)
(*                                                                          *)
(* A signal that is not aborted is a process. The clients are the processes *)
(* that subscribe to it. The module shows which clients learn of an abort,  *)
(* and when the process of the signal stops.                                *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design.                                                      *)
EXTENDS Naturals

CONSTANTS
    Clients,    \* the processes that subscribe to the signal
    MaxSubs,    \* the largest number of subscriptions of one client
    Bug         \* "none", or the name of a rule to remove

VARIABLES
    aborted,      \* TRUE after the abort
    running,      \* TRUE while the process of the signal is alive
    owner_alive,  \* TRUE while the owner of the signal is alive
    live,         \* the clients that are alive
    subs,         \* subs[c] is the number of subscriptions that the signal
                  \* has for client c
    wants,        \* wants[c] is the number of subscriptions that client c
                  \* has not ended
    notified,     \* the clients that got the abort
    dropped,      \* the clients that saw the signal stop with no abort
    stored        \* TRUE while the store has the reason of the abort

vars == <<aborted, running, owner_alive, live, subs, wants, notified, dropped, stored>>

NoSubs == [c \in Clients |-> 0]

Init ==
    /\ aborted = FALSE
    /\ running = TRUE
    /\ owner_alive = TRUE
    /\ live = Clients
    /\ subs = NoSubs
    /\ wants = NoSubs
    /\ notified = {}
    /\ dropped = {}
    /\ stored = FALSE

Subscribed == {c \in Clients : subs[c] > 0}

\* The signal has no owner and no subscriber.
Unused == ~owner_alive /\ Subscribed = {}

Subscribe(c) ==
    /\ running /\ c \in live /\ subs[c] < MaxSubs
    /\ subs' = [subs EXCEPT ![c] = @ + 1]
    /\ wants' = [wants EXCEPT ![c] = @ + 1]
    /\ UNCHANGED <<aborted, running, owner_alive, live, notified, dropped, stored>>

Unsubscribe(c) ==
    /\ running /\ c \in live /\ subs[c] > 0
    /\ subs' = [subs EXCEPT ![c] = IF Bug = "unsubscribe_keeps_entry" THEN @ ELSE @ - 1]
    /\ wants' = [wants EXCEPT ![c] = @ - 1]
    /\ UNCHANGED <<aborted, running, owner_alive, live, notified, dropped, stored>>

\* The controller aborts the signal. Each subscriber gets the abort. The
\* process of the signal stops, and the store keeps the reason.
Abort ==
    /\ running /\ ~aborted
    /\ aborted' = TRUE
    /\ running' = FALSE
    /\ notified' = IF Bug = "abort_skips_subscribers" THEN notified ELSE notified \cup Subscribed
    /\ subs' = NoSubs
    /\ wants' = NoSubs
    /\ stored' = TRUE
    /\ UNCHANGED <<owner_alive, live, dropped>>

OwnerStop ==
    /\ owner_alive
    /\ owner_alive' = FALSE
    /\ UNCHANGED <<aborted, running, live, subs, wants, notified, dropped, stored>>

\* Client c stops. The signal removes its subscriptions.
ClientStop(c) ==
    /\ c \in live
    /\ live' = live \ {c}
    /\ subs' = [subs EXCEPT ![c] = 0]
    /\ wants' = [wants EXCEPT ![c] = 0]
    /\ UNCHANGED <<aborted, running, owner_alive, notified, dropped, stored>>

\* The linger time of a signal that has no use is complete. The signal
\* stops with no abort. A subscriber at that time sees the stop.
Expire ==
    /\ running
    /\ IF Bug = "stop_with_subscribers" THEN ~owner_alive ELSE Unused
    /\ running' = FALSE
    /\ dropped' = dropped \cup Subscribed
    /\ subs' = NoSubs
    /\ wants' = NoSubs
    /\ UNCHANGED <<aborted, owner_alive, live, notified, stored>>

\* The store removes the reason after the linger time.
Sweep ==
    /\ stored
    /\ stored' = FALSE
    /\ UNCHANGED <<aborted, running, owner_alive, live, subs, wants, notified, dropped>>

Next ==
    \/ \E c \in Clients : Subscribe(c) \/ Unsubscribe(c) \/ ClientStop(c)
    \/ Abort \/ OwnerStop \/ Expire \/ Sweep
    \/ (~running /\ UNCHANGED vars)

Spec == Init /\ [][Next]_vars /\ WF_vars(Expire) /\ WF_vars(Sweep)

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ aborted \in BOOLEAN
    /\ running \in BOOLEAN
    /\ owner_alive \in BOOLEAN
    /\ live \subseteq Clients
    /\ subs \in [Clients -> 0..MaxSubs]
    /\ wants \in [Clients -> 0..MaxSubs]
    /\ notified \subseteq Clients
    /\ dropped \subseteq Clients
    /\ stored \in BOOLEAN

\* Only a client that is alive has a subscription, and only to a signal that
\* runs.
SubscriptionsAreValid == \A c \in Clients : subs[c] > 0 => c \in live /\ running

\* The signal has a subscription for a client only while the client wants
\* it. Thus an unsubscribe removes the subscription from the signal.
SubscriptionsMatch == subs = wants

\* Each client that is subscribed at the abort gets the abort.
AbortReachesSubscribers ==
    [][(~aborted /\ aborted') => Subscribed \subseteq notified']_vars

\* No subscriber sees the signal stop with no abort. Thus a stream that
\* another process reads does not get a false abort when the owner of the
\* signal stops.
NoFalseAbort == dropped = {}

\* A signal that is not aborted stays while its owner is alive.
KeptForOwner == (owner_alive /\ ~aborted) => running

\* A signal that stopped does not start again.
StaysStopped == [][~running => ~running']_vars

\* A signal does not continue after its owner and all its clients. This is
\* false when an unsubscribe does not remove the subscription.
NoOrphan == (~owner_alive /\ live = {}) ~> ~running

\* A signal with no owner stops after its last subscriber unsubscribes, if
\* no client subscribes again.
NoInterest == ~owner_alive /\ wants = NoSubs
UnusedStops == NoInterest ~> (~running \/ ~NoInterest)

\* The store does not keep the reason of an abort with no limit.
ReasonIsRemoved == stored ~> ~stored
=============================================================================
