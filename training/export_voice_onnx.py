#!/usr/bin/env python3
"""Export the existing Resemblyzer encoder for a native feasibility comparison.

No training, model replacement or profile changes. Audio preprocessing remains
a separate compatibility requirement; this graph only accepts mel features.
Architecture follows Resemblyzer's Apache-2.0 VoiceEncoder.forward implementation.
"""
import argparse
import hashlib
import json
from pathlib import Path

import torch
from torch import nn


class SpeakerEncoder(nn.Module):
    def __init__(self):
        super().__init__()
        self.lstm = nn.LSTM(40, 256, 3, batch_first=True)
        self.linear = nn.Linear(256, 256)
        self.relu = nn.ReLU()

    def forward(self, mels):
        _, (hidden, _) = self.lstm(mels)
        embeddings = self.relu(self.linear(hidden[-1]))
        return embeddings / torch.norm(embeddings, dim=1, keepdim=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    model = SpeakerEncoder().eval()
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
    # Original Resemblyzer inference ignores these two training-loss parameters.
    state = {key: value for key, value in checkpoint["model_state"].items()
             if key not in {"similarity_weight", "similarity_bias"}}
    model.load_state_dict(state, strict=True)
    args.destination.mkdir(parents=True, exist_ok=True)
    output = args.destination / "speaker_encoder.onnx"
    torch.onnx.export(model, torch.zeros(1, 160, 40), output,
                      input_names=["mels"], output_names=["embeddings"],
                      dynamic_axes={"mels": {0: "batch"}, "embeddings": {0: "batch"}},
                      opset_version=17, dynamo=False)
    manifest = {"source": "Resemblyzer 0.1.4 pretrained encoder", "license": "apache-2.0",
                "checkpoint_sha256": hashlib.sha256(args.checkpoint.read_bytes()).hexdigest(),
                "graph_sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
                "torch_export_version": torch.__version__, "opset": 17,
                "input": ["batch", 160, 40], "output": ["batch", 256],
                "audio_preprocessing_verified": False, "runtime_cutover_approved_by_parity": False}
    (args.destination / "voice-export.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
