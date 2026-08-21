# The Doctrine

*The governing design law of invoice-audit / Financial Ops Copilot — and every
money brick in the dark-factory suite it seeds. If a change violates a line
here, the change is wrong, not the doctrine.*

---

## The five lines

> **Intent can be probabilistic.**
> **Discovery can be probabilistic.**
> **Narration can be probabilistic.**
> **Financial truth cannot be probabilistic.**
> **Every transition from probabilistic → authoritative must cross an inspectable evidence boundary.**

An LLM may *guess what you meant*, *find candidates worth looking at*, and
*describe a result in words*. It may never *decide, produce, or restate a
financial value as authoritative*. Between the probabilistic world and the
authoritative one there is always a boundary a human can inspect — a receipt, a
trace, a signed record. Nothing crosses it invisibly.

---

## Law 1 — No ML touches money

The money path is deterministic and symbolic, end to end.

- **ML is the librarian.** It may *retrieve* — "let me fetch that" — and hand the
  value over. It never reasons about, decides, or edits a money value.
  *Forbidden:* "I don't like the name Bruno, pay him $70." *Correct:* SQL says
  Bruno = $100, no override exists, no taught rule says otherwise → pay $100.
- **Deterministic + symbolic decide.** The source-of-record data (SQL), the
  arithmetic gate, and the symbolic floor (Jeeves — taught rules with mandatory
  source + evidence) produce the number. PEEL / SQL-trace carries the lineage.
- **Every money number carries a provenance receipt:** *this value came from this
  place, at this time; here is what we found.* No provenance → not a money number.
- **Numbers change only two ways:** a human-in-the-loop edits them, or enough
  grounded evidence accumulates that *probabilistic math* (statistics, not an
  LLM's opinion) shows the pattern shifted. Otherwise: same answer every round.
- **ML output that informs a money view is a review signal, never banked.**
  (The kist-researched industry benchmark is surfaced, labeled *"estimate — not
  banked,"* and never enters the money figure.)

---

## The stability invariant

> **Same grounded inputs + same rules = same authoritative result.**

Run the money path twice on the same source data and the same rule versions and
it returns the identical authoritative value — every round, no drift. If the
result *does* change, the **trace must show exactly what changed**, and it can
only be one of four things:

1. a **human override** (who, when),
2. the **source data** (which rows, new timestamps),
3. the **rule version** (which taught rule / floor changed, and its evidence),
4. an **approved statistical / evidence update** (probabilistic math crossed its
   threshold — never an LLM's opinion).

If a money result changes and the trace cannot name which of these four caused
it, that is a corruption, not an update. Reject it.

---

## Law 2 — The REPL is the operator surface, never the authority

The rule from Law 1 applies **twice** — at computation *and* at narration. An
LLM is not trusted merely because it correctly *described* a financial result.

Runtime authority boundary:

```
human language
   → intent parser        (probabilistic — may misread)
   → approved primitives  (deterministic — perform the work)
   → deterministic systems authorize money   (SQL / arithmetic / Jeeves)
   → PEEL proves what happened                (trace + provenance)
   → REPL narrates it — AND shows the receipt for every claim it makes
```

The REPL is **boring underneath.** It never "reasons up" an answer; it calls
existing primitives and reads the result back. Because the narration is itself
an LLM, the substrate is always shown next to the prose:

> **"Bruno was paid $100 because he worked 5 hours at $20/hour."**
>
> ```
> payroll.lookup(bruno)   → 5.0 hours
> rate.lookup(bruno)      → $20.00/hour
> jeeves.evaluate(rules)  → $100.00
> peel.trace(payment_id)  → source rows + timestamps
> authorized result       → $100.00
> ```

The prose is convenience. **The records are the truth.** If the model
mistranslates the result, the operator sees the mismatch immediately.

Safety by construction:
- **Read-only is an enforced capability scope, not a prompt.** A read-only
  session is handed a toolset containing only read primitives, so a misparsed
  intent physically cannot mutate. An LLM that can only reach read/gated tools
  cannot do damage even when it hallucinates the intent.
- **`approve` / `disburse` / `change` stay gated** even when agents chain
  `search → compare → trace → explain` autonomously.

---

## How a function becomes a primitive

Do **not** invent a grand registry because it sounds clean. Promote by evidence.

The signal: *"I've already built this action three different ways in three
different screens."* Search the actual code; count independent implementations.
An operation implemented ≥3 ways has proven it's a real **concept** in the
system, not a temporary implementation detail. Extract it once; make the screens
call it.

Stable behavior earns abstraction. Changing behavior stays local — never
crystallize a primitive whose semantics you settled this week.

Progression (don't skip, don't rush):
`functions work → tool-addressable → provenance on every action → enforced gates
→ expose the REPL → agents chain autonomously.`
Exposing the REPL is where it starts to feel like kist instead of an app.

---

## Enforcement

This file is a **contract**, not documentation. It is meant to be checked
against, continuously, by humans and by the synthetic review team. A reviewer —
Codex, DeepSeek, verify-eng, or a human — should be able to be asked, of any
diff:

> **Does this diff violate `FINANCIAL_DOCTRINE.md`? Show evidence.**

and answer from the specific lines above. A "no evidence" answer is not a pass;
it is an incomplete review. The doctrine is only real if the team tests itself
against it every round.

---

*Repetition audit, 2026-08-21 — earned promotion: `verify`, `trace`;
deterministic-core promotion: `compare`, `search`. Held (still moving or not yet
a concept): `benchmark`, `savings`, `explain`, `export`.*

*Honest note on `verify`: promoted as the registry TEMPLATE with two live
consumers (CLI + Swift) sharing one contract, plus the REPL to come — the
"≥3 ways" bar is counted as consumers/narrations, not three independent
re-derivations. Stable behavior (one deterministic core, many surfaces) is what
earned it.*
