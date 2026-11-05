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

    def test_regression_shard_is_fresh_balanced_and_reproducible(self):
        import importlib.util
        from collections import Counter
        spec = importlib.util.spec_from_file_location("regression_generator", ROOT / 'training/generate_regression_shard.py')
        generator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(generator)
        rows = [json.loads(s) for s in generator.OUTPUT.read_text().splitlines()]
        self.assertEqual(generator.generate(), rows)
        normalize = generator.key
        texts = {normalize(r['text']) for r in rows}
        self.assertEqual(len(texts), len(rows))
        for path in [*ROOT.glob('dataset/*.jsonl'), *ROOT.glob('training/eval_*.jsonl')]:
            if path == generator.OUTPUT: continue
            other = {normalize(json.loads(s)['text']) for s in path.read_text().splitlines() if s.strip()}
            self.assertFalse(texts & other, path.name)
        counts = Counter(r['regression_family'] for r in rows)
        for family in ('volume', 'web_arguments', 'creation_arguments', 'install_arguments',
                       'media_arguments', 'workspace_retention', 'shuffle_retention', 'native_retention'):
            self.assertGreaterEqual(counts[family], 15, family)
        self.assertGreater(sum(v for k, v in counts.items() if not k.endswith('_retention')),
                           sum(v for k, v in counts.items() if k.endswith('_retention')))

    def test_rejects_evaluation_file_as_training_shard(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run([sys.executable, str(ROOT / 'training/prepare_data.py'),
                                     '--shards', str(ROOT / 'dataset/test.jsonl'),
                                     '--output-dir', tmp], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((Path(tmp) / 'train.jsonl').exists())


if __name__ == '__main__':
    unittest.main()
