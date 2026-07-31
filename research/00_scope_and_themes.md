# Scout-Rig Scope and Themes

> **Non-normative.** This is an investigation artifact produced during
> documentation work. It may contain observations about implementation
> history, design alternatives, and unresolved questions. It is supporting
> material, not primary documentation.

## What is scout-rig?

Scout-rig is a Ruby gem that bridges the Scout framework with Python. It
provides three complementary capabilities:

1. **ScoutPython** — A Ruby module that wraps the `pycall` gem to execute
   Python code from Ruby, with support for imports, bindings, threading,
   scripting, and data conversion.

2. **PythonWorkflow** — A Ruby module that defines Scout workflow tasks
   backed by Python functions, so workflow authors can write task logic in
   Python while keeping Scout's dependency management, persistence,
   provenance, and CLI.

3. **Python `scout` package** — A companion Python package (`python/scout`)
   that lets Python code drive Scout workflows (local or remote over HTTP),
   read/write Scout-style TSV files, and register Python functions as
   Scout-compatible tasks via the `scout.task` decorator.

## Repository structure

```
scout-rig/
├── lib/
│   ├── scout-rig.rb                          # Entry point (5 lines)
│   ├── scout/
│   │   ├── python.rb                         # ScoutPython module (158 lines)
│   │   ├── python/
│   │   │   ├── paths.rb                      # Path management (27 lines)
│   │   │   ├── run.rb                        # Execution modes (137 lines)
│   │   │   ├── script.rb                     # Scripting facility (115 lines)
│   │   │   └── util.rb                       # Data conversion (61 lines)
│   │   └── workflow/
│   │       ├── python.rb                     # PythonWorkflow module (37 lines)
│   │       └── python/
│   │           ├── inputs.rb                 # CLI argv builder (59 lines)
│   │           └── task.rb                   # python_task, metadata, type mapping (111 lines)
├── python/
│   ├── scout/
│   │   ├── __init__.py                       # TSV IO, cmd, run_job (231 lines)
│   │   ├── runner.py                         # scout.task, describe_function, CLI (536 lines)
│   │   ├── workflow.py                       # Workflow, Step (64 lines)
│   │   └── workflow/
│   │       └── remote.py                     # RemoteWorkflow, RemoteStep (103 lines)
│   ├── pyproject.toml
│   └── README.md
├── test/
│   ├── scout/
│   │   ├── python/
│   │   │   ├── test_run.rb
│   │   │   ├── test_script.rb
│   │   │   └── test_util.rb
│   │   ├── test_python.rb
│   │   └── workflow/
│   │       ├── python/test_task.rb
│   │       └── test_python.rb
├── doc/
│   ├── Python.md                             # OLD - to be replaced
│   └── PythonWorkflow.md                     # OLD - to be replaced
└── research/                                 # NEW - this directory
```

## Module inventory

### Ruby side

| Module                  | File                              | Lines | Responsibility                                     |
|-------------------------|-----------------------------------|-------|----------------------------------------------------|
| ScoutPython             | lib/scout/python.rb               | 158   | Core API: init, imports, iteration, bindings       |
| ScoutPython (paths)     | lib/scout/python/paths.rb         | 27    | Manage Python sys.path entries                     |
| ScoutPython (run)       | lib/scout/python/run.rb           | 137   | Execution modes, threading, GC, at_exit            |
| ScoutPython (script)    | lib/scout/python/script.rb        | 115   | ruby2python, script(), pickle/JSON result loading  |
| ScoutPython (util)      | lib/scout/python/util.rb          | 61    | py2ruby_a, tsv2df, df2tsv, list2ruby, numpy2ruby  |
| PythonWorkflow          | lib/scout/workflow/python.rb      | 37    | Module definition, load_directory                  |
| PythonWorkflow (inputs) | lib/scout/workflow/python/inputs.rb | 59  | build_python_argv from Ruby values                 |
| PythonWorkflow (task)   | lib/scout/workflow/python/task.rb | 111   | python_task, read_python_metadata, type mapping    |

### Python side

| Module                        | File                                | Lines | Responsibility                                     |
|-------------------------------|-------------------------------------|-------|----------------------------------------------------|
| scout                         | python/scout/__init__.py            | 231   | cmd, libdir, tsv IO, save_tsv, save_job_inputs, run_job |
| scout.runner                  | python/scout/runner.py              | 536   | scout.task decorator, describe_function, CLI dispatch |
| scout.workflow                | python/scout/workflow.py            | 64    | Workflow, Step (local execution)                   |
| scout.workflow.remote         | python/scout/workflow/remote.py     | 103   | RemoteWorkflow, RemoteStep (HTTP client)           |

## Investigation themes

1. **ScoutPython bridge** — How PyCall is wrapped, execution modes, threading,
   bindings, GC, at_exit hooks.

2. **Data conversion** — How Ruby values become Python literals and vice versa;
   TSV↔DataFrame conversion; numpy/list handling; the script() subprocess
   facility.

3. **PythonWorkflow** — How `python_task` discovers metadata, maps Python types
   to Scout types, builds CLI argv, and decodes return values.

4. **Python `scout` package** — The Python-side helpers for TSV IO, running
   Scout workflows from Python, and the `scout.task` decorator with metadata
   extraction and CLI dispatch.

5. **Design philosophy** — How scout-rig follows Scout conventions: thin
   wrappers, annotated objects, fluent APIs, the "setup" pattern.

## GitHub URLs

- scout-rig: `https://github.com/mikisvaz/scout-rig`
- scout-essentials: `https://github.com/mikisvaz/scout-essentials`

For cross-referencing scout-essentials docs, use:
```
https://github.com/mikisvaz/scout-essentials/blob/main/doc/user/<File>.md
https://github.com/mikisvaz/scout-essentials/blob/main/doc/developer/<File>.md
```
