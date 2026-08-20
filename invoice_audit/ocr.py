"""OCR stage — return positioned tokens from one of two on-device backends.

Only OCR is OS-specific; it is the seam the whole pipeline hangs off. macOS
uses the on-device Apple Vision CLI; Windows 11 uses Tesseract (chosen because
it emits per-word confidence, which grounding.py requires). Both emit the same
Token schema, so layout/validate/grounding/floor/receipt are identical.

Backend selection: env `INVOICE_AUDIT_OCR` = vision | tesseract | auto
(default auto — Windows→tesseract, else Vision binary if present, else
tesseract). Fail-closed: a missing binary or an OCR failure raises AuditError
with a named reason; we never return a fabricated or partial page silently.
"""
from __future__ import annotations

import hashlib
import json
import os
import platform
import shutil
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


def _select_backend() -> str:
    b = os.environ.get("INVOICE_AUDIT_OCR", "auto").lower()
    if b in ("vision", "tesseract"):
        return b
    if platform.system() == "Windows":
        return "tesseract"
    if BIN.exists():
        return "vision"
    if shutil.which("tesseract"):
        return "tesseract"
    return "vision"  # nothing available → clear ocr-binary-missing below


def backend_label(backend: str | None = None) -> str:
    """Human/receipt label for the OCR backend actually in use — so a receipt
    never claims Apple Vision when Tesseract (Windows) produced the tokens."""
    return ("apple-vision/vision-ocr"
            if (backend or _select_backend()) == "vision"
            else "tesseract")


def ocr_image(path: Path, backend: str | None = None) -> list[Token]:
    if (backend or _select_backend()) == "tesseract":
        from .ocr_tesseract import ocr_image_tesseract
        return ocr_image_tesseract(path)
    return _ocr_vision(path)


def _ocr_vision(path: Path) -> list[Token]:
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
