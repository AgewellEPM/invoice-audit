"""Tesseract OCR backend — the Windows 11 token source (also runs on macOS).

Chosen over Windows.Media.Ocr because Tesseract emits per-word CONFIDENCE, and
grounding.py refuses to trust a number whose token confidence is low. Emits the
exact same Token schema as the Apple Vision backend, so everything downstream —
layout, validate, grounding, floor, receipt — is byte-for-byte identical across
operating systems. Fail-closed with named reasons, like the Vision path.

Running this backend on macOS (where Tesseract is also installed) is how the
Windows-bound pipeline is proven without a VM: same engine, same tokens; only
the tesseract binary differs between OSes. Two engines (Vision + Tesseract) also
give the independent second read that closes the self-consistent-misread gap.
"""
from __future__ import annotations

import csv
import io
import shutil
import subprocess
from pathlib import Path

from .ocr import AuditError, Token


def ocr_image_tesseract(path: Path) -> list[Token]:
    exe = shutil.which("tesseract")
    if not exe:
        raise AuditError("ocr-tesseract-missing:install tesseract "
                         "(Windows: winget install tesseract-ocr.tesseract)")
    if not path.exists():
        raise AuditError(f"scan-missing:{path.name}")
    proc = subprocess.run([exe, str(path), "stdout", "tsv"],
                          capture_output=True, text=True, timeout=120)
    if proc.returncode != 0:
        raise AuditError(f"ocr-failed:{path.name}:{proc.stderr.strip()[:200]}")
    return _parse_tsv(proc.stdout, path.name)


def _parse_tsv(tsv: str, name: str) -> list[Token]:
    """Tesseract TSV → normalized tokens. Page dims come from the level-1 row;
    word rows are level 5, conf 0-100 (-1 marks non-text, dropped)."""
    reader = csv.DictReader(io.StringIO(tsv), delimiter="\t",
                            quoting=csv.QUOTE_NONE)
    w_img = h_img = None
    toks: list[Token] = []
    for row in reader:
        try:
            level = int(row["level"])
        except (KeyError, ValueError, TypeError):
            continue
        if level == 1:  # page — carries the full-image dimensions
            w_img, h_img = float(row["width"]), float(row["height"])
            continue
        if level != 5:  # 5 == word
            continue
        text = (row.get("text") or "").strip()
        if not text:
            continue
        try:
            conf = float(row["conf"])
        except (KeyError, ValueError, TypeError):
            continue
        if conf < 0:  # non-text placeholder
            continue
        if not w_img or not h_img:
            raise AuditError(f"ocr-tesseract-no-page-dims:{name}")
        left, top = float(row["left"]), float(row["top"])
        w, h = float(row["width"]), float(row["height"])
        toks.append(Token(text=text, confidence=conf / 100.0,
                          x=left / w_img, y=top / h_img,
                          w=w / w_img, h=h / h_img))
    if not toks:
        raise AuditError(f"ocr-tesseract-empty:{name}")
    return toks
