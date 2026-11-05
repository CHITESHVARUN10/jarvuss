"""Checks for shard-only preparation; does not load or train a model."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SHARDS = [ROOT / 'dataset' / name for name in (
    'train-070-spotify-shuffle.jsonl',
    'train-071-system-volume.jsonl',
    'train-072-workspace.jsonl',
)]


class IncrementalDataTests(unittest.TestCase):
    def test_only_selected_shards_and_no_heldout_leakage(self):
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run([sys.executable, str(ROOT / 'training/prepare_data.py'),
                            '--shards', *map(str, SHARDS), '--output-dir', tmp],
                           check=True, capture_output=True, text=True)
            output = Path(tmp)
            manifest = json.loads((output / 'dataset_manifest.json').read_text())
            self.assertEqual({r['file'] for r in manifest['shards']},
                             {str(p.relative_to(ROOT)) for p in SHARDS})
            def texts(path):
                return {json.loads(s)['input_text'].strip().casefold()
                        for s in path.read_text().splitlines() if s.strip()}
            selected = {'parse: ' + json.loads(s)['text'].strip().casefold()
                        for path in SHARDS for s in path.read_text().splitlines() if s.strip()}
            train, dev = texts(output / 'train.jsonl'), texts(output / 'dev.jsonl')
            self.assertEqual(train | dev, selected)
            self.assertFalse(train & dev)
            self.assertEqual(len(train) + len(dev), 326)
            for path in output.glob('*.jsonl'):
                if path.name not in ('train.jsonl', 'dev.jsonl'):
                    self.assertFalse((train | dev) & texts(path), path.name)
            self.assertFalse((output / 'rl_pairs.jsonl').exists())

    def test_rejects_evaluation_file_as_training_shard(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run([sys.executable, str(ROOT / 'training/prepare_data.py'),
                                     '--shards', str(ROOT / 'dataset/test.jsonl'),
                                     '--output-dir', tmp], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((Path(tmp) / 'train.jsonl').exists())


if __name__ == '__main__':
    unittest.main()
