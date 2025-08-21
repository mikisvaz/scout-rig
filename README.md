# scout-rig

scout-rig provides the language interop “rigging” for the Scout ecosystem. It currently focuses on Python: executing Python from Ruby, round‑tripping data (TSV ↔ pandas), and running Scout Workflows from Python code. It builds on the low-level/core packages:

- scout-essentials — low level utilities (Annotation, CMD, ConcurrentStream, IndiferentHash, Log, Open, Path, Persist, TmpFile)
- scout-gear — data and workflow primitives (TSV, Workflow, KnowledgeBase, Association, Entity, WorkQueue, Semaphore)
- scout-rig — interop with other languages (currently Python)
- scout-camp — remote servers, cloud deployments, web interfaces, cross-site operations
- scout-ai — model training and agentic tools

All packages are available on GitHub under https://github.com/mikisvaz (for example, https://github.com/mikisvaz/scout-gear).

For broader background and many real workflow examples, see Rbbt (the bioinformatics framework from which Scout was refactored) and the Rbbt-Workflows organization:
- https://github.com/mikisvaz/rbbt
- https://github.com/Rbbt-Workflows

This README focuses on the Python bridge in scout-rig (ScoutPython). See the docs in doc/ for reference material.

- doc/Python.md — ScoutPython user guide

---

## What you get

ScoutPython (Ruby) and a companion Python package (python/scout) provide:

- Safe, ergonomic execution of Python code from Ruby (PyCall-based), with:
  - Simple import helpers and localized bindings
  - Synchronous, direct, or background-thread execution
  - Logging wrappers that capture Python stdout/stderr
- Scripting to run ad‑hoc Python text with Ruby variables (including TSV) injected, and results returned
- Data conversion helpers:
  - numpy arrays → Ruby Arrays
  - pandas DataFrame ↔ TSV (key_field, fields, type respected)
- Python path management (expose package python/ dirs to sys.path)
- Python‑side helpers to:
  - Read/write TSVs with headers (pandas)
  - Run Ruby Workflows from Python
  - Call remote Workflow services over HTTP

---

## Installation and requirements

Ruby
- Ruby 2.6+ (or compatible with PyCall)
- Gems:
  - pycall (PyCall)
  - json (standard)
  - Optional for script result loading:
    - python/pickle (gem) for loading pickle from Python scripts

Python
- Python 3
- Packages:
  - pandas
  - numpy
  - requests (only for remote workflow client)
- Ensure python3 is in PATH

Add scout-rig to your Ruby project (Gemfile or local checkout), then ensure Python dependencies are installed in your Python environment.

---

## Quick start

Execute Python directly from Ruby:

```ruby
require 'scout_python'

# Sum with numpy
arr_sum = ScoutPython.run 'numpy', as: :np do
  np.array([1,2,3]).sum
end
# => PyObject (to_i if needed)

# Background thread execution
ScoutPython.run_threaded :sys do
  sys.path.append('/opt/my_py_pkg')
end
ScoutPython.stop_thread
```

Run an ad‑hoc Python script, returning a result value:

```ruby
tsv = TSV.setup({}, "Key~ValueA,ValueB#:type=:list")
tsv["k1"] = %w[a1 b1]; tsv["k2"] = %w[a2 b2]

TmpFile.with_file do |target|
  result = ScoutPython.script <<~PY, df: tsv, target: target
    import scout
    # df is a pandas DataFrame (tsv injected)
    result = df.loc["k2", "ValueB"]
    scout.save_tsv(target, df)  # save as TSV with header
  PY

  # result is "b2"; target holds a TSV round-tripped from pandas
end
```

Convert between TSV and pandas:

```ruby
df = ScoutPython.tsv2df(tsv)      # TSV -> pandas DataFrame
tsv2 = ScoutPython.df2tsv(df)     # pandas DataFrame -> TSV
```

Run a Workflow from Python:

```python
import sys
sys.path.append('python')  # add this repo's python/ on dev checkouts

import scout.workflow as sw

wf = sw.Workflow('Baking')
print(wf.tasks())
step = wf.fork('bake_muffin_tray', add_blueberries=True, clean='recursive')
step.join()
print(step.load())         # load Ruby job result
```

---

## Core concepts

### Path management for Python imports

ScoutPython tracks Python directories to add to sys.path:

- ScoutPython.add_path(path) / add_paths(paths)
- ScoutPython.process_paths  # idempotent; run before/inside sessions

These are applied in Python contexts by run/run_simple/run_direct.

### Running Python from Ruby

Pick the execution model that fits:

- run(mod = nil, imports = nil) { ... }
  - Initialize PyCall if needed, set up paths, run block; GC after run
- run_simple(mod = nil, imports = nil) { ... }
  - Lightweight; process_paths, then run block
- run_direct(mod = nil, imports = nil) { ... }
  - Minimal overhead: optional single pyimport/pyfrom, then evaluate
- run_threaded(mod = nil, imports = nil) { ... }
  - Queue work into a dedicated Python thread; stop with stop_thread

Logging wrappers capture Python’s stdout/stderr via the Scout Log:

- run_log(mod=nil, imports=nil, severity=Log::LOW, severity_err=nil) { ... }
- run_log_stderr(mod=nil, imports=nil, severity=Log::LOW) { ... }

Imports
- Pass 'numpy', as: :np or "module.submodule", import: [:Class, :func]

### Binding scopes and imports

Keep imports local to a binding:

```ruby
ScoutPython.binding_run do
  pyimport :torch
  pyfrom :torch, import: ['nn']
  # torch and nn available here only
end
```

Helpers
- new_binding, binding_run
- import_method, call_method
- get_module, get_class, class_new_obj
- exec(script) → PyCall.exec

### Scripting

Run arbitrary Python text with Ruby variables injected:

- ScoutPython.script(text, variables = {}) → result
  - Ruby primitives → Python literals
  - Arrays/Hashes → recursively converted
  - TSV variables → materialized to temp file and loaded into pandas via the python/scout helper
  - result is read back via pickle (default) or JSON (configurable)

Swap result serializer if desired:

```ruby
class << ScoutPython
  alias save_script_result save_script_result_json
  alias load_result        load_json
end
```

### Iteration utilities

Traverse Python iterables with optional progress bars:

- iterate(iterator, bar: nil|true|String) { |elem| ... }
- iterate_index(sequence, bar: ...) { |elem| ... }
- collect(iterator, bar: ...) { |elem| ... } → Array

### Data conversion and pandas helpers

- numpy2ruby(numpy_array)
- to_a/py2ruby_a(py_list)
- obj2hash(py_mapping)
- tsv2df(tsv) / df2tsv(df, options={type: :list, key_field: ...})

---

## Python-side package (python/scout)

The included Python package is importable as scout and provides:

General utilities
- scout.libdir(), scout.add_libdir()
- scout.path(), scout.read()
- scout.inspect(obj), scout.rich(obj)

TSV IO (pandas-aware)
- scout.tsv(tsv_path_or_stream, ...) → pandas.DataFrame (Scout headers respected)
- scout.save_tsv(filename, df, key=None)

Workflow wrappers
- scout.run_job(workflow, task, name='Default', fork=False, clean=False, **inputs)
  - Shells out to the Ruby CLI to execute/fork jobs
- scout.workflow.Workflow(name).run/fork/tasks/task_info
- scout.workflow.Step(path).info/status/join/load

Remote workflows (HTTP)
- scout.workflow.remote.RemoteWorkflow(url).job/task_info
- scout.workflow.remote.RemoteStep(url).status/wait/raw/json

---

## Error handling and threading

- Python process errors from script are surfaced as ConcurrentStreamProcessFailed (non‑zero exit), with stderr logged via Log if a logging wrapper is used
- Background thread execution must be stopped explicitly:
  - ScoutPython.stop_thread — sends a sentinel, tries to join/kill, GCs, and finalizes PyCall if available

---

## Command line usage and discovery

Scout commands are discovered under scout_commands across installed packages using the Path subsystem. The dispatcher resolves nested commands by adding terms until a file is found to execute; if you stop on a directory, it lists available subcommands.

- General pattern:
  - scout <top-level> [<subcommand> ...] [options] [args...]
- Examples relevant to Python integration (executed from Ruby CLI but callable from Python via scout.run_job):
  - scout workflow task <Workflow> <task> [task-input-options...]
  - scout workflow prov <step_path>
  - scout workflow info <step_path>

Notes
- The bin/scout launcher walks scout_commands/… across packages; Workflows and other packages can add their own commands and they will be discovered
- See the Workflow, TSV, and KnowledgeBase docs for their CLI suites:
  - TSV: scout tsv …
  - Workflow: scout workflow …
  - KnowledgeBase: scout kb …

scout-rig itself does not register standalone CLI commands; instead, its Python wrapper invokes the existing Ruby CLI to run jobs from Python.

---

## Reference

Read the full module guide in doc/Python.md. For core building blocks referenced above, see these docs in scout-essentials and scout-gear:

- Annotation.md, CMD.md, ConcurrentStream.md, IndiferentHash.md, Log.md, Open.md, Path.md, Persist.md, TmpFile.md
- TSV.md, Workflow.md, KnowledgeBase.md, Association.md, Entity.md, WorkQueue.md, Semaphore.md

---

## Examples

Direct PyCall with imports:

```ruby
ScoutPython.run 'numpy', as: :np do
  a = np.array([1,2,3])
  a.sum            # PyObject; convert with to_i if needed
end
```

Script with a returned value and TSV round‑trip:

```ruby
tsv = TSV.setup({}, "Key~ValueA,ValueB#:type=:list")
tsv["k1"] = ["a1", "b1"]; tsv["k2"] = ["a2", "b2"]

TmpFile.with_file do |target|
  result = ScoutPython.script <<~PY, df: tsv, target: target
    import scout
    result = df.loc["k2", "ValueB"]
    scout.save_tsv(target, df)
  PY
  # result == "b2"; target contains the saved TSV
end
```

numpy conversion:

```ruby
ra = ScoutPython.run :numpy, as: :np do
  na = np.array([[[1,2,3], [4,5,6]]])
  ScoutPython.numpy2ruby(na)
end
ra[0][1][2] # => 6
```

Run workflows from Python:

```python
import scout.workflow as sw

wf = sw.Workflow('Baking')
step = wf.fork('bake_muffin_tray', add_blueberries=True, clean='recursive')
step.join()
print(step.load())
```

---

## Project links

- scout-essentials — https://github.com/mikisvaz/scout-essentials
- scout-gear — https://github.com/mikisvaz/scout-gear
- scout-rig — https://github.com/mikisvaz/scout-rig
- scout-camp — https://github.com/mikisvaz/scout-camp
- scout-ai — https://github.com/mikisvaz/scout-ai
- Rbbt — https://github.com/mikisvaz/rbbt
- Rbbt-Workflows — https://github.com/Rbbt-Workflows

Contributions and issues are welcome in their respective GitHub repositories.