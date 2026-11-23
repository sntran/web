----------------------------- MODULE LazySignal -----------------------------
(* The signal of a Web.Request: a lazy signal that depends on a source     *)
(* signal, for example the signal of an AbortController.                   *)
(*                                                                          *)
(* The Request constructor and clone() give each request a new signal, as  *)
(* the steps "create a dependent abort signal" of the DOM Standard. The    *)
(* struct of that signal has no process. A read (aborted?, reason, and     *)
(* onabort) reads the source, and a subscription goes to the process of    *)
(* the source. Thus Request.new and fetch start no process, and the model  *)
(* has no step for them.                                                   *)
(*                                                                          *)
(* An operation that keeps a state, such as a listener, needs a process.   *)
(* Each copy of the struct can be in a different process, and all the     *)
(* copies are one signal: the process registers itself in a registry, with *)
(* the reference of the signal as its key. The operation of a copy:        *)
(*   1. The copy looks in the registry. With no live process, it starts    *)
(*      one. The new process registers the key before its start continues: *)
(*      thus one start wins, and each other start gets the process of the  *)
(*      winner.                                                            *)
(*   2. The copy keeps the process. The process answers the keep only      *)
(*      after its start, and the lifetime rules do not stop a process that *)
(*      a copy keeps. A process that stopped before the keep did not get   *)
(*      the operation: the copy looks again, while the source is not       *)
(*      aborted.                                                           *)
(*   3. The copy adds its listener, and then it releases the process.      *)
(* In its start, the process adds itself to the dependent signals of the   *)
(* source, and only then it answers a copy. A process that finds the       *)
(* source aborted stops at once: no listener can fire on it.               *)
(*                                                                          *)
(* The source keeps its dependent signals in the sequence in which they     *)
(* were made, as the Standard specifies. The lazy signal L was made before  *)
(* the signal E of AbortSignal.any/1, which the model can make at each     *)
(* time. Thus the process of L goes before E in the list, also when it      *)
(* starts after E.                                                         *)
(*                                                                          *)
(* The abort of the source marks its dependent signals. Then the process   *)
(* that aborts fires the event "abort" at each one, in the sequence of the *)
(* list. A marked process stops after its event.                           *)
(*                                                                          *)
(* The process stops as each signal does: when its owner (the copy that    *)
(* started it) stopped, and it has no listener, and no copy keeps it; or   *)
(* after its abort.                                                        *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one *)
(* rule of the design. The value "eager" is the simple design that the     *)
(* owner refused: the constructor starts the process.                      *)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Copies,     \* the processes that have a copy of the struct
    MaxGen,     \* the largest number of processes that start for the signal
    Bug         \* "none", or the name of a rule to remove

VARIABLES
    src,        \* the source signal: "open" or "aborted"
    pstate,     \* pstate[g] is the state of process g: "none", "init",
                \* "run", "aborted", or "stopped"
    key,        \* the process that has the key in the registry, or 0
    owner,      \* owner[g] is the copy that started process g
    deps,       \* the dependent signals of the source, in their sequence:
                \* 0 is the signal E, and g > 0 is process g
    e,          \* the signal E: "none", "run", "aborted", or "stopped"
    live,       \* the copies that are alive
    pc,         \* pc[c] is the step of the operation of copy c
    found,      \* found[c] is the process that copy c uses, or 0
    listeners,  \* listeners[g] is the set of copies with a listener on g
    keepers,    \* keepers[g] is the set of copies that keep process g
    steps,      \* the marked signals that wait for their event, in their
                \* sequence
    fired,      \* the copies whose listener ran
    log         \* the events "abort" at L and at E, in their sequence

vars == <<src, pstate, key, owner, deps, e, live, pc, found, listeners, keepers,
          steps, fired, log>>

Gens == 1..MaxGen
Steps == {"idle", "look", "start", "keep", "add", "release", "done"}
NoCopies == [g \in Gens |-> {}]

Alive(g) == g \in Gens /\ pstate[g] \in {"init", "run", "aborted"}
Started == {g \in Gens : pstate[g] # "none"}
InDeps(g) == \E i \in 1..Len(deps) : deps[i] = g

Init ==
    /\ src = "open"
    /\ pstate = [g \in Gens |-> IF Bug = "eager" /\ g = 1 THEN "run" ELSE "none"]
    /\ key = IF Bug = "eager" THEN 1 ELSE 0
    /\ owner = [g \in Gens |-> CHOOSE c \in Copies : TRUE]
    /\ deps = IF Bug = "eager" THEN <<1>> ELSE <<>>
    /\ e = "none"
    /\ live = Copies
    /\ pc = [c \in Copies |-> "idle"]
    /\ found = [c \in Copies |-> 0]
    /\ listeners = NoCopies
    /\ keepers = NoCopies
    /\ steps = <<>>
    /\ fired = {}
    /\ log = <<>>

-----------------------------------------------------------------------------
\* The operation of a copy, for example add_event_listener/4.

Begin(c) ==
    /\ c \in live /\ pc[c] = "idle"
    /\ pc' = [pc EXCEPT ![c] = "look"]
    /\ UNCHANGED <<src, pstate, key, owner, deps, e, live, found, listeners,
                   keepers, steps, fired, log>>

UsesRegistry == Bug # "no_registry"

\* The look in the registry.
Look(c) ==
    /\ c \in live /\ pc[c] = "look"
    /\ IF UsesRegistry /\ Alive(key)
          THEN /\ found' = [found EXCEPT ![c] = key]
               /\ pc' = [pc EXCEPT ![c] = "keep"]
          ELSE /\ pc' = [pc EXCEPT ![c] = "start"]
               /\ UNCHANGED found
    /\ UNCHANGED <<src, pstate, key, owner, deps, e, live, listeners, keepers,
                   steps, fired, log>>

\* The start of a process. The new process registers the key before its
\* start continues. When a live process has the key, the start gives that
\* process.
Start(c) ==
    /\ c \in live /\ pc[c] = "start"
    /\ IF UsesRegistry /\ Alive(key)
          THEN /\ found' = [found EXCEPT ![c] = key]
               /\ UNCHANGED <<pstate, key, owner>>
          ELSE LET g == Cardinality(Started) + 1 IN
               /\ g <= MaxGen
               /\ pstate' = [pstate EXCEPT ![g] = "init"]
               /\ key' = g
               /\ owner' = [owner EXCEPT ![g] = c]
               /\ found' = [found EXCEPT ![c] = g]
    /\ pc' = [pc EXCEPT ![c] = "keep"]
    /\ UNCHANGED <<src, deps, e, live, listeners, keepers, steps, fired, log>>

\* The keep. The call waits for the end of the start of the process. A
\* process that stopped did not get the keep: the copy looks again, while
\* the source is not aborted.
Keep(c) ==
    /\ c \in live /\ pc[c] = "keep"
    /\ LET g == found[c] IN
       /\ pstate[g] # "init"
       /\ IF Bug = "no_keep"
             THEN /\ pc' = [pc EXCEPT ![c] = "add"]
                  /\ UNCHANGED keepers
          ELSE IF pstate[g] \in {"run", "aborted"}
             THEN /\ keepers' = [keepers EXCEPT ![g] = @ \cup {c}]
                  /\ pc' = [pc EXCEPT ![c] = "add"]
          ELSE /\ pc' = [pc EXCEPT ![c] =
                    IF Bug = "no_retry" \/ (src = "aborted" /\ Bug # "retry_when_aborted")
                       THEN "done"
                       ELSE "look"]
               /\ UNCHANGED keepers
    /\ UNCHANGED <<src, pstate, key, owner, deps, e, live, found, listeners, steps,
                   fired, log>>

\* The add of the listener. A process that stopped does not get it.
Add(c) ==
    /\ c \in live /\ pc[c] = "add"
    /\ LET g == found[c] IN
       /\ pstate[g] # "init"
       /\ listeners' = IF pstate[g] \in {"run", "aborted"}
                          THEN [listeners EXCEPT ![g] = @ \cup {c}]
                          ELSE listeners
    /\ pc' = [pc EXCEPT ![c] = "release"]
    /\ UNCHANGED <<src, pstate, key, owner, deps, e, live, found, keepers, steps,
                   fired, log>>

Release(c) ==
    /\ c \in live /\ pc[c] = "release"
    /\ keepers' = [keepers EXCEPT ![found[c]] = @ \ {c}]
    /\ pc' = [pc EXCEPT ![c] = "done"]
    /\ UNCHANGED <<src, pstate, key, owner, deps, e, live, found, listeners, steps,
                   fired, log>>

\* Copy c stops. Its listeners go away, and it keeps no process.
CopyStop(c) ==
    /\ c \in live
    /\ live' = live \ {c}
    /\ listeners' = [g \in Gens |-> listeners[g] \ {c}]
    /\ keepers' = [g \in Gens |-> keepers[g] \ {c}]
    /\ UNCHANGED <<src, pstate, key, owner, deps, e, pc, found, steps, fired, log>>

-----------------------------------------------------------------------------
\* The process of the signal

\* The process adds itself to the dependent signals of the source, in the
\* sequence in which the signals were made: L was made before E.
WithDep(g) == IF Bug = "order_by_start" THEN Append(deps, g) ELSE <<g>> \o deps

\* The start of process g continues: the process adds itself to the
\* dependent signals of the source, and then it answers the copies. A
\* process that finds the source aborted stops.
Ready(g) ==
    /\ pstate[g] = "init"
    /\ IF src = "open"
          THEN /\ pstate' = [pstate EXCEPT ![g] = "run"]
               /\ deps' = WithDep(g)
          ELSE /\ pstate' = [pstate EXCEPT ![g] =
                    IF Bug = "init_ignores_aborted" THEN "run" ELSE "stopped"]
               /\ UNCHANGED deps
    /\ UNCHANGED <<src, key, owner, e, live, pc, found, listeners, keepers, steps,
                   fired, log>>

\* The process has no use. Its key stays in the registry until a new
\* process takes it: a look gives only a live process.
Unused(g) ==
    /\ owner[g] \notin live
    /\ listeners[g] = {}
    /\ (keepers[g] = {} \/ Bug = "stop_with_keeper")

Expire(g) ==
    /\ pstate[g] = "run" /\ Unused(g) /\ Bug # "no_expire"
    /\ pstate' = [pstate EXCEPT ![g] = "stopped"]
    /\ deps' = SelectSeq(deps, LAMBDA d : d # g)
    /\ UNCHANGED <<src, key, owner, e, live, pc, found, listeners, keepers, steps,
                   fired, log>>

\* With "stop_at_mark", a marked process stops before its event.
EarlyStop(g) ==
    /\ Bug = "stop_at_mark" /\ pstate[g] = "aborted"
    /\ pstate' = [pstate EXCEPT ![g] = "stopped"]
    /\ UNCHANGED <<src, key, owner, deps, e, live, pc, found, listeners, keepers,
                   steps, fired, log>>

-----------------------------------------------------------------------------
\* The source and the signal E

\* AbortSignal.any/1 makes the signal E from the source.
MakeE ==
    /\ src = "open" /\ e = "none"
    /\ e' = "run"
    /\ deps' = Append(deps, 0)
    /\ UNCHANGED <<src, pstate, key, owner, live, pc, found, listeners, keepers,
                   steps, fired, log>>

Running(d) == IF d = 0 THEN e = "run" ELSE pstate[d] = "run"

\* The abort of the source marks each dependent signal that runs. The
\* process that aborts gets the list of the marked signals.
Abort ==
    /\ src = "open"
    /\ src' = "aborted"
    /\ LET marked == SelectSeq(deps, Running) IN
       /\ steps' = marked
       /\ pstate' = [g \in Gens |-> IF \E i \in 1..Len(marked) : marked[i] = g
                                       THEN "aborted"
                                       ELSE pstate[g]]
    /\ e' = IF e = "run" THEN "aborted" ELSE e
    /\ deps' = <<>>
    /\ UNCHANGED <<key, owner, live, pc, found, listeners, keepers, fired, log>>

\* The process that aborts fires the event "abort" at the next marked
\* signal. The listeners of a process run, and then the process stops.
Fire ==
    /\ steps # <<>>
    /\ LET d == Head(steps) IN
       IF d = 0
          THEN /\ e' = "stopped"
               /\ log' = Append(log, "E")
               /\ UNCHANGED <<pstate, fired>>
          ELSE /\ fired' = IF pstate[d] = "aborted"
                              THEN fired \cup (listeners[d] \cap live)
                              ELSE fired
               /\ pstate' = [pstate EXCEPT ![d] = "stopped"]
               /\ log' = Append(log, "L")
               /\ UNCHANGED e
    /\ steps' = Tail(steps)
    /\ UNCHANGED <<src, key, owner, deps, live, pc, found, listeners, keepers>>

-----------------------------------------------------------------------------

CopyActions(c) == Look(c) \/ Start(c) \/ Keep(c) \/ Add(c) \/ Release(c)

Next ==
    \/ \E c \in Copies : Begin(c) \/ CopyActions(c) \/ CopyStop(c)
    \/ \E g \in Gens : Ready(g) \/ Expire(g) \/ EarlyStop(g)
    \/ MakeE \/ Abort \/ Fire
    \/ UNCHANGED vars

Spec ==
    /\ Init /\ [][Next]_vars
    /\ \A c \in Copies : WF_vars(CopyActions(c))
    /\ \A g \in Gens : WF_vars(Ready(g)) /\ WF_vars(Expire(g)) /\ WF_vars(EarlyStop(g))
    /\ WF_vars(Fire)

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ src \in {"open", "aborted"}
    /\ pstate \in [Gens -> {"none", "init", "run", "aborted", "stopped"}]
    /\ key \in 0..MaxGen
    /\ owner \in [Gens -> Copies]
    /\ deps \in Seq(0..MaxGen)
    /\ e \in {"none", "run", "aborted", "stopped"}
    /\ live \subseteq Copies
    /\ pc \in [Copies -> Steps]
    /\ found \in [Copies -> 0..MaxGen]
    /\ listeners \in [Gens -> SUBSET Copies]
    /\ keepers \in [Gens -> SUBSET Copies]
    /\ steps \in Seq(0..MaxGen)
    /\ fired \subseteq Copies
    /\ log \in Seq({"L", "E"})

\* All the copies use one process: two copies that start a process at the
\* same time get the same process.
OneProcess == Cardinality({g \in Gens : Alive(g)}) <= 1

\* A process starts only for an operation that needs one. A read, the
\* constructor, and fetch start no process.
LazyStart == Started # {} => \E c \in Copies : pc[c] # "idle"

\* A process answers the copies only while it is a dependent signal of a
\* source that is not aborted. Thus the abort of the source reaches each
\* listener of the process.
RunningIsDependent == \A g \in Gens : pstate[g] = "run" => src = "open" /\ InDeps(g)

\* The events fire in the sequence in which the signals were made.
EventOrder == \A i, j \in 1..Len(log) : (log[i] = "L" /\ log[j] = "E") => i < j

\* An operation that ends while the source is not aborted has its effect:
\* the listener is on a process.
OpTakesEffect ==
    [][\A c \in Copies :
         (pc[c] # "done" /\ pc'[c] = "done" /\ src = "open")
            => \E g \in Gens : c \in listeners'[g]]_vars

\* A marked process stops only after the listeners of its copies ran.
FiresBeforeStop ==
    [][\A g \in Gens :
         (pstate[g] = "aborted" /\ pstate'[g] = "stopped")
            => (listeners[g] \cap live) \subseteq fired']_vars

\* Each operation ends, or its copy stops.
AddEnds ==
    \A c \in Copies :
        (pc[c] \in {"look", "start", "keep", "add", "release"})
            ~> (pc[c] = "done" \/ c \notin live)

\* After the abort of the source, each process of the signal stops.
AbortedStops == (src = "aborted") ~> (\A g \in Gens : pstate[g] \in {"none", "stopped"})

\* A process does not continue after all the copies.
NoOrphan == (live = {}) ~> (\A g \in Gens : pstate[g] \in {"none", "stopped"})
=============================================================================
