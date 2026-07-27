#!/usr/bin/env python3
"""
Project-Local Model Downloader for JarvisMacOS.

Downloads OCR, Embeddings, and Bonsai 27B model weights strictly into project-local
directories inside `./models/`. Never uses global cache locations (~/.cache/huggingface).
Includes skip-guards so already-downloaded models are not re-downloaded.
"""
import os
import sys
from pathlib import Path

# ── Force project-local HF cache paths before any Hugging Face imports ────────
PROJECT_ROOT = Path(__file__).resolve().parent.parent
MODELS_DIR = PROJECT_ROOT / "models"

os.environ["HF_HOME"] = str(MODELS_DIR)
os.environ["TRANSFORMERS_CACHE"] = str(MODELS_DIR)
os.environ["HF_HUB_ENABLE_HF_TRANSFER"] = "0"

OCR_DIR = MODELS_DIR / "ocr"
EMBEDDINGS_DIR = MODELS_DIR / "embeddings"
BONSAI_DIR = MODELS_DIR / "bonsai"

for d in [OCR_DIR, EMBEDDINGS_DIR, BONSAI_DIR]:
    d.mkdir(parents=True, exist_ok=True)

try:
    from huggingface_hub import snapshot_download
except ImportError:
    print("[Downloader][ERROR] huggingface_hub is required. Run 'pip install huggingface-hub' first.")
    sys.exit(1)


def is_model_present(model_dir: Path, expected_files: list[str]) -> bool:
    """Returns True if all expected key files exist in model_dir with non-zero size."""
    if not model_dir.exists():
        return False
    for filename in expected_files:
        p = model_dir / filename
        if not p.exists() or p.stat().st_size == 0:
            return False
    return True


def download_ocr_model():
    """Download Baidu Unlimited-OCR (~6.36GB) into ./models/ocr/"""
    expected = ["model-00001-of-000001.safetensors", "config.json"]
    if is_model_present(OCR_DIR, expected):
        print(f"[Downloader][OCR] Unlimited-OCR model weights already present in {OCR_DIR}. Skipping download.")
        return

    print(f"[Downloader][OCR] Downloading baidu/Unlimited-OCR into project-local folder: {OCR_DIR} ...")
    try:
        snapshot_download(
            repo_id="baidu/Unlimited-OCR",
            local_dir=str(OCR_DIR),
            local_dir_use_symlinks=False,
            resume_download=True
        )
        print(f"[Downloader][OCR] Unlimited-OCR download complete -> {OCR_DIR}")
    except Exception as e:
        print(f"[Downloader][OCR][ERROR] Failed to download Unlimited-OCR: {e}")


def download_embeddings_model():
    """Download sentence-transformers/all-MiniLM-L6-v2 (~90MB) into ./models/embeddings/"""
    expected = ["model.safetensors", "tokenizer.json"]
    if is_model_present(EMBEDDINGS_DIR, expected):
        print(f"[Downloader][Embeddings] all-MiniLM-L6-v2 model weights already present in {EMBEDDINGS_DIR}. Skipping download.")
        return

    print(f"[Downloader][Embeddings] Downloading sentence-transformers/all-MiniLM-L6-v2 into project-local folder: {EMBEDDINGS_DIR} ...")
    try:
        snapshot_download(
            repo_id="sentence-transformers/all-MiniLM-L6-v2",
            local_dir=str(EMBEDDINGS_DIR),
            local_dir_use_symlinks=False,
            resume_download=True
        )
        print(f"[Downloader][Embeddings] all-MiniLM-L6-v2 download complete -> {EMBEDDINGS_DIR}")
    except Exception as e:
        print(f"[Downloader][Embeddings][ERROR] Failed to download embeddings model: {e}")


def main():
    print("=======================================================================")
    print("   JarvisMacOS Project-Local Model Downloader")
    print("=======================================================================")
    download_ocr_model()
    download_embeddings_model()
    print("[Downloader] All model checks/downloads complete.")


if __name__ == "__main__":
    main()
