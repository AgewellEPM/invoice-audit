"""kist research adapter — the ONLY probabilistic step in the benchmark path.

Luke's directive: "make sure the kist framework is running the research using
the best models cross-comparing." So market pricing is researched by shelling
the real `kist` binary — `kist --dig` asks every reachable model the same
question and synthesizes an agree/disagree answer; `kist --research` runs an
evidence dossier. Either way the OUTPUT is treated exactly like the pricebook:
a *reference input*, never a money decision. The deterministic comparison in
`pricebook.py`/`benchmark.py` is what actually flags an overpay.

Fail-closed, named reasons: if kist is missing, times out, exits non-zero, or
returns something we cannot parse into a price, we return a `KistResearchError`
with a machine-readable reason code — we NEVER invent a market price from a
garbled run. That would be the exact sin the whole engine exists to prevent.

Offline / test / reproducible-demo determinism: set
`INVOICE_AUDIT_KIST_FIXTURE=<path.json>` to a JSON map of
`"<sku>|<description>" -> {unit_price_usd, low_usd, high_usd, confidence,
sources, models}`. When a fixture is used the provenance says so — an honest
result is never dressed up as a live cross-model run.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from dataclasses import dataclass, field, asdict
from pathlib import Path

# How the kist framework runs the research. `dig` = ask every reachable model
# and synthesize agree/disagree (Luke's "best models cross-comparing").
KIST_MODES = ("dig", "research")
DEFAULT_MODE = "dig"
DEFAULT_TIMEOUT_S = float(os.environ.get("INVOICE_AUDIT_KIST_TIMEOUT", "240"))


class KistResearchError(Exception):
    """Raised with a named `reason` so callers can fail closed, not guess."""

    def __init__(self, reason: str, detail: str = ""):
        self.reason = reason
        self.detail = detail
        super().__init__(f"{reason}: {detail}" if detail else reason)


@dataclass(frozen=True)
class MarketQuote:
    """One researched, cross-compared market price for a single item.

    This is a *reference estimate with provenance* — not ground truth. The
    caller writes `unit_price_usd` into a PriceBook-shaped CSV and lets the
    deterministic checker decide overpay; everything else is kept for the
    receipt so the research is auditable and re-runnable.
    """
    sku: str
    description: str
    region: str
    unit_price_usd: float          # median — the number the checker compares to
    low_usd: float
    high_usd: float
    confidence: float              # 0..1, as reported by the research
    models_consulted: list[str] = field(default_factory=list)
    sources: list[str] = field(default_factory=list)
    notes: str = ""
    kist_mode: str = DEFAULT_MODE
    provenance: str = "kist-live"  # or "fixture"
    as_of: str = ""

    def to_dict(self) -> dict:
        return asdict(self)


def _kist_bin() -> str:
    return os.environ.get("INVOICE_AUDIT_KIST_BIN", "kist")


def kist_available() -> bool:
    """True when the kist binary is resolvable — cheap, no token spend."""
    return shutil.which(_kist_bin()) is not None


def _fixture_map() -> dict | None:
    path = os.environ.get("INVOICE_AUDIT_KIST_FIXTURE")
    if not path:
        return None
    p = Path(path)
    if not p.exists():
        raise KistResearchError("kist-fixture-missing", str(p))
    try:
        return json.loads(p.read_text())
    except json.JSONDecodeError as e:
        raise KistResearchError("kist-fixture-bad-json", str(e)) from e


def _fixture_key(sku: str, description: str) -> str:
    return f"{sku.strip()}|{description.strip()}".strip("|")


def _prompt(sku: str, description: str, region: str) -> str:
    ident = " / ".join(part for part in (sku.strip(), description.strip()) if part)
    return (
        "You are a procurement price researcher. Research the current fair-market "
        f"UNIT price in USD that a commercial buyer in {region} would pay for this "
        f"item: {ident}. Cross-compare multiple independent sources and models. "
        "Respond with ONLY a single fenced ```json block, no prose, of the exact "
        'shape: {"unit_price_usd": <median number>, "low_usd": <number>, '
        '"high_usd": <number>, "confidence": <0..1>, "models": [<string>...], '
        '"sources": [<url string>...], "notes": <short string>}. '
        "unit_price_usd MUST be the median fair market unit price. If you cannot "
        'find a defensible price, return {"unit_price_usd": null} and nothing else.'
    )


_JSON_FENCE = re.compile(r"```(?:json)?\s*(\{.*?\})\s*```", re.DOTALL)


def _extract_json(stdout: str) -> dict:
    """Pull the LAST JSON object out of kist's stream — synthesis comes last."""
    blocks = _JSON_FENCE.findall(stdout)
    if not blocks:
        # Fall back to the last bare {...} object in the stream.
        bare = re.findall(r"\{[^{}]*\"unit_price_usd\"[^{}]*\}", stdout, re.DOTALL)
        blocks = bare
    if not blocks:
        raise KistResearchError("kist-no-json", stdout[-400:])
    try:
        return json.loads(blocks[-1])
    except json.JSONDecodeError as e:
        raise KistResearchError("kist-bad-json", str(e)) from e


def _quote_from_payload(sku: str, description: str, region: str, mode: str,
                        payload: dict, provenance: str, as_of: str) -> MarketQuote:
    raw = payload.get("unit_price_usd", None)
    if raw is None:
        raise KistResearchError("kist-missing-price", f"{sku}|{description}")
    try:
        median = float(raw)
    except (TypeError, ValueError) as e:
        raise KistResearchError("kist-bad-price", str(raw)) from e
    if median <= 0:
        raise KistResearchError("kist-nonpositive-price", str(median))

    def _num(key: str, fallback: float) -> float:
        try:
            return float(payload.get(key, fallback))
        except (TypeError, ValueError):
            return fallback

    low = _num("low_usd", median)
    high = _num("high_usd", median)
    conf = max(0.0, min(1.0, _num("confidence", 0.0)))
    models = [str(m) for m in payload.get("models", []) if str(m).strip()]
    sources = [str(s) for s in payload.get("sources", []) if str(s).strip()]
    return MarketQuote(
        sku=sku, description=description, region=region,
        unit_price_usd=round(median, 2),
        low_usd=round(min(low, median), 2),
        high_usd=round(max(high, median), 2),
        confidence=round(conf, 3),
        models_consulted=models, sources=sources,
        notes=str(payload.get("notes", ""))[:400],
        kist_mode=mode, provenance=provenance, as_of=as_of,
    )


def research_price(sku: str, description: str, *, region: str = "United States",
                   mode: str = DEFAULT_MODE,
                   timeout_s: float = DEFAULT_TIMEOUT_S,
                   as_of: str = "") -> MarketQuote:
    """Research one item's market unit price via kist (or the fixture).

    Raises KistResearchError(reason=...) on any failure — fail closed.
    """
    if mode not in KIST_MODES:
        raise KistResearchError("kist-bad-mode", mode)

    fixture = _fixture_map()
    if fixture is not None:
        entry = fixture.get(_fixture_key(sku, description))
        if entry is None:
            raise KistResearchError("kist-fixture-no-entry", _fixture_key(sku, description))
        return _quote_from_payload(sku, description, region, mode, entry,
                                   provenance="fixture", as_of=as_of)

    if not kist_available():
        raise KistResearchError("kist-binary-not-found", _kist_bin())

    cmd = [_kist_bin(), f"--{mode}", _prompt(sku, description, region)]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True,
                              timeout=timeout_s)
    except subprocess.TimeoutExpired as e:
        raise KistResearchError("kist-timeout", f"{timeout_s}s") from e
    except OSError as e:
        raise KistResearchError("kist-spawn-failed", str(e)) from e
    if proc.returncode != 0:
        raise KistResearchError("kist-nonzero-exit",
                                f"rc={proc.returncode} {proc.stderr[-300:]}")
    payload = _extract_json(proc.stdout)
    return _quote_from_payload(sku, description, region, mode, payload,
                               provenance="kist-live", as_of=as_of)
