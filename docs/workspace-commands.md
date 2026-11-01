# App windows, tabs, and projects

Configure **System → Project locations** before opening projects by name. Use
**Add project root…** to choose the folder containing your projects, such as a
development drive. Edit its spoken name, for example `work`. Use **Add project
alias…** to choose one particular project and give it a spoken nickname.
Locations are local settings, separate from general file-search locations.

Examples:

- `open a new window in Brave`
- `open a new Chrome window`
- `open a new tab in Chrome`
- `open a new window in VS Code`
- `open a new editor tab in VS Code`
- `open a new terminal tab in VS Code`
- `open my portfolio project` — Finder is the default.
- `open portfolio project in VS Code`
- `open portfolio project from work in Terminal`
- `open it in Finder` — reuses the last successfully opened project.
- `open portfolio project in Finder then open it in VS Code`

A VS Code editor tab is a new untitled text file. An integrated terminal tab is
a separate explicit command. Browsers currently support Brave and Google Chrome;
project destinations are Finder, Visual Studio Code, and the macOS Terminal app.
A project command opens its directory; it does not run a build or development server.

## Matching and context

Saved project aliases take precedence. Immediate child folder names are checked
before deeper folders. Matching ignores case, spacing, and name punctuation;
collisions produce a project selection window rather than opening an arbitrary
folder. `open my project` presents available immediate project directories.

Lookup stays within the configured roots, searches at most three directory
levels, and skips hidden folders, dependency/build directories, and directory
symlinks. It has a 10,000-entry/three-second gathering limit. A limit, inaccessible
root, or disconnected drive produces an error. Add a narrower root or explicit
alias for a large/deep tree. Roots are not guessed from drive names.

`it`, `that`, `this project`, and `that project` refer to the last successful
project open for up to ten minutes. Restarting Jarvis, changing saved locations,
or losing the directory invalidates that context. A failed open does not create
new context. Name the project explicitly when specifying a root.

## Permissions and verification

Browser and Finder/Terminal automation may require allowing Jarvis under
**Privacy & Security → Automation**. VS Code editor/terminal menu actions also
require **Accessibility** and currently use its English menu labels. Permission
failures are surfaced. Creating an editor tab requires an existing or newly
launched editor window; the native adapter creates a window if necessary.

Browser creation checks native window/tab counts; Finder checks the requested
window target. Terminal opens a fresh session, changes directory using a quoted
path, and reports its working directory through a private temporary file that
Jarvis removes afterward. VS Code window creation checks native window counts.
Folder opening through the VS Code bundled CLI reports that the folder request
was sent; CLI acceptance alone does not prove workspace loading completed.

Untitled editor creation checks the window title. The integrated-terminal action
acknowledges the native menu click; terminal-shell readiness needs a manual check.
These operations do not depend on Ollama, the Spotify helper, or a trained intent
model. Process calls have deadlines and accept cancellation; an already accepted
native action cannot be undone by cancellation.

In Routines, select **Window / tab / project** and supply one complete command.
Use separate steps for multiple commands. The command test runner also includes
editable workspace examples. Configure your own project name before executing them.

## Dataset and training status

`dataset/train-072-workspace.jsonl` contains 140 synthetic training examples;
`training/eval_workspace.jsonl` contains 38 independent held-out cases, including
negative routing examples. Native fields are retained as `resolved_args` oracles;
model labels are argument-free `app.new_window`, `app.new_tab`, or `project.open`.
Exact names, apps, and roots are parsed from the original utterance in Swift.
Personal locations and filesystem listings are not part of either dataset.

`training/prepare_data.py --check` validates the schema without training or
writing prepared data. Preparation excludes the workspace evaluation set from
training. The existing evaluator has a `--workspace` option for later evaluation;
no model evaluation or training is required to use the native command pipeline.
Harvesting workspace successes requires a matching authored correction; command
runner executions remain excluded from automatic training rewards.

No training, model replacement, or model publication was performed for this change.

## Developer checks

```sh
swift test
python3 training/prepare_data.py --check
# Explicitly opens blank test windows and a temporary Finder folder, then cleans up:
JARVIS_RUN_WORKSPACE_TESTS=1 swift test --filter WorkspaceLiveTests
```

Unit tests check both routing modes, exact fields for every dataset row, scoped
resolution, ambiguity, aliases, context expiry, failed opens, path quoting,
permissions, and exclusion of model-invented arguments.
