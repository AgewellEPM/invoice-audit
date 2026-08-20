"""OCR stage — run the on-device Vision CLI and return positioned tokens.

Fail-closed: a missing binary or an OCR failure raises AuditError with a
named reason; we never return a fabricated or partial page silently.
"""
from __future__ import annotations

import hashlib
import json
import subprocess
from dataclasses import dataclass
from pathlib import Path

BIN = Path(__file__).resolve().parent.parent / "bin" / "vision-ocr"


class AuditError(RuntimeError):
    """Named, machine-readable failure (message is the reason code)."""


@dataclass(frozen=True)
class Token:
    text: str
    confidence: float
    x: float  # normalized, top-left origin
    y: float
    w: float
    h: float

    @property
    def cx(self) -> float:
        return self.x + self.w / 2

    @property
    def cy(self) -> float:
        return self.y + self.h / 2


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def ocr_image(path: Path) -> list[Token]:
    if not BIN.exists():
        raise AuditError("ocr-binary-missing:bin/vision-ocr (build with scripts/build.sh)")
    if not path.exists():
        raise AuditError(f"scan-missing:{path.name}")
    proc = subprocess.run(
        [str(BIN), str(path)], capture_output=True, text=True, timeout=120
    )
    if proc.returncode != 0:
        raise AuditError(f"ocr-failed:{path.name}:{proc.stderr.strip()[:200]}")
    try:
        rows = json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        raise AuditError(f"ocr-bad-json:{path.name}:{e}") from e
    return [
        Token(
            text=r["text"],
            confidence=float(r["confidence"]),
            x=float(r["x"]),
            y=float(r["y"]),
            w=float(r["w"]),
            h=float(r["h"]),
        )
        for r in rows
    ]
