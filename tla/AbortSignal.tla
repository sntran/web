----------------------------- MODULE AbortSignal -----------------------------
(* The lifetime of one signal of Web.AbortSignal.                           *)
(*                                                                          *)
(* A signal that is not aborted is a process. The clients are processes:   *)
(* each one can subscribe to the signal, and can use it: add a listener of *)
(* the event "abort", or an abort algorithm. One signal of                 *)
(* AbortSignal.any/1 can depend on the signal: the dependent signal. A     *)
(* different process, its maker, made it.                                  *)
(*                                                                          *)
(* The abort marks the signal and the dependent signal, and the            *)
(* subscribers get it. The process that aborts then runs the steps of the  *)
(* abort: see AbortSteps.tla. While it runs them, the process of the       *)
(* signal stays, to answer the dispatch of the event. The processes stop   *)
(* when the steps end, or when the process that runs them stops.           *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design.                                                      *)
EXTENDS Naturals

CONSTANTS
    Clients,    \* the processes that subscribe to the signal and use it
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
    stored,       \* TRUE while the store has the reason of the abort
    users,        \* the clients that added a listener or an abort algorithm,
                  \* and did not remove it
    dep,          \* the dependent signal: "none", "running", "aborted", or
                  \* "stopped"
    maker_alive,  \* TRUE while the maker of the dependent signal is alive
    steps         \* the steps of the abort: "idle", "run", or "ended"

vars == <<aborted, running, owner_alive, live, subs, wants, notified, dropped,
          stored, users, dep, maker_alive, steps>>

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
    /\ users = {}
    /\ dep = "none"
    /\ maker_alive = TRUE
    /\ steps = "idle"

Subscribed == {c \in Clients : subs[c] > 0}

\* The signal is not aborted, and its process runs.
Open == running /\ ~aborted

\* The signal has no owner, and no process has a use for it.
Unused ==
    /\ ~owner_alive
    /\ Subscribed = {}
    /\ (Bug = "use_not_kept" \/ users = {})
    /\ (Bug = "dependent_not_kept" \/ dep # "running")

Subscribe(c) ==
    /\ Open /\ c \in live /\ subs[c] < MaxSubs
    /\ subs' = [subs EXCEPT ![c] = @ + 1]
    /\ wants' = [wants EXCEPT ![c] = @ + 1]
    /\ UNCHANGED <<aborted, running, owner_alive, live, notified, dropped, stored,
                   users, dep, maker_alive, steps>>

Unsubscribe(c) ==
    /\ running /\ c \in live /\ subs[c] > 0
    /\ subs' = [subs EXCEPT ![c] = IF Bug = "unsubscribe_keeps_entry" THEN @ ELSE @ - 1]
    /\ wants' = [wants EXCEPT ![c] = @ - 1]
    /\ UNCHANGED <<aborted, running, owner_alive, live, notified, dropped, stored,
                   users, dep, maker_alive, steps>>

\* Client c adds a listener or an abort algorithm.
Use(c) ==
    /\ Open /\ c \in live /\ c \notin users
    /\ users' = users \cup {c}
    /\ UNCHANGED <<aborted, running, owner_alive, live, subs, wants, notified,
                   dropped, stored, dep, maker_alive, steps>>

\* Client c removes its listener.
Unuse(c) ==
    /\ Open /\ c \in users
    /\ users' = users \ {c}
    /\ UNCHANGED <<aborted, running, owner_alive, live, subs, wants, notified,
                   dropped, stored, dep, maker_alive, steps>>

\* AbortSignal.any/1 makes the dependent signal. The signal keeps it in its
\* list of dependent signals.
Depend ==
    /\ Open /\ dep = "none"
    /\ dep' = "running"
    /\ UNCHANGED <<aborted, running, owner_alive, live, subs, wants, notified,
                   dropped, stored, users, maker_alive, steps>>

\* The controller aborts the signal. Each subscriber gets the abort. The
\* store keeps the reason. The process of the signal marks the dependent
\* signal, and stays while the steps of the abort run.
Abort ==
    /\ Open
    /\ aborted' = TRUE
    /\ running' = (Bug # "stop_at_mark")
    /\ notified' = IF Bug = "abort_skips_subscribers" THEN notified ELSE notified \cup Subscribed
    /\ subs' = NoSubs
    /\ wants' = NoSubs
    /\ stored' = TRUE
    /\ dep' = IF dep = "running" THEN "aborted" ELSE dep
    /\ steps' = "run"
    /\ UNCHANGED <<owner_alive, live, dropped, users, maker_alive>>

\* The steps of the abort end, or the process that runs them stops.
StepsEnd ==
    /\ steps = "run"
    /\ steps' = "ended"
    /\ UNCHANGED <<aborted, running, owner_alive, live, subs, wants, notified,
                   dropped, stored, users, dep, maker_alive>>

\* After the steps, the process of the signal and the process of the
\* dependent signal stop.
SignalStop ==
    /\ aborted /\ running /\ steps = "ended" /\ Bug # "keeps_after_abort"
    /\ running' = FALSE
    /\ UNCHANGED <<aborted, owner_alive, live, subs, wants, notified, dropped,
                   stored, users, dep, maker_alive, steps>>

DepStop ==
    /\ dep = "aborted" /\ steps = "ended"
    /\ dep' = "stopped"
    /\ UNCHANGED <<aborted, running, owner_alive, live, subs, wants, notified,
                   dropped, stored, users, maker_alive, steps>>

OwnerStop ==
    /\ owner_alive
    /\ owner_alive' = FALSE
    /\ UNCHANGED <<aborted, running, live, subs, wants, notified, dropped, stored,
                   users, dep, maker_alive, steps>>

\* Client c stops. The signal removes its subscriptions, its listener, and
\* its abort algorithm.
ClientStop(c) ==
    /\ c \in live
    /\ live' = live \ {c}
    /\ subs' = [subs EXCEPT ![c] = 0]
    /\ wants' = [wants EXCEPT ![c] = 0]
    /\ users' = users \ {c}
    /\ UNCHANGED <<aborted, running, owner_alive, notified, dropped, stored, dep,
                   maker_alive, steps>>

MakerStop ==
    /\ maker_alive
    /\ maker_alive' = FALSE
    /\ UNCHANGED <<aborted, running, owner_alive, live, subs, wants, notified,
                   dropped, stored, users, dep, steps>>

\* The linger time of the dependent signal is complete, after its maker
\* stopped: it stops with no abort, and the signal removes it.
DepExpire ==
    /\ dep = "running" /\ ~maker_alive
    /\ dep' = "stopped"
    /\ UNCHANGED <<aborted, running, owner_alive, live, subs, wants, notified,
                   dropped, stored, users, maker_alive, steps>>

\* The linger time of a signal that has no use is complete. The signal
\* stops with no abort. A subscriber at that time sees the stop.
Expire ==
    /\ Open
    /\ IF Bug = "stop_with_subscribers"
          THEN ~owner_alive /\ users = {} /\ dep # "running"
          ELSE Unused
    /\ running' = FALSE
    /\ dropped' = dropped \cup Subscribed
    /\ subs' = NoSubs
    /\ wants' = NoSubs
    /\ UNCHANGED <<aborted, owner_alive, live, notified, stored, users, dep, maker_alive,
                   steps>>

\* The store removes the reason after the linger time.
Sweep ==
    /\ stored
    /\ stored' = FALSE
    /\ UNCHANGED <<aborted, running, owner_alive, live, subs, wants, notified,
                   dropped, users, dep, maker_alive, steps>>

Next ==
    \/ \E c \in Clients :
          Subscribe(c) \/ Unsubscribe(c) \/ Use(c) \/ Unuse(c) \/ ClientStop(c)
    \/ Depend \/ Abort \/ StepsEnd \/ SignalStop \/ DepStop
    \/ OwnerStop \/ MakerStop \/ DepExpire \/ Expire \/ Sweep
    \/ UNCHANGED vars

Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(Expire) /\ WF_vars(Sweep) /\ WF_vars(DepExpire)
    /\ WF_vars(StepsEnd) /\ WF_vars(SignalStop) /\ WF_vars(DepStop)

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
    /\ users \subseteq Clients
    /\ dep \in {"none", "running", "aborted", "stopped"}
    /\ maker_alive \in BOOLEAN
    /\ steps \in {"idle", "run", "ended"}

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

\* A signal that is not aborted stays while its owner is alive, while a
\* client uses it, and while a signal depends on it.
KeptForUse ==
    (~aborted /\ (owner_alive \/ users # {} \/ dep = "running")) => running

\* The process of the signal answers the dispatch of the event while the
\* steps of the abort run.
ServesSteps == steps = "run" => running

\* A signal that stopped does not start again.
StaysStopped == [][~running => ~running']_vars

\* An aborted signal stops after the steps of the abort.
AbortedStops == aborted ~> ~running

\* A signal does not continue after its owner and all its clients. This is
\* false when an unsubscribe does not remove the subscription.
NoOrphan == (~owner_alive /\ live = {} /\ ~maker_alive) ~> ~running

\* A signal with no owner stops after its last subscriber unsubscribes, if
\* no client subscribes again.
NoInterest ==
    /\ ~owner_alive /\ wants = NoSubs /\ users = {} /\ dep # "running"
UnusedStops == NoInterest ~> (~running \/ ~NoInterest)

\* The store does not keep the reason of an abort with no limit.
ReasonIsRemoved == stored ~> ~stored
=============================================================================
