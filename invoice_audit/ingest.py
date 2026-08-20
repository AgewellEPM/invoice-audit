"""Input collection and PDF rendering for audit runs."""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from .ocr import AuditError, sha256_file

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".tiff"}
SCAN_EXTS = IMAGE_EXTS | {".pdf"}


@dataclass(frozen=True)
class ScanInput:
    image_path: Path
    source_path: Path
    source_kind: str
    source_page: int | None = None

    @property
    def file_name(self) -> str:
        return self.image_path.name

    @property
    def image_sha256(self) -> str:
        return sha256_file(self.image_path)

    @property
    def source_sha256(self) -> str:
        return sha256_file(self.source_path)


def collect_scan_inputs(scans_dir: Path) -> list[ScanInput]:
    if not scans_dir.is_dir():
        raise AuditError(f"scans-dir-missing:{scans_dir}")
    inputs = sorted(p for p in scans_dir.iterdir()
                    if p.suffix.lower() in SCAN_EXTS)
    if not inputs:
        raise AuditError(f"no-scans-found:{scans_dir}")

    scans: list[ScanInput] = []
    render_root = scans_dir / ".invoice-audit-rendered"
    for p in inputs:
        suffix = p.suffix.lower()
        if suffix in IMAGE_EXTS:
            scans.append(ScanInput(p, p, "image"))
        elif suffix == ".pdf":
            for page_no, image_path in enumerate(_render_pdf(p, render_root), start=1):
                scans.append(ScanInput(image_path, p, "pdf", page_no))
    if not scans:
        raise AuditError(f"no-renderable-scans-found:{scans_dir}")
    return scans


def _render_pdf(path: Path, render_root: Path) -> list[Path]:
    out_dir = render_root / _slug(path.stem)
    out_dir.mkdir(parents=True, exist_ok=True)
    try:
        return _render_pdfium(path, out_dir)
    except ImportError:
        try:
            return _render_pymupdf(path, out_dir)
        except ImportError as e:
            raise AuditError(
                "pdf-renderer-missing:install pypdfium2 or pymupdf"
            ) from e


def _render_pdfium(path: Path, out_dir: Path) -> list[Path]:
    import pypdfium2 as pdfium

    pdf = pdfium.PdfDocument(str(path))
    out: list[Path] = []
    try:
        for idx in range(len(pdf)):
            page = pdf[idx]
            image = page.render(scale=2.0).to_pil()
            target = out_dir / f"page-{idx + 1:03d}.png"
            image.save(target)
            out.append(target)
    finally:
        pdf.close()
    if not out:
        raise AuditError(f"pdf-empty:{path.name}")
    return out


def _render_pymupdf(path: Path, out_dir: Path) -> list[Path]:
    import fitz

    doc = fitz.open(path)
    out: list[Path] = []
    for idx, page in enumerate(doc):
        pix = page.get_pixmap(matrix=fitz.Matrix(2, 2), alpha=False)
        target = out_dir / f"page-{idx + 1:03d}.png"
        pix.save(target)
        out.append(target)
    if not out:
        raise AuditError(f"pdf-empty:{path.name}")
    return out


def _slug(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-") or "document"
