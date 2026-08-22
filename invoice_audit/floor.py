"""Symbolic floor — human-taught vendor/domain rules that VETO a line the
arithmetic + price checks would wave through.

Why local, not the Perslis Jeeves MCP: the live Jeeves floor is a legacy
COBOL/Windows knowledge graph. Asked an invoice claim it returns
`verdict: unknown, veto: false` ("no checkable relation in the graph") — a veto
that never fires is theater. So this floor implements the SAME Jeeves contract
(teach_relation + check_contradiction) for the invoice domain, where the rules
actually live. It stays deterministic and portable (the demo runs with no MCP
stack), and the contract matches so it can delegate to / merge with the Perslis
floor once that floor is taught invoice relations.

Fail-closed, exactly like teach_relation:
  - KNOWN relation types only — any other type is REFUSED.
  - mandatory source + evidence (provenance) — refused without them.
  - refused on conflict (same subject+relation, different value).
  - idempotent (re-teaching an identical rule is a no-op).
Rules carry provenance into the signed receipt; the rules file is hashed and
re-checked by `verify`, so a receipt pins exactly which rules were in force.

The floor's job is NARROW: given a number we already trust (grounding said so),
is it *allowed*? Grounding answers "did we read it right?"; the floor answers
"is it within policy?". Two different failure modes, kept separate.
"""
from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path

from .layout import LineItem
from .ocr import AuditError

FLOOR_SCHEMA = "invoice-audit.floor.v1"

# A rule of any other type is REFUSED — the floor never guesses a relation.
KNOWN_RELATIONS = {
    "max_unit_price",       # object = dollars; unit_price above it → veto
    "min_unit_price",       # object = dollars; unit_price below it → veto
    "unit_price_positive",  # a charged unit price must be > 0
    "qty_integer",          # discrete goods ship in whole units
}


def _norm(text: str) -> str:
    return re.sub(r"[^A-Z0-9 ]", "", (text or "").upper()).strip()


@dataclass(frozen=True)
class Rule:
    subject: str          # SKU, description, or "*" (applies to every line)
    relation_type: str
    object: str           # numeric string, or "true" for the invariants
    source: str           # WHO taught it (provenance — mandatory)
    evidence: str         # WHY it holds (mandatory)

    @property
    def hash(self) -> str:
        raw = f"{_norm(self.subject)}|{self.relation_type}|{self.object}"
        return hashlib.sha256(raw.encode()).hexdigest()[:16]


class Floor:
    def __init__(self, rules: list[Rule], source: Path | None = None):
        self.source = source
        # index by (subject, relation) so a conflicting VALUE is caught
        self._index: dict[tuple[str, str], Rule] = {}
        for r in rules:
            self._teach(r)
        self.rules = list(self._index.values())

    def _teach(self, r: Rule) -> None:
        if r.relation_type not in KNOWN_RELATIONS:
            raise AuditError(f"floor-unknown-relation:{r.relation_type}")
        if not r.source.strip() or not r.evidence.strip():
            raise AuditError(
                f"floor-missing-provenance:{r.subject}/{r.relation_type}")
        if r.relation_type in ("max_unit_price", "min_unit_price"):
            try:
                float(r.object)
            except ValueError as e:
                raise AuditError(
                    f"floor-bad-object:{r.relation_type}:{r.object}") from e
        key = (_norm(r.subject), r.relation_type)
        existing = self._index.get(key)
        if existing and existing.object != r.object:
            raise AuditError(
                f"floor-conflict:{r.subject}/{r.relation_type} "
                f"{existing.object} vs {r.object}")
        self._index[key] = r  # idempotent: identical rule re-teaches to itself

    @classmethod
    def load(cls, path: Path) -> "Floor":
        if not path.exists():
            raise AuditError(f"floor-rules-missing:{path}")
        try:
            data = json.loads(path.read_text())
        except json.JSONDecodeError as e:
            raise AuditError(f"floor-bad-json:{path.name}:{e}") from e
        if data.get("schema") != FLOOR_SCHEMA:
            raise AuditError(f"floor-wrong-schema:{data.get('schema')}")
        rules: list[Rule] = []
        for row in data.get("rules", []):
            try:
                rules.append(Rule(
                    subject=str(row["subject"]),
                    relation_type=str(row["relation_type"]),
                    object=str(row["object"]),
                    source=str(row["source"]),
                    evidence=str(row["evidence"]),
                ))
            except KeyError as e:
                raise AuditError(f"floor-bad-rule:{row}:{e}") from e
        return cls(rules, path)

    def _applies(self, r: Rule, line: LineItem) -> bool:
        if r.subject == "*":
            return True
        s = _norm(r.subject)
        return s == _norm(line.sku) or s in _norm(line.description)

    @staticmethod
    def _violation(r: Rule, line: LineItem) -> str | None:
        if r.relation_type == "max_unit_price":
            cap = float(r.object)
            if line.unit_price > cap:
                return f"unit {line.unit_price:.2f} exceeds taught max {cap:.2f}"
        elif r.relation_type == "min_unit_price":
            floor_ = float(r.object)
            if line.unit_price < floor_:
                return f"unit {line.unit_price:.2f} below taught min {floor_:.2f}"
        elif r.relation_type == "unit_price_positive":
            if line.unit_price <= 0:
                return f"unit price {line.unit_price:.2f} is not positive"
        elif r.relation_type == "qty_integer":
            if abs(line.qty - round(line.qty)) > 1e-9:
                return f"qty {line.qty} is not a whole number"
        return None

    def check_line(self, line: LineItem) -> dict:
        """Mirror Jeeves check_contradiction: verdict + veto + conflicts.

        contradiction (veto) — a taught rule is violated; the floor overrides.
        consistent           — a rule applied and the line satisfies it.
        unknown              — no taught rule covers this line (floor abstains).
        """
        conflicts = []
        applied = False
        max_caps: list[tuple[float, str]] = []  # (cap, source) for EVERY applied max rule
        for r in self._index.values():
            if not self._applies(r, line):
                continue
            applied = True
            if r.relation_type == "max_unit_price":
                try:
                    max_caps.append((float(r.object), r.source))
                except (TypeError, ValueError):
                    pass
            v = self._violation(r, line)
            if v:
                conflicts.append({
                    "relation_type": r.relation_type, "subject": r.subject,
                    "object": r.object, "source": r.source,
                    "evidence": r.evidence, "detail": v,
                })
        # The most restrictive taught max that applied — recorded on PASSING lines
        # too, so the receipt can carry a floor invariant for EVERY covered line,
        # not just vetoed ones (closes the coverage gap). See build_invariants.
        applied_max = min(max_caps, key=lambda c: c[0]) if max_caps else None
        applied_max_field = ({"object": applied_max[0], "source": applied_max[1]}
                             if applied_max else None)
        if conflicts:
            return {"verdict": "contradiction", "veto": True,
                    "conflicts": conflicts,
                    "appliedMaxUnitPrice": applied_max_field, "floor": FLOOR_SCHEMA}
        return {"verdict": "consistent" if applied else "unknown",
                "veto": False, "conflicts": [],
                "appliedMaxUnitPrice": applied_max_field, "floor": FLOOR_SCHEMA}
