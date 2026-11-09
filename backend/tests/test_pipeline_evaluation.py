import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


def module(name, path):
    spec=importlib.util.spec_from_file_location(name,path)
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result)
    return result


pipeline=module('pipeline_evaluation',ROOT/'scripts/evaluate_pipeline.py')
calibration=module('confidence_calibration',ROOT/'training/calibrate_intent.py')


class PipelineEvaluationTests(unittest.TestCase):
    def test_speech_plan_and_execution_failures_are_separate(self):
        result=pipeline.evaluate([
            dict(expected_transcript='open Chrome',transcript='open home',expected_actions=['open Chrome'],actions=['open Chrome'],effect_verified=False,duration_ms=100),
            dict(expected_transcript='play music',transcript='play music',expected_actions=['play'],actions=['pause'],effect_verified=True,duration_ms=200),
        ])['summary']
        self.assertEqual(result['word_errors'],1)
        self.assertEqual(result['exact_plans'],1)
        self.assertEqual(result['verified_effects'],1)
        self.assertEqual(result['p95_ms'],200)

    def test_unknown_execution_status_is_not_counted_as_verified(self):
        self.assertEqual(pipeline.summarize([dict(success=True)])['effect_cases'],0)

    def test_calibration_requires_evidence_and_accounts_for_sample_size(self):
        few=[dict(schema_valid=True,confidence=.9,exact=True)]*5
        self.assertIsNone(calibration.calibrate(few)['suggested_threshold'])
        sufficient=[dict(schema_valid=True,confidence=.9,exact=True)]*100
        self.assertIsNotNone(calibration.calibrate(sufficient)['suggested_threshold'])
        wrong=[dict(schema_valid=True,confidence=.99,exact=False)]*100
        self.assertIsNone(calibration.calibrate(wrong)['suggested_threshold'])
