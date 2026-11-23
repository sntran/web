----------------------------- MODULE Performance -----------------------------
(* The marks and the measures of Web.Performance for one process.           *)
(*                                                                          *)
(* The module shows the entries after each call, as the User Timing         *)
(* Standard specifies. The clock is a counter: each call that reads the     *)
(* time gets a new, larger value.                                           *)
(*                                                                          *)
(* The constant Bug is "none" for the design. Each other value removes one  *)
(* rule of the design.                                                      *)
EXTENDS Naturals, Sequences

CONSTANTS
    Names,       \* the names of the entries
    MaxClock,    \* the largest value of the clock
    MaxEntries,  \* the largest number of entries
    Bug          \* "none", or the name of a rule to remove

VARIABLES
    clock,    \* the time now. The time origin is 0
    entries,  \* the entries, in the sequence of the calls
    last      \* the last call, and its result

vars == <<clock, entries, last>>

None == "none"
Moments == Names \cup {None}

Entry(name, type, start, finish) ==
    [name |-> name, type |-> type, start |-> start, finish |-> finish]

Call(op, ok, from, had_marks) ==
    [op |-> op, ok |-> ok, from |-> from, had_marks |-> had_marks]

Init ==
    /\ clock = 0
    /\ entries = <<>>
    /\ last = Call("none", TRUE, None, TRUE)

\* The positions of the marks with a name.
Marks(name) ==
    {i \in 1..Len(entries) : entries[i].type = "mark" /\ entries[i].name = name}

HasMark(name) == Marks(name) # {}

\* The first design looked at the last entry with the name, of each type.
\* A measure with the name of a mark made the mark impossible to find.
Entries(name) == {i \in 1..Len(entries) : entries[i].name = name}
Last(set) == CHOOSE i \in set : \A j \in set : j <= i
First(set) == CHOOSE i \in set : \A j \in set : i <= j

Finds(name) ==
    IF Bug = "measure_hides_mark"
    THEN Entries(name) # {} /\ entries[Last(Entries(name))].type = "mark"
    ELSE HasMark(name)

\* The time of the mark that was made last with a name.
MarkTime(name) ==
    IF Bug = "measure_uses_first_mark"
    THEN entries[First(Marks(name))].start
    ELSE entries[Last(Marks(name))].start

\* mark makes an entry at the time now.
Mark(name) ==
    /\ name \in Names /\ clock < MaxClock /\ Len(entries) < MaxEntries
    /\ clock' = clock + 1
    /\ entries' = Append(entries, Entry(name, "mark", clock + 1, clock + 1))
    /\ last' = Call("mark", TRUE, None, TRUE)

\* measure makes an entry from a mark, or from the time origin, to a mark,
\* or to the time now. A mark that does not exist is an error: the call
\* adds no entry.
Measure(name, from, to) ==
    /\ name \in Names /\ from \in Moments /\ to \in Moments
    /\ Len(entries) < MaxEntries
    /\ to = None => clock < MaxClock
    /\ LET had == (from = None \/ HasMark(from)) /\ (to = None \/ HasMark(to))
           ok == (from = None \/ Finds(from)) /\ (to = None \/ Finds(to))
           start == IF from = None THEN 0 ELSE MarkTime(from)
           finish == IF to = None THEN clock + 1 ELSE MarkTime(to)
       IN  /\ last' = Call("measure", ok, from, had)
           /\ IF ok
              THEN /\ entries' = Append(entries, Entry(name, "measure", start, finish))
                   /\ clock' = IF to = None THEN clock + 1 ELSE clock
              ELSE UNCHANGED <<clock, entries>>

Keeps(type, name, entry) ==
    ~(entry.type = type /\ (name = None \/ entry.name = name))

\* clear_marks removes the marks with a name, or all the marks.
ClearMarks(name) ==
    /\ name \in Moments
    /\ entries' =
         IF Bug = "clear_marks_removes_measures"
         THEN SelectSeq(entries, LAMBDA e : name # None /\ e.name # name)
         ELSE SelectSeq(entries, LAMBDA e : Keeps("mark", name, e))
    /\ last' = Call("clear_marks", TRUE, None, TRUE)
    /\ UNCHANGED clock

\* clear_measures removes the measures with a name, or all the measures.
ClearMeasures(name) ==
    /\ name \in Moments
    /\ entries' = SelectSeq(entries, LAMBDA e : Keeps("measure", name, e))
    /\ last' = Call("clear_measures", TRUE, None, TRUE)
    /\ UNCHANGED clock

Next ==
    \/ \E name \in Names : Mark(name)
    \/ \E name \in Names : \E from \in Moments : \E to \in Moments :
           Measure(name, from, to)
    \/ \E name \in Moments : ClearMarks(name) \/ ClearMeasures(name)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ clock \in 0..MaxClock
    /\ Len(entries) <= MaxEntries
    /\ \A i \in 1..Len(entries) :
           /\ entries[i].name \in Names
           /\ entries[i].type \in {"mark", "measure"}
           /\ entries[i].start \in 0..MaxClock
           /\ entries[i].finish \in 0..MaxClock

OfType(seq, type) == SelectSeq(seq, LAMBDA e : e.type = type)

\* A measure finds each mark that exists, also when a measure has the name
\* of the mark.
MarkIsFound == (last.op = "measure" /\ last.had_marks) => last.ok

\* A measure from a mark starts at the largest time of the marks with that
\* name: the mark that was made last.
MeasureUsesLastMark ==
    (last.op = "measure" /\ last.ok /\ last.from # None) =>
        \A i \in Marks(last.from) : entries[i].start <= entries[Len(entries)].start

\* A mark has no duration, and no entry starts in the future.
TimesAreValid ==
    \A i \in 1..Len(entries) :
        /\ entries[i].type = "mark" => entries[i].start = entries[i].finish
        /\ entries[i].start <= clock /\ entries[i].finish <= clock

\* clear_marks does not change the measures, and clear_measures does not
\* change the marks.
ClearKeepsTheOtherType ==
    [][/\ last'.op = "clear_marks" =>
            OfType(entries', "measure") = OfType(entries, "measure")
       /\ last'.op = "clear_measures" =>
            OfType(entries', "mark") = OfType(entries, "mark")]_vars
=============================================================================
