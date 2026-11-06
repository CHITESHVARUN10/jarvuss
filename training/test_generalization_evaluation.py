import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import evaluate_generalization as evaluation
from generalization_gate import gate
from leakage_report import signature


class EvaluationTests(unittest.TestCase):
    def test_reused_predictions_require_identical_model_and_decoder(self):
        import merge_evaluations
        base=dict(weights={'encoder':'hash'},decoder_sha256='decoder',schema_sha256='schema',
                  suites={'development':{'rows':[]}},files={'development':{}})
        old=copy.deepcopy(base)
        for key in ('weights','decoder_sha256','schema_sha256'):
            bad=copy.deepcopy(old);bad[key]='different'
            with self.assertRaises(ValueError):merge_evaluations.merge(base,[('old',bad,'development')])
        with patch.object(merge_evaluations,'annotate_novelty',side_effect=lambda x:x):
            result=merge_evaluations.merge(base,[('old',old,'development')])
        self.assertEqual(result['suites']['old'],old['suites']['development'])

    def test_new_cycle_data_are_fresh_reproducible_and_case_varied(self):
        from generate_context_shard import generate as context,OUTPUT as context_path
        from generate_paraphrase_shard import generate as paraphrase,OUTPUT as paraphrase_path
        from evaluation_data import heldout_paths,text_key
        blocked={text_key(json.loads(s)['text']) for p in heldout_paths() for s in p.read_text().splitlines() if s.strip()}
        for generator,path in [(context,context_path),(paraphrase,paraphrase_path)]:
            rows=[json.loads(s) for s in path.read_text().splitlines()]
            self.assertEqual(generator(),rows)
            self.assertFalse(blocked & {text_key(r['text']) for r in rows})
        literals=[i['args']['name'] for r in paraphrase() for i in r['intents'] if i['name']=='file.create']
        self.assertTrue(any(v.islower() for v in literals))
        self.assertTrue(any(v.isupper() for v in literals))

    def test_new_audit_edition_is_frozen_disjoint_and_covers_all_intents(self):
        from generalization_v3 import generate,DEST
        from generalization_data import digest
        from post_train import load_schema,schema_score
        generated=generate();manifest=json.loads((DEST/'manifest.json').read_text());seen=set()
        for split in ('development','audit'):
            path=DEST/(split+'.jsonl');rows=[json.loads(s) for s in path.read_text().splitlines()]
            self.assertEqual(rows,generated[split]);self.assertEqual(digest(path),manifest['files'][split]['sha256'])
            texts={r['text'].casefold() for r in rows};self.assertFalse(texts & seen);seen |= texts
            self.assertEqual({i['name'] for r in rows for i in r['intents']},set(load_schema()))
            self.assertTrue(all(schema_score(r['intents'],load_schema())==1 for r in rows))

    def test_relative_benchmark_paths_and_immutable_audit_outputs(self):
        import sys,io
        from contextlib import redirect_stderr
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp)/'audit.json'
            row=dict(text='fixture',expected=[dict(name='info.time',args={})],predicted=[dict(name='info.time',args={})],
                     exact=True,schema_valid=True,intent_sequence_exact=True,family='info',slice='test',confidence=1.,latency_ms=1.)
            suite=dict(summary=evaluation.summarize([row]),rows=[row],p50_ms=1.)
            argv=['evaluate_generalization.py','--model',tmp,'--split','audit','--without-legacy',
                  '--benchmark','training/benchmarks/stress-20261106','--output',str(out)]
            with patch.object(sys,'argv',argv),patch.object(evaluation,'evaluate',return_value=dict(audit=suite)):
                self.assertEqual(evaluation.main(),0)
                self.assertTrue(out.exists())
                with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit): evaluation.main()

    def test_serving_metrics_do_not_reward_missing_args_or_confident_wrong_numbers(self):
        rows=[dict(text='set to seven',intents=[dict(name='volume.set',args=dict(level=7))]),
              dict(text='set to eight',intents=[dict(name='volume.set',args=dict(level=8))]),
              dict(text='set to nine',intents=[dict(name='volume.set',args=dict(level=9))])]
        outputs=[('[{"name":"volume.set","args":{}}]',.99),
                 ('[{"name":"volume.set","args":{"level":80}}]',.99),
                 ('[{"name":"volume.set","args":{"level":9}}]',.99)]
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'data.jsonl';path.write_text('\n'.join(map(json.dumps,rows)))
            with patch.object(evaluation,'_OnnxIntentEngine') as engine:
                engine.return_value.generate.side_effect=outputs
                report=evaluation.evaluate(Path(tmp),dict(check=path))['check']
        self.assertEqual(report['summary']['exact'],1)
        self.assertEqual(report['summary']['accepted'],2)
        self.assertEqual(report['summary']['accepted_wrong'],1)
        self.assertEqual(len(report['rows']),3)

    def test_structural_overlap_does_not_count_new_names_as_new_grammar(self):
        def row(name):return dict(text='could you create a folder called '+name+' please',
                                  intents=[dict(name='folder.create',args=dict(name=name))])
        self.assertEqual(signature(row('orange lake')),signature(row('purple hill')))

    def test_seeded_audits_refuse_overwrite_and_preserve_paired_targets(self):
        import subprocess,sys,hashlib
        root=Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            suite=Path(tmp)/'fresh';cmd=[sys.executable,str(root/'training/generate_challenge.py'),
                '--seed','86390862','--pairs','30','--output-dir',str(suite)]
            subprocess.run(cmd,check=True,capture_output=True)
            data=(suite/'audit.jsonl').read_bytes();rows=[json.loads(s) for s in data.splitlines()]
            for index in range(0,len(rows),2):
                self.assertEqual(rows[index]['intents'],rows[index+1]['intents'])
                self.assertEqual(rows[index]['pair_id'],rows[index+1]['pair_id'])
            self.assertNotEqual(subprocess.run(cmd,capture_output=True).returncode,0)
            self.assertEqual(data,(suite/'audit.jsonl').read_bytes())

    def test_no_audits_cannot_pass_release(self):
        report=dict(decoder_sha256='decoder',schema_sha256='schema',weights={},files={},suites={})
        self.assertFalse(gate(report,report,report,[])['promotion_passed'])

    def test_transfer_shard_is_reproducible_and_excludes_every_benchmark(self):
        from generate_transfer_shard import generate,OUTPUT
        from evaluation_data import heldout_paths,text_key
        rows=[json.loads(s) for s in OUTPUT.read_text().splitlines()]
        self.assertEqual(generate(),rows)
        blocked={text_key(json.loads(s)['text']) for p in heldout_paths() for s in p.read_text().splitlines() if s.strip()}
        self.assertFalse(blocked & {text_key(r['text']) for r in rows})

    def test_boundary_shard_is_reproducible_and_does_not_copy_audit_phrases(self):
        from generate_boundary_shard import generate,OUTPUT
        from evaluation_data import heldout_paths,text_key
        rows=[json.loads(s) for s in OUTPUT.read_text().splitlines()]
        self.assertEqual(generate(),rows)
        blocked={text_key(json.loads(s)['text']) for p in heldout_paths() for s in p.read_text().splitlines() if s.strip()}
        self.assertFalse(blocked & {text_key(r['text']) for r in rows})

    def test_status_shard_is_fresh_reproducible_and_schema_valid(self):
        from generate_status_shard import generate,OUTPUT
        from evaluation_data import heldout_paths,text_key
        from post_train import schema_score,load_schema
        rows=[json.loads(s) for s in OUTPUT.read_text().splitlines()]
        self.assertEqual(generate(),rows)
        blocked={text_key(json.loads(s)['text']) for p in heldout_paths() for s in p.read_text().splitlines() if s.strip()}
        self.assertFalse(blocked & {text_key(r['text']) for r in rows})
        self.assertTrue(all(schema_score(r['intents'],load_schema())==1 for r in rows))

    def test_cap_limits_ordered_intent_sequences_without_adding_old_data(self):
        import subprocess,sys
        from collections import Counter
        root=Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run([sys.executable,str(root/'training/prepare_data.py'),'--shards',
                str(root/'dataset/train-074-generalization.jsonl'),str(root/'dataset/train-075-slot-transfer.jsonl'),
                str(root/'dataset/train-076-boundary-copy.jsonl'),'--cap-per-intent-sequence','160',
                '--development',str(root/'training/benchmarks/generalization-v2/development.jsonl'),
                '--output-dir',tmp],check=True,capture_output=True)
            rows=[json.loads(s) for s in (Path(tmp)/'train.jsonl').read_text().splitlines()]
            counts=Counter(tuple(i['name'] for i in json.loads(r['target_text'])) for r in rows)
            self.assertEqual(len(rows),3219)
            self.assertLessEqual(max(counts.values()),160)


if __name__=='__main__':unittest.main()
