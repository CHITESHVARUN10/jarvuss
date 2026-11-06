# Intent-model generalization workflow

Continue from a known checkpoint using explicitly selected **new** shards. Do
not silently prepare the entire original corpus or harvest execution-log pairs.
The project's “RL” command currently performs supervised continued fine-tuning;
it is not policy-gradient reinforcement learning.

## Data boundaries

Shards 074–079 provide synthetic general commands, slot transfer, question/action
contrasts and retention examples. They contain no copied benchmark sentences or
private usage logs. Their generators exclude normalized overlap with existing
training data and **every** versioned benchmark. The preparer and trainer also
enforce that boundary; the trainer rejects leaked development/audit rows even if
they enter through harvested pairs.

`training/benchmarks/generalization-v2/development.jsonl` is reusable selection
data. Its 276 commands cover all 45 intent names. The 275-command audit uses
different authored phrasing and slot pools and is consulted after candidate
selection. Repeated use makes a suite a regression test, not a fresh audit.

Version 1 development was used in experiment 01 before native mapping validation
caught an invalid `files.query(op="smallest")` label. The app does not implement
that operation. Version 2 labels those requests `ai.query` for fallback. Version 1
files and historical scores remain available; they are not an additional
independent benchmark. No version 1 audit predictions were inspected before this
correction. Experiment 01's snapshot retains the original training data.

`generate_challenge.py` creates immutable seeded recombination audits with paired
surface variations. For example:

```sh
training/.venv/bin/python training/generate_challenge.py \
  --seed 2026110674 --pairs 150 \
  --output-dir training/benchmarks/a-new-unused-directory
```

The seed, generator hash and resulting file hash identify the suite. Exclusion
depends on the repository corpus at generation time; recreating it requires that
same corpus. Fresh seeds vary slots and combinations, not the underlying finite
grammar. Periodically author genuinely new phrasing and add human-reviewed real
commands. A seed alone cannot prevent benchmark saturation.

## Prepare and train

```sh
training/.venv/bin/python training/prepare_data.py \
  --shards dataset/train-074-generalization.jsonl \
           dataset/train-075-slot-transfer.jsonl \
           dataset/train-076-boundary-copy.jsonl \
           dataset/train-077-status-file-retention.jsonl \
  --development training/benchmarks/generalization-v2/development.jsonl \
  --cap-per-intent-sequence 160 \
  --output-dir training/out/my-run/data

training/.venv/bin/python training/post_train.py --train --no-rl-pairs \
  --data-dir training/out/my-run/data --init-from PATH_TO_PARENT_CHECKPOINT \
  --output-dir training/out/my-run/checkpoint --device cpu \
  --epochs 3 --batch 4 --accum 4 --lr 0.00004 \
  --selection-metric macro_exact
```

The cap samples each ordered sequence of intent names deterministically. It is
optional and recorded in the manifest. It balances large template families; it
does not add older data. `macro_exact` selects checkpoints using complete
intent-and-argument matches averaged across intent names. Partial-credit reward
is still a diagnostic metric and cannot substitute for exact accuracy.

Keep the selected shard snapshots, commands, manifests, environment and initial
weight hash with each run. Export to an isolated `training/out/.../onnx` path.
Never use the active model directory as an experiment's export destination.

## Evaluate without hiding regressions

`evaluate_generalization.py` uses the real quantized serving decoder, saves every
prediction and reports strict exact match, schema validity, intent sequence,
confidence acceptance errors, per-family/slice accuracy and paired correctness.
It includes unchanged legacy suites alongside the new benchmark. Example:

```sh
training/.venv/bin/python training/evaluate_generalization.py \
  --model training/out/my-run/onnx \
  --output training/out/my-run/development.json
```

Only after choosing a candidate, run `--split audit` on both the authored and a
fresh seeded benchmark. An `.audit-access.json` receipt records the start of
each final audit. Compare the active model, previous candidate and selected
candidate on identical file hashes and decoder/schema versions.

Exact deduplication does not establish unfamiliar syntax. `leakage_report.py`
also checks delexicalized structure, removing slots, numbers and polite wrappers.
Evaluation reports split familiar and unfamiliar structures against **all**
repository training shards as a conservative common exposure reference. This
heuristic cannot prove semantic novelty. String-copy tests include unfamiliar
names; canonical command forms remain useful regression tests.

Wilson intervals and template-group bootstrap intervals describe this small
authored sample. Correlated templates and synthetic distribution limit their
interpretation; neither estimates accuracy over every real user command.

`GeneralizationDataTests` checks that native-family gold labels map to executable
actions; it does not execute those actions. `GeneralizationServingTests` can
map saved predictions offline via `JARVIS_INTENT_EVALUATIONS`, a JSON array of
report paths. Result files end in `.mapped.json`. Raw model scores and mapped
action scores remain separate; native correction must not be represented as a
learned-model improvement. Gold labels that cannot map are counted explicitly. This is not a full-planner
precedence check or live execution test; native routes may preempt the model.

## Promotion

`generalization_gate.py` requires passing final audits, no lost shard073-correct
cases, no aggregate legacy-suite regression, adequate unfamiliar-structure
accuracy and no audit-family decline against the active model. It binds evidence
to exact quantized weights. Existing native/shuffle/volume/workspace 90% release
thresholds also apply. An aggregate gain cannot waive an individual gate.

The owner-local publication pipeline additionally requires this evidence when
versioned benchmarks exist and refuses changed evidence or different weights.
No benchmark should be relabeled to make a candidate pass. When a label error is
confirmed by the executable contract, publish an explicit corrected edition and
re-evaluate every compared model; preserve the original scores.

A failed audit is useful evidence. Preserve the accepted model, record remaining
failure families and use a fresh audit for the next selection cycle. Passing a
finite suite cannot prove the model never memorizes or handles every future
command correctly.

## Second audit cycle and functional comparison

After consuming thev2audit, new shards078/079 target its broad failure families
without copying its sentences. Generalizationv3provides272development and276
audit cases with new phrasing/slots; the new seeded audit has274cases. Runs6
and7were compared once on those550fresh cases after training finished. They are
now comparison/regression evidence, not untouched tests for future optimization.

Optional intent loss can emphasize names (`--intent-loss-weight3`) or separate
discrete decisions from literal copying (`--intent-loss-mode grouped
--intent-loss-scope typed`). The latter also marks schema enums and integers;
no parameters or vocabulary entries are added. These are experimental training
objectives, not claims of proven improvement.

`--novelty-reference` binds structural slices to a frozen source manifest rather
than allowing future untrained shards to alter the reference silently. Cached
baseline predictions can be merged only for identical weights, decoder and
schema; source report hashes remain recorded.

The user ended further experiments, compared functional candidates 6 and 7,
and explicitly selected Run 6 without requiring perfect scores. Run 6 is now
published as v1.0.2 and bundled in the installed app. Strict generalization
checks remain recorded as failing. A separate owner acceptance binds this exact
release, checkpoint, weights and unchanged evidence; artifact integrity,
provenance and privacy checks remain required. Future candidates require a new
evaluation and release decision.

See [the v1.0.2 benchmark report](intent-model-v1.0.2.md) for the published
v1.0.1 comparison, results on newer suites and remaining limitations. Other
local candidate weights and optimizer payloads were deleted at the owner’s
request. Run 6’s selected trainable checkpoint and quantized export remain,
alongside datasets and evaluation reports. Historical candidate report paths
remain valid, but their model files are intentionally no longer present.
