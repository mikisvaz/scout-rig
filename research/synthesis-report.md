# Synthesis Report

> **Non-normative.** This report cross-checks all investigation artifacts,
> identifies gaps, and produces a concrete writing plan for the new documentation.

## Artifact inventory

| # | Artifact | Coverage |
|---|----------|----------|
| 00 | scope_and_themes | Repository structure, module inventory, GitHub URLs |
| 01 | scoutpython-bridge-analysis | PyCall wrapping, execution modes, threading, bindings, paths, iteration |
| 02 | data-conversion-and-scripting-analysis | ruby2python, script(), data converters, TSV↔DataFrame |
| 03 | pythonworkflow-analysis | python_task lifecycle, type mapping, CLI argv building, return decoding |
| 04 | python-helper-package-analysis | Python scout package: TSV IO, runner.py, workflow.py, remote.py |
| 05 | design-philosophy-analysis | Design principles, anti-patterns, comparison with scout-essentials |

## Gap analysis

### Covered well
- ScoutPython execution modes and their differences.
- Threading model and at_exit hook.
- Data conversion helpers (py2ruby_a, tsv2df, df2tsv, etc.).
- script() facility and result persistence.
- PythonWorkflow lifecycle (metadata → task definition → execution).
- Python scout package (all four modules).
- Design philosophy and anti-patterns.
- Type mapping between Python and Scout.

### Gaps (acceptable)
- No deep investigation of PyCall internals (out of scope — it's a dependency).
- No performance benchmarks (not requested).
- No investigation of error recovery paths in detail (mentioned where relevant).

## Writing plan

### User documentation (`doc/user/`)

Concept-oriented, task-focused. No implementation internals.

| File | Concepts covered | Source artifacts |
|------|-----------------|------------------|
| `RunningPythonFromRuby.md` | When/how to run Python from Ruby: run modes, imports, aliases | 01 |
| `PassingDataToPython.md` | Converting Ruby data to Python: TSV→DataFrame, numpy→Array, script variables | 02 |
| `ScriptingPython.md` | Ad-hoc Python scripts with Ruby variables: script(), result persistence | 02 |
| `DefiningPythonTasks.md` | Defining Scout tasks backed by Python functions | 03 |
| `DrivingWorkflowsFromPython.md` | Using the Python scout package: local and remote workflows | 04 |
| `IteratingPythonData.md` | Traversing Python iterables from Ruby | 01 |
| `Cookbook.md` | Practical recipes | 01-05 |

### Developer documentation (`doc/developer/`)

Concise architectural explanations. Link to research for deep detail.

| File | Architecture covered | Source artifacts |
|------|---------------------|------------------|
| `Architecture.md` | Module map, dependency graph, data flow | 00, all |
| `ScoutPythonInternals.md` | PyCall wrapping, execution modes, threading, GC, bindings | 01 |
| `PythonWorkflowInternals.md` | Metadata discovery, type mapping, CLI generation, result decoding | 03 |
| `DataConversionInternals.md` | ruby2python pipeline, pickle/JSON, subprocess management | 02 |
| `DesignPrinciples.md` | Scout-rig design philosophy, idiomatic patterns, anti-patterns | 05 |

### Top-level

| File | Content |
|------|---------|
| `StartHere.md` | Routing page: audience → layer |
| `Improvements.md` | Actionable recommendations |

## Writing order

1. `doc/StartHere.md` — Needed first for structure.
2. `doc/user/RunningPythonFromRuby.md` — Core user concept.
3. `doc/user/PassingDataToPython.md` — Data flow, depends on RunningPython concept.
4. `doc/user/ScriptingPython.md` — Script-specific, depends on PassingData.
5. `doc/user/DefiningPythonTasks.md` — Workflow integration, depends on all previous.
6. `doc/user/DrivingWorkflowsFromPython.md` — Python-side, standalone.
7. `doc/user/IteratingPythonData.md` — Niche but useful.
8. `doc/user/Cookbook.md` — Recipes, references all above.
9. `doc/developer/Architecture.md` — Overview for developers.
10. `doc/developer/ScoutPythonInternals.md` — Deep dive.
11. `doc/developer/PythonWorkflowInternals.md` — Deep dive.
12. `doc/developer/DataConversionInternals.md` — Deep dive.
13. `doc/developer/DesignPrinciples.md` — Philosophy and anti-patterns.
14. `doc/Improvements.md` — From anti-patterns and findings.
15. Remove old docs.

## GitHub cross-references

For scout-essentials concepts, link to:
```
https://github.com/mikisvaz/scout-essentials/blob/main/doc/user/<File>.md
https://github.com/mikisvaz/scout-essentials/blob/main/doc/developer/<File>.md
```

Specific links to use:
- TSV → `doc/user/AnnotatingData.md`
- Working with files / TmpFile → `doc/user/WorkingWithFiles.md`
- CMD / Running commands → `doc/user/RunningCommands.md`
- Logging / Progress bars → `doc/user/LoggingAndProgress.md`
- Streams / ConcurrentStreamProcessFailed → `doc/user/HandlingStreams.md`
- Path resolution → `doc/developer/PathResolution.md`
- Caching / Persist → `doc/user/CachingResults.md`
