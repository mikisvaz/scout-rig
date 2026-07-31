# Architecture

This document explains the overall architecture of scout-rig, the
relationships between its subsystems, and how data flows through the
system.

## Audience

This page is intended for:

- ✓ Framework contributors
- ✓ Advanced workflow authors who need to understand internal structure
- ✗ Users looking for usage instructions (see [User Documentation](../user/))

## Module map

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Ruby (Scout) Side                           │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  ScoutPython (lib/scout/python.rb + sub-files)              │   │
│  │                                                              │   │
│  │  • run / run_simple / run_direct / run_threaded             │   │
│  │  • import helpers                                            │   │
│  │  • script() subprocess facility                              │   │
│  │  • data converters (tsv2df, numpy2ruby, etc.)               │   │
│  │  • iteration (iterate, collect)                              │   │
│  │                                                              │   │
│  │  extends PyCall::Import                                      │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                      │
│                              │ uses                                │
│                              ▼                                      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  PythonWorkflow (lib/scout/workflow/python.rb + sub-files)  │   │
│  │                                                              │   │
│  │  • python_task: Python file → Scout task                     │   │
│  │  • read_python_metadata: --scout-metadata introspection      │   │
│  │  • build_python_argv: Ruby values → CLI args                 │   │
│  │  • type mapping: Python types ↔ Scout types                  │   │
│  │                                                              │   │
│  │  extends Workflow                                            │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
         │                                          │
         │ subprocess                                │ CLI (rbbt / rbbt_exec.rb)
         ▼                                          ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       Python Side                                   │
│                                                                     │
│  ┌──────────────────┐   ┌──────────────────┐   ┌────────────────┐  │
│  │  scout           │   │  scout.runner    │   │  scout.workflow│  │
│  │  __init__.py     │   │  runner.py       │   │  workflow.py   │  │
│  │                  │   │                  │   │                │  │
│  │  • tsv IO        │   │  • scout.task    │   │  • Workflow    │  │
│  │  • cmd()         │   │  • describe_func │   │  • Step        │  │
│  │  • run_job()     │   │  • CLI dispatch  │   │                │  │
│  │  • save_tsv()    │   │  • type mapping  │   │  + remote.py   │  │
│  │                  │   │                  │   │  • RemoteWF    │  │
│  └──────────────────┘   └──────────────────┘   └────────────────┘  │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Subsystem responsibilities

### ScoutPython

**Responsibility:** Execute Python code from Ruby.

ScoutPython wraps the `pycall` gem with a layered set of execution modes,
import helpers, and data converters. It is the foundational Ruby↔Python
bridge.

Key files:
- `lib/scout/python.rb` — Core module, imports, bindings, iteration.
- `lib/scout/python/run.rb` — Execution modes, threading, GC.
- `lib/scout/python/script.rb` — ruby2python serialization, script().
- `lib/scout/python/util.rb` — Data converters.
- `lib/scout/python/paths.rb` — sys.path management.

See [ScoutPython Internals](ScoutPythonInternals.md).

### PythonWorkflow

**Responsibility:** Define Scout tasks backed by Python functions.

PythonWorkflow extends a Scout `Workflow` module with the `python_task`
method. At definition time, it introspects the Python function's signature
and docstring to automatically declare Scout inputs and return types. At
execution time, it invokes the Python function as a subprocess and decodes
the return value.

Key files:
- `lib/scout/workflow/python.rb` — Module definition, load_directory.
- `lib/scout/workflow/python/task.rb` — python_task, metadata reading, type mapping.
- `lib/scout/workflow/python/inputs.rb` — build_python_argv.

See [PythonWorkflow Internals](PythonWorkflowInternals.md).

### Python `scout` package

**Responsibility:** Let Python code drive Scout workflows.

The Python `scout` package is the reverse bridge: it lets Python code call
Scout workflows. It does this by shelling out to the Ruby CLI. It also
provides TSV I/O, the `scout.task` decorator (which makes Python functions
discoverable by PythonWorkflow), and a remote workflow client.

Key files:
- `python/scout/__init__.py` — TSV IO, cmd, run_job.
- `python/scout/runner.py` — scout.task decorator, describe_function, CLI dispatch.
- `python/scout/workflow.py` — Workflow, Step (local).
- `python/scout/workflow/remote.py` — RemoteWorkflow, RemoteStep.

## Data flow

### Ruby → Python (in-process)

```
Ruby value
  │
  ├─ ScoutPython.run { pyimport :numpy; numpy.array(ruby_array) }
  │    │
  │    ├─ PyCall converts Ruby Array → Python list
  │    ├─ Python code executes
  │    └─ PyCall proxy returned to Ruby
  │
  └─ ScoutPython.tsv2df(tsv)
       │
       ├─ tsv.values, tsv.fields, tsv.keys extracted in Ruby
       ├─ pandas.DataFrame.new(values, columns, index)
       └─ PyCall proxy to DataFrame returned
```

### Ruby → Python (subprocess via script())

```
Ruby variables
  │
  ├─ ruby2python() serializes each to Python literal
  │    ├─ Array → [1, 2, 3]
  │    ├─ TSV → temp file + scout.tsv(filepath)
  │    └─ Hash → {key: value, ...}
  │
  ├─ script text + assignments + "save result" snippet
  │
  ├─ CMD.cmd_log("python script.py")
  │    └─ new Python process
  │
  └─ result loaded from temp file (pickle or JSON)
```

### Python → Ruby (CLI-based)

```
Python code
  │
  ├─ scout.cmd(ruby_code)
  │    ├─ subprocess.run('rbbt_exec.rb', input=...)
  │    └─ stdout returned as string
  │
  ├─ scout.Workflow(name).run(task, **inputs)
  │    ├─ save_job_inputs() writes inputs to files
  │    ├─ subprocess.run(['rbbt', 'workflow', 'task', ...])
  │    └─ stdout = result
  │
  └─ RemoteWorkflow(url).job(task, **inputs)
       ├─ POST url/task with inputs
       └─ GET url/info, url/result
```

## Dependencies

### External (Ruby gems)

- `pycall` — The Ruby↔Python bridge library.
- `python/pickle` — Ruby pickle parser, used by script() result loading.
- `scout-essentials` — Foundation: TSV, CMD, Log, Path, TmpFile, etc.

### External (Python packages)

- `numpy` — Required for numpy2ruby and array conversions.
- `pandas` — Required for TSV↔DataFrame conversion and TSV I/O.
- `requests` — Optional, for remote workflow client.

### Internal dependencies (Ruby → Ruby)

```
PythonWorkflow → ScoutPython (for run_file)
PythonWorkflow → Workflow (extends)
ScoutPython → PyCall (wraps)
ScoutPython → CMD, Log, TSV, TmpFile (from scout-essentials)
```

### Internal dependencies (Python → Ruby CLI)

```
scout.__init__ → rbbt_exec.rb (via cmd())
scout.workflow → rbbt (via run_job())
scout.runner → (standalone, run as script)
```

## Codebase statistics

| Language | Files | Lines (approx) |
|----------|-------|----------------|
| Ruby     | 8     | 705            |
| Python   | 4     | 934            |
| Total    | 12    | 1,639          |

The codebase is intentionally compact. Each file has a single,
well-defined responsibility. For deeper understanding of any subsystem,
refer to the [research artifacts](../../research/).

## See also

- [ScoutPython Internals](ScoutPythonInternals.md)
- [PythonWorkflow Internals](PythonWorkflowInternals.md)
- [Data Conversion Internals](DataConversionInternals.md)
- [Design Principles](DesignPrinciples.md)
- [Scout-essentials architecture](https://github.com/mikisvaz/scout-essentials/blob/main/doc/developer/Architecture.md)
