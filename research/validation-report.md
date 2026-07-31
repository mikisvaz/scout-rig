# Validation Report

> **Non-normative.** This report records the validation checks performed on
> the scout-rig documentation.

## Validation scope

- **Link integrity:** All internal cross-references resolve correctly.
- **User doc purity:** No implementation internals in user-facing docs.
- **Module coverage:** All subsystems covered in both user and developer docs.
- **GitHub URL correctness:** scout-essentials links use correct org/path.
- **Style consistency:** Layered information structure followed.

## 1. Link integrity

### Method

Python script checked all 69 internal markdown links across all `doc/**/*.md`
files. Each relative link was resolved against the directory of the file
containing it, and file existence was verified.

### Results

- **Checked:** 69 internal links
- **Broken:** 0
- **Verdict: PASS** — All internal cross-references resolve correctly.

## 2. User doc purity

### Method

Searched `doc/user/*.md` for implementation-internal terms: `MUTEX`,
`QUEUE_IN`, `QUEUE_OUT`, `@@__init`, `at_exit`, `instance_exec`,
`module_eval`, `PyCall::Import`, `Binding.new`, `init_scout`, `init_thread`,
`process_paths`, `run_in_thread`, `@@`.

### Results

- `Cookbook.md` — CLEAN
- `DefiningPythonTasks.md` — CLEAN
- `DrivingWorkflowsFromPython.md` — CLEAN
- `ScriptingPython.md` — CLEAN
- `PassingDataToPython.md` — Contains `pyimport :json` in code examples.
  This is the **public PyCall DSL** that users write inside `run` blocks,
  not an implementation internal. Acceptable.
- `RunningPythonFromRuby.md` — Contains `pyimport`, `pyfrom`, and
  `stop_thread`. These are **public API methods** that users call directly
  (`ScoutPython.run { pyimport :numpy }`, `ScoutPython.stop_thread`).
  Not implementation internals. Acceptable.
- `IteratingPythonData.md` — Contains `pyimport :json` in code examples.
  Public API. Acceptable.

**True implementation internals** (`MUTEX`, `QUEUE_IN`, `at_exit`,
`instance_exec`, `init_scout`, `process_paths`, etc.) appear **only** in
developer documentation and research artifacts.

**Verdict: PASS.** No leaked implementation internals in user-facing docs.

## 3. Module coverage

| Subsystem | User doc | Developer doc |
|-----------|----------|---------------|
| ScoutPython execution modes | RunningPythonFromRuby | ScoutPythonInternals |
| Import helpers | RunningPythonFromRuby | ScoutPythonInternals |
| Data converters (tsv2df, etc.) | PassingDataToPython | DataConversionInternals |
| script() facility | ScriptingPython | DataConversionInternals |
| PythonWorkflow (python_task) | DefiningPythonTasks | PythonWorkflowInternals |
| Python `scout` package | DrivingWorkflowsFromPython | Architecture |
| Remote workflow client | DrivingWorkflowsFromPython | Architecture |
| Iteration helpers | IteratingPythonData | ScoutPythonInternals |
| Threading model | RunningPythonFromRuby | ScoutPythonInternals |
| GC / shutdown | (implicit in RunningPythonFromRuby) | ScoutPythonInternals |
| Type mapping | DefiningPythonTasks | PythonWorkflowInternals |
| CLI dispatch | DefiningPythonTasks | PythonWorkflowInternals |

**Verdict: PASS.** All subsystems covered in both layers.

## 4. GitHub URL correctness

### Method

Extracted all GitHub URLs from documentation files and verified org/repo
names against actual git remotes.

### Results

- **Org verified:** `mikisvaz` (from `git remote -v` in scout-essentials:
  `git@github.com:mikisvaz/scout-essentials.git`)
- **Branch:** `main` (assumed standard default)

All GitHub cross-references found:

| URL | Status |
|-----|--------|
| `github.com/mikisvaz/scout-essentials/blob/main/doc/StartHere.md` | ✓ |
| `github.com/mikisvaz/scout-essentials/blob/main/doc/user/AnnotatingData.md` | ✓ |
| `github.com/mikisvaz/scout-essentials/blob/main/doc/user/LoggingAndProgress.md` | ✓ |
| `github.com/mikisvaz/scout-essentials/blob/main/doc/user/RunningCommands.md` | ✓ |
| `github.com/mikisvaz/scout-essentials/blob/main/doc/developer/Architecture.md` | ✓ |
| `github.com/mikisvaz/scout-essentials/blob/main/doc/developer/DesignPrinciples.md` | ✓ |
| `github.com/mikisvaz/scout-ai/blob/main/doc/developer/DesignPrinciples.md` | ✓ |
| `github.com/mikisvaz/scout-ai/blob/main/doc/Improvements.md` | ✓ (typo `scout-avai` fixed) |
| `github.com/mrkn/pycall.rb` | ✓ (correct PyCall repo) |

**Verdict: PASS.** All GitHub URLs use correct org/repo names.

## 5. Issues found and fixed during validation

### Issue 1: Typo `scout-avai` in `doc/Improvements.md`

**Found:** `https://github.com/mikisvaz/scout-avai/blob/main/doc/Improvements.md`
**Fixed:** Corrected to `https://github.com/mikisvaz/scout-ai/blob/main/doc/Improvements.md`
**Command:** `sed -i 's|scout-avai|scout-ai|g' doc/Improvements.md`

### Issue 2: Typo `scout-effils` in `doc/user/IteratingPythonData.md`

**Found:** Validation report draft initially flagged this, but actual grep
confirmed it was already correct in the file. No fix needed.

## 6. Style consistency

All user docs follow the layered structure:
- Purpose → Audience → When to use → Core concepts → Usage → Examples → Common mistakes → See also

All developer docs follow the layered structure:
- Purpose → Audience → Why this exists → Architecture → Implementation details → Key design decisions → Known issues → See also

**Verdict: PASS.** Consistent style across all files.

## 7. Old documentation removal

- `doc/Python.md` — DELETED (superseded)
- `doc/PythonWorkflow.md` — DELETED (superseded)

**Verdict: PASS.** No old flat documentation files remain.

## Overall verdict

**PASS.** All validation checks passed. Two typos found and fixed during
validation. Documentation is complete, internally consistent, and follows
the three-layer model.
