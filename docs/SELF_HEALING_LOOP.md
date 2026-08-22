# The Self-Healing Loop

*A companion to `FINANCIAL_DOCTRINE.md`. The doctrine governs how a money value
is produced and narrated. This governs what happens **after** execution — when
the system observes the world and finds it does not match what it expected.
Same law, one step further: **the agent never decides it succeeded. The world
state, the invariants, and the verifier decide.***

Status: **DESIGN** (PROTOTYPE-in-planning). Nothing here is built except the
degenerate verifier noted below. This file exists so the architecture survives,
and so a reviewer can ask of any future diff: *does this violate the loop?*

---

## Why the loop belongs after execution

Self-healing is only meaningful once there is something objective to compare
against. Before execution the system has *intent*; after execution it has a
*result* and it can *observe actual state*. The gap between the two is the only
honest trigger for repair.

The failure mode we are refusing: **"the LLM noticed something weird and rewrote
some code."** That is not self-healing — it is an agent with unilateral
authority asking itself whether it succeeded. We replace the agent's opinion
with an objective contradiction.

---

## The stack

Probabilistic at the edges, deterministic and symbolic in the core, ML fenced
to the two fuzzy jobs it is actually good at (reading messy reality; proposing
candidates when the machinery is stuck).

```
LLM / vision                → messy reality              (probabilistic)
   ↓
symbolic representation     → meaning / state            (ELIZA/SHRDLU-lineage)
   ↓
STRIPS-like actions         → preconditions / effects
   ↓
truth-maintenance system    → what became invalid when a dependency changed
   ↓
deterministic primitives    → execution                  (the registry)
   ↓
PEEL / provenance           → observe exactly what occurred
   ↓
self-healing loop           → discrepancy → diagnosis → repair → verification
   ↓
LLM                         → propose a repair ONLY when deterministic
                              machinery cannot resolve the discrepancy
```

Read top-to-bottom for a run; the loop closes bottom back to the symbolic layer.

---

## The loop

```
human intent
   → LLM interprets messy intent          (probabilistic — may misread)
   → symbolic layer constructs task/state AND an EXPECTED invariant set
   → Jeeves evaluates taught rules
   → PEEL executes / traces
   → deterministic result                 (e.g. payroll.total = 100)
   → observer reads ACTUAL world state
   → EXPECTED == ACTUAL ?
        YES → continue
        NO  → objective contradiction: EXPECTED=100, ACTUAL=70
              → ML unleashed on the FUZZY questions only:
                  why did this happen? which component? what repair?
              → candidate repair
              → sandbox / simulation
              → tests
              → symbolic invariants
              → EXPECTED == ACTUAL ?  → accept, else discard + retry/escalate
```

ML never gets the `accept`. It proposes; the verifier decides. `approve` /
`disburse` / `change` stay gated even when agents chain
`search → compare → trace → explain → repair` autonomously.

---

## The keystone: EXPECTED must be first-class

The loop is impossible until the **symbolic layer emits an expected state** —
not the final signed number, but the *invariants that must hold*:

```
EXPECTED: payroll.total == sum(line.hours * line.rate)
EXPECTED: no line unit_price exceeds its taught floor max
EXPECTED: stated_total == sum(reconstructed line totals)
```

With EXPECTED as data, the observer can catch divergence **mid-flight**, not
only at receipt-verify time; and a repair can be checked against a concrete
target instead of the model's self-assessment. Without it, the only thing the
system "expects" is the receipt itself — which is why today it can only detect
damage after the fact.

**This is the first brick to build.** Everything below depends on it.

---

## Truth maintenance, not re-reading the world

When a value changes, the system must know *what it invalidated* — cheaply and
symbolically — instead of asking an LLM to vaguely re-read everything.

If the substrate knows `A depends on B`, `B depends on C`, and `C changed`, then
only the beliefs downstream of C are marked stale and re-evaluated. This is a
classical truth-maintenance / dependency-directed system, and it is the honest
alternative to "invalidate the world and let the model sort it out."

The receipt is already a flat version of this: its hashed inputs (scans,
pricebook, floor rules) are the dependency set for the authoritative result.
A dependency **graph** generalizes it — edges between derived beliefs, not just
inputs-to-result.

---

## What already exists (the degenerate verifier)

`verify` (the primitive) is a one-node instance of this whole loop:

| loop concept            | today, in `verify`                                    |
|-------------------------|-------------------------------------------------------|
| dependency set          | the receipt's hashed inputs                            |
| EXPECTED                | the signed result + input hashes                      |
| observe ACTUAL          | re-hash the files, re-check the signature             |
| contradiction           | `scan-hash-changed`, `receipt-signature-invalid`, …   |
| invalidation classifier | the doctrine's four legal causes of change            |
| authority               | deterministic; ML never touches the verdict           |

It has no EXPECTED richer than the signed record, no dependency **graph**, and
no diagnose→repair arc. Those are the build-outs — but the boundary, the
fail-closed named contradictions, and the "verifier holds authority" property
are already real and tested. We extend this node; we do not invent a new one.

---

## Build order (do not skip, do not rush)

1. ✅ **DONE** — **Symbolic layer emits an `expected` invariant block** into the
   receipt (`invariants.py`, schema v3); `verify` re-proves it and graduates from
   "hashes match" to "invariants hold." A re-signed tamper is caught by the
   invariant even though the forged signature is valid. Three kinds pinned:
   line-arithmetic, invoice-reconcile, floor-max-unit-price.
2. **Observer** reads ACTUAL state and reports EXPECTED≠ACTUAL as named
   contradictions (reuse the reason-code discipline).
3. **Dependency graph** (TMS): edges between beliefs; a changed node marks only
   its descendants stale.
4. **Diagnose → candidate repair → sandbox → tests → invariants → accept**, with
   ML scoped strictly to *propose* and the verifier holding `accept`.
5. Only then does the loop run autonomously — and even then, money-gated actions
   remain gated.

---

## Enforcement

Like the doctrine, this is a **contract**. A reviewer — Codex, DeepSeek,
verify-eng, or a human — should be able to answer, of any diff that touches the
loop:

> **Does this let ML decide `accept`? Does a money result change without the
> trace naming which of the four causes moved it? Does repair bypass the
> verifier? Show evidence.**

A "no evidence" answer is an incomplete review, not a pass.
