#!/usr/bin/env python3
"""
Interactive CLI Tester for Ternary-Bonsai-27B (MLX 2-bit).

Loads model weights from project-local folder `./models/bonsai/`
and runs inference using Apple Silicon Metal acceleration.
"""

import os
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent
MODELS_DIR = PROJECT_ROOT / "models"
BONSAI_DIR = MODELS_DIR / "bonsai"

# Ensure Hugging Face cache paths point to project-local ./models/
os.environ["HF_HOME"] = str(MODELS_DIR)
os.environ["TRANSFORMERS_CACHE"] = str(MODELS_DIR)


def main():
    print("=======================================================================")
    print("   JarvisMacOS — Interactive Ternary-Bonsai-27B CLI Tester")
    print("=======================================================================")

    if not BONSAI_DIR.exists():
        print(f"[ERROR] Model folder not found at: {BONSAI_DIR}")
        print("Please ensure model weights are downloaded into ./models/bonsai/")
        sys.exit(1)

    # Prompt user for input in terminal
    user_prompt = input("\nEnter your prompt for Bonsai 27B: ").strip()

    if not user_prompt:
        print("[WARN] Prompt was empty. Exiting.")
        sys.exit(0)

    print(f"\n[1/2] Loading Ternary-Bonsai-27B into Metal Unified Memory from:\n      {BONSAI_DIR} ...")
    try:
        import mlx_lm
    except ImportError:
        print("[ERROR] mlx_lm is not installed in current Python environment.")
        print("Use backend virtualenv: ./backend/venv/bin/python test.py")
        sys.exit(1)

    model, tokenizer = mlx_lm.load(str(BONSAI_DIR))
    print("[1/2] Model successfully loaded into Metal Unified Memory.")

    print(f"\n[2/2] Generating response (max_tokens=256) ...\n")
    response_text = mlx_lm.generate(
        model,
        tokenizer,
        prompt=user_prompt,
        max_tokens=256,
        verbose=False
    )

    print("-----------------------------------------------------------------------")
    print("BONSAI 27B RESPONSE:")
    print("-----------------------------------------------------------------------")
    print(response_text.strip())
    print("-----------------------------------------------------------------------")


if __name__ == "__main__":
    main()
