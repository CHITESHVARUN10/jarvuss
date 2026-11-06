# Jarvis intent model v1.0.2 — selected Run 6

**v1.0.2 selects Run 6.** Against published v1.0.1, established exact parsing improves from **166/229 (72.5%) to 222/229 (96.9%)**, and the newer 550 comparison cases improve from **298/550 (54.2%) to 475/550 (86.4%)**. Shuffle is 12/12, volume 28/28, and all 33 actual tab/project commands pass. Native search changes from 16/16 to 15/16. These are offline intent-and-argument scores, not live app success rates. The owner accepted the remaining generalization limitations.

## Published v1.0.1 versus Run 6

| Suite | Cases | Published v1.0.1 | Run 6 | Change |
|---|---:|---:|---:|---:|
| native_search | 16 | 16/16 (100.0%) | 15/16 (93.8%) | -6.2 pp |
| valid | 45 | 41/45 (91.1%) | 43/45 (95.6%) | +4.4 pp |
| test | 45 | 42/45 (93.3%) | 43/45 (95.6%) | +2.2 pp |
| novel | 45 | 42/45 (93.3%) | 44/45 (97.8%) | +4.4 pp |
| shuffle | 12 | 0/12 (0.0%) | 12/12 (100.0%) | +100.0 pp |
| volume | 28 | 20/28 (71.4%) | 28/28 (100.0%) | +28.6 pp |
| workspace | 38 | 5/38 (13.2%) | 37/38 (97.4%) | +84.2 pp |
| development | 272 | 151/272 (55.5%) | 216/272 (79.4%) | +23.9 pp |
| previous_development | 276 | 157/276 (56.9%) | 258/276 (93.5%) | +36.6 pp |
| v2_authored | 275 | 171/275 (62.2%) | 259/275 (94.2%) | +32.0 pp |
| v2_rotating | 296 | 175/296 (59.1%) | 287/296 (97.0%) | +37.8 pp |
| v2_stress | 34 | 10/34 (29.4%) | 24/34 (70.6%) | +41.2 pp |
| fresh_authored | 276 | 150/276 (54.3%) | 212/276 (76.8%) | +22.5 pp |
| fresh_seeded | 274 | 148/274 (54.0%) | 263/274 (96.0%) | +42.0 pp |

## Why Run 6

Run 7 scores 224/229 on established cases versus Run 6 at 222/229, but Run 6 scores 475/550 on fresh comparison cases versus Run 7 at 467/550. Both pass all 33 actual tab/project commands, 12 shuffle cases and 28 volume cases. The 37/38 versus 38/38 workspace score differs on Spotify title casing in a negative control, not project support. Run 7 introduced file-count versus folder-count errors, unspecified browser overrides and literal-name substitutions that Run 6 handles better.

## All candidates on the same established cases

| Candidate | General /135 | Native /16 | Shuffle /12 | Volume /28 | Workspace /38 | Total /229 | Exact |
|---|---:|---:|---:|---:|---:|---:|---:|
| Active v1.0.1 | 125 | 16 | 0 | 20 | 5 | 166 | 72.5% |
| 070–072 candidate | 109 | 16 | 4 | 19 | 23 | 171 | 74.7% |
| Shard 073 | 125 | 15 | 7 | 21 | 27 | 195 | 85.2% |
| Run 1 | 123 | 15 | 10 | 26 | 38 | 212 | 92.6% |
| Run 2 | 126 | 15 | 10 | 27 | 38 | 216 | 94.3% |
| Run 3 | 126 | 16 | 12 | 27 | 38 | 219 | 95.6% |
| Run 4 | 132 | 16 | 12 | 27 | 38 | 225 | 98.3% |
| Run 5 | 130 | 16 | 12 | 28 | 37 | 223 | 97.4% |
| Run 6 | 130 | 15 | 12 | 28 | 37 | 222 | 96.9% |
| Run 7 | 131 | 15 | 12 | 28 | 38 | 224 | 97.8% |


## Method and reproducibility

The quantized ONNX models use the actual Jarvis serving decoder and `parse: ` prefix, with identical suite contents and intent schema. Exact match includes arguments and ordering, and requires schema validity. All case predictions, latencies and artifact hashes were recorded locally. The previous model matches the published v1.0.1 ONNX hashes. No live application actions were executed during these measurements.

Established suites contain 229 cases. Development suites (272 new, 276 prior) were used for model selection. The older authored 275, seeded 296 and stress 34 audits were consumed and reused as explicitly identified regression suites. Fresh authored 276 plus seeded 274 cases were uninspected during training/checkpoint selection of runs 6 and 7; both were measured before the owner chose Run 6. They are now consumed tests and must not be called untouched in subsequent tuning. All are synthetic tests, not population accuracy estimates. Mixed development/regression totals are not independent generalization estimates.

Evaluation-only files are included in the dataset repository under `eval/`; do not train on these files. Their released copies are privacy-screened; screening can change paths or literals, so historical scores describe the original frozen local suites rather than a rerun on modified public rows. Machine-readable aggregate scores and source evidence hashes are in `benchmarks.json`. No private command logs or audio are published.

## Training and dataset

The Google T5-small architecture and vocabulary are unchanged. Run 6 continues from campaign Run 4 using only selected new shards 074–079, with 4,076 prepared rows, 4,944 examples after focused repetition, 272 development cases, seed 13, three epochs and learning rate 0.00003. Intent-name tokens receive loss weight 3. No original corpus replay or harvested reward pairs were used in this round. This is supervised continuation in the project’s RL pipeline, not PPO/RLHF. The full released corpus contains 79 training shards; the last six add 7,042 synthetic rows.

## Limitations and release decision

Native search loses one exact case (16/16 to 15/16). Negated or quoted instructions and unfamiliar literal names still cause errors. Gains are substantial but do not establish universal correctness, semantic reasoning or absence of memorization. Some older benchmark labels conflict with native behavior; raw scores remain unchanged.

The owner explicitly accepted Run 6 for functional use and authorized publication on 2026-11-06. Strict quality checks remain recorded as failing; a separately recorded acceptance binds the release version, checkpoint, quantized files and unchanged evidence. Privacy, artifact integrity and provenance checks remain required. No benchmark was relabeled to make this release pass.
