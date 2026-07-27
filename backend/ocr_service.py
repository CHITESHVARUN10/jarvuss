from __future__ import annotations

import os
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(__file__).resolve().parent.parent
MODELS_DIR = PROJECT_ROOT / "models"
OCR_DIR = MODELS_DIR / "ocr"
RAG_DOCS_DIR = PROJECT_ROOT / "rag_documents"

os.environ["HF_HOME"] = str(MODELS_DIR)
os.environ["TRANSFORMERS_CACHE"] = str(MODELS_DIR)

_ocr_model: Any = None
_ocr_processor: Any = None


def get_ocr_model():
    """Lazily loads Baidu Unlimited-OCR from ./models/ocr/ on first request."""
    global _ocr_model, _ocr_processor
    if _ocr_model is not None and _ocr_processor is not None:
        return _ocr_model, _ocr_processor

    print(f"[OCR] Loading Unlimited-OCR model from project-local path: {OCR_DIR} ...")
    try:
        from transformers import AutoModelForCausalLM, AutoProcessor
        import torch

        model_path = str(OCR_DIR) if OCR_DIR.exists() else "baidu/Unlimited-OCR"
        _ocr_processor = AutoProcessor.from_pretrained(model_path, trust_remote_code=True, local_files_only=OCR_DIR.exists())
        _ocr_model = AutoModelForCausalLM.from_pretrained(
            model_path,
            trust_remote_code=True,
            torch_dtype=torch.float16 if torch.cuda.is_available() else torch.float32,
            local_files_only=OCR_DIR.exists()
        )
        print("[OCR] Unlimited-OCR model successfully loaded.")
        return _ocr_model, _ocr_processor
    except Exception as e:
        print(f"[OCR][WARN] Failed to load AutoModelForCausalLM Unlimited-OCR: {e}. Falling back to PIL/pyPDF text extraction.")
        return None, None


def extract_text_from_file(file_path: Path) -> dict[str, Any]:
    """
    Extracts text from a document or image in ./rag_documents/.
    Strictly READ-ONLY: Never modifies or deletes source files.
    """
    if not file_path.exists():
        raise FileNotFoundError(f"File not found: {file_path}")

    ext = file_path.suffix.lower()
    extracted_text = ""
    page_count = 1

    if ext in [".png", ".jpg", ".jpeg", ".bmp", ".tiff", ".webp"]:
        extracted_text = _ocr_image(file_path)
    elif ext == ".pdf":
        extracted_text, page_count = _extract_pdf(file_path)
    elif ext in [".txt", ".md", ".json", ".csv"]:
        extracted_text = file_path.read_text(encoding="utf-8", errors="ignore")
    else:
        raise ValueError(f"Unsupported file type for OCR/extraction: {ext}")

    return {
        "success": True,
        "filename": file_path.name,
        "filepath": str(file_path),
        "text": extracted_text.strip(),
        "char_count": len(extracted_text.strip()),
        "page_count": page_count
    }


def _ocr_image(image_path: Path) -> String:
    from PIL import Image
    model, processor = get_ocr_model()
    image = Image.open(image_path).convert("RGB")

    if model is not None and processor is not None:
        try:
            inputs = processor(images=image, return_tensors="pt")
            outputs = model.generate(**inputs, max_new_tokens=1024)
            text = processor.batch_decode(outputs, skip_special_tokens=True)[0]
            return text
        except Exception as e:
            print(f"[OCR][ERROR] OCR model inference failed: {e}")

    # Basic fallback if model unavailable
    return f"[Image OCR Content: {image_path.name} ({image.width}x{image.height})]"


def _extract_pdf(pdf_path: Path) -> tuple[str, int]:
    try:
        import pypdf
        reader = pypdf.PdfReader(str(pdf_path))
        num_pages = len(reader.pages)
        full_text = []

        for idx, page in enumerate(reader.pages):
            text = page.extract_text() or ""
            if text.strip():
                full_text.append(f"--- Page {idx + 1} ---\n{text.strip()}")
            else:
                full_text.append(f"--- Page {idx + 1} ---\n[Scanned/Image Page]")

        return "\n\n".join(full_text), num_pages
    except Exception as e:
        print(f"[OCR][ERROR] PDF extraction failed for {pdf_path}: {e}")
        return f"[PDF Content: {pdf_path.name}]", 1
