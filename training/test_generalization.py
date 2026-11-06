import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from evaluation_data import heldout_paths, text_key
from generalization_data import generate, SHARD, BENCH, digest
from post_train import load_schema, schema_score
from prepare_data import canonicalize

ROOT=Path(__file__).resolve().parents[1]


class GeneralizationTests(unittest.TestCase):
    def test_frozen_generation_and_disjoint_splits(self):
        generated=generate(); manifest=json.loads((BENCH/'manifest.json').read_text())
        all_texts=set(); all_templates=set()
        for split,path in [('train',SHARD),('development',BENCH/'development.jsonl'),('audit',BENCH/'audit.jsonl')]:
            rows=[json.loads(s) for s in path.read_text().splitlines()]
            self.assertEqual(rows,generated[split])
            self.assertEqual(digest(path),manifest['files'][split]['sha256'])
            texts={text_key(r['text']) for r in rows}; templates={r['template_id'] for r in rows}
            self.assertEqual(len(texts),len(rows)); self.assertFalse(texts & all_texts)
            self.assertFalse(templates & all_templates)
            all_texts |= texts; all_templates |= templates
            self.assertEqual({i['name'] for r in rows for i in r['intents']},set(load_schema()))
            for r in rows: self.assertFalse(canonicalize(r['intents'],load_schema())[1],r)
        old={text_key(json.loads(line)['text']) for path in
             [*ROOT.glob('dataset/*.jsonl'),*ROOT.glob('training/eval_*.jsonl')]
             if path != SHARD for line in path.read_text().splitlines() if line.strip()}
        self.assertFalse(all_texts & old)

    def test_audit_rejected_for_development_and_excluded_from_preparation(self):
        self.assertIn(BENCH/'audit.jsonl',heldout_paths())
        with tempfile.TemporaryDirectory() as tmp:
            cmd=[sys.executable,str(ROOT/'training/prepare_data.py'),'--shards',str(SHARD),'--output-dir',tmp,'--development']
            bad=subprocess.run(cmd+[str(BENCH/'audit.jsonl')],capture_output=True)
            self.assertNotEqual(bad.returncode,0)
            subprocess.run(cmd+[str(BENCH/'development.jsonl')],capture_output=True,check=True)
            train=[json.loads(s) for s in (Path(tmp)/'train.jsonl').read_text().splitlines()]
            dev=[json.loads(s) for s in (Path(tmp)/'dev.jsonl').read_text().splitlines()]
            self.assertEqual(len(train),1580)
            self.assertEqual(len(dev),276)
            blocked={text_key(json.loads(s)['text']) for p in heldout_paths() for s in p.read_text().splitlines() if s.strip()}
            self.assertFalse({text_key(r['input_text']) for r in train}&blocked)

    def test_numeric_bools_are_not_valid_integers(self):
        target=[dict(name='volume.set',args=dict(level=True))]
        self.assertEqual(schema_score(target,load_schema()),0)
        self.assertTrue(canonicalize(target,load_schema())[1])

    def test_file_query_operations_match_executable_contract(self):
        import re
        swift=(ROOT/'Sources/JarvisMacOS/Files/FileExplorer.swift').read_text().split('var wantsOpen')[0]
        operations=set(re.findall(r'^\s+case (\w+)',swift,re.M))
        self.assertEqual(set(load_schema()['files.query']['enums']['op']),operations)
        bad=[dict(name='files.query',args=dict(op='smallest',folder='downloads',ext=''))]
        self.assertEqual(schema_score(bad,load_schema()),0)
        self.assertTrue(canonicalize(bad,load_schema())[1])


if __name__=='__main__': unittest.main()
