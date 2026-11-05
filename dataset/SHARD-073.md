# Shard 073: regression repair and capability retention

`train-073-regression-retention.jsonl` contains 583 synthetic authored examples.
Regenerate deterministically with `python training/generate_regression_shard.py`.
The generator excludes every existing training and held-out utterance after
case/punctuation normalization. It uses fresh topics, song titles, folder/file
names, project aliases and numeric amounts, not benchmark rows or private logs.

The previous three-shard candidate often emitted the correct intent family with
empty arguments. This shard restores full argument production while retaining
new argument-free families. General validation, test and novel evaluation rows
remain untouched. Those split names describe evaluation sets, not training labels.

Coverage:

- 132 web-search examples with engine and complete query.
- 84 folder/latest-file/create examples with exact names.
- 30 install-preview examples with package and source (no install execution).
- 59 music/transport examples, including song and playlist arguments.
- 65 volume examples: numeric/spoken amounts, absolute versus delta, info/mute.
- 42 display, 24 app, 5 information, 21 compound and 6 AI-boundary examples.
- 28 shuffle, 71 window/tab/project, 16 native-search retention examples.

`regression_family` is an audit annotation, not model input. `resolved_args`
oracles accompany native retention commands. The model still predicts only
argument-free families for shuffle, workspace and native search. Swift tests
verify their actual native field resolution, and numeric volume targets.

The authorized run continues from the previous 070–072 candidate, with only
this shard selected, no historical-shard rehearsal and no harvested pairs.
A lower learning rate reduces update size. Retention is an empirical check,
not a guarantee: compare all fixed independent suites against both the active
model and the prior candidate, and separately check the 28 previously improved
phrases. A candidate that loses retained capabilities is not automatically
promoted, uploaded or installed.
