from __future__ import annotations

import json
import urllib.request
from typing import Any

OLLAMA_API_URL = "http://127.0.0.1:11434/api/generate"
MODEL_NAME = "mistral:7b"


def get_bonsai_model():
    """Compatibility placeholder - model is managed by local Ollama service."""
    return True, True


def generate_bonsai(prompt: str, max_tokens: int = 256, temp: float = 0.7) -> dict[str, Any]:
    """Generates text completion using local Ollama (mistral:7b)."""
    if not prompt.strip():
        return {"error": "Prompt cannot be empty."}

    print(f"[Ollama][Mistral] Generating response via local Ollama ({MODEL_NAME}, prompt len={len(prompt)}) ...")

    payload = {
        "model": MODEL_NAME,
        "prompt": prompt,
        "stream": False,
        "options": {
            "num_predict": max_tokens,
            "temperature": temp
        }
    }

    try:
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            OLLAMA_API_URL,
            data=data,
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            result = json.loads(resp.read().decode("utf-8"))
            response_text = result.get("response", "")
            return {
                "model": MODEL_NAME,
                "prompt": prompt,
                "response": response_text.strip()
            }
    except Exception as e:
        print(f"[Ollama][ERROR] Generation failed: {e}")
        return {"error": f"Ollama generation failed: {str(e)}. Ensure Ollama is running."}
