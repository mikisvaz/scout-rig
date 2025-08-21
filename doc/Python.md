# Python (ScoutPython)

ScoutPython is the bridge between Ruby (Scout) and Python. It provides:

- A thin, ergonomic layer on top of PyCall to execute Python code from Ruby (direct or in a dedicated thread).
- Import helpers and a safe “binding” scope that keeps Python names local to a call site.
- A small scripting facility to run ad‑hoc Python text, pass Ruby variables (including TSV) into Python, and return results.
- Data conversion helpers for numpy/list and pandas DataFrame to/from TSV.
- Path management to expose package Python modules to sys.path.
- A companion Python package (scout) with utilities for TSV IO and Workflow execution from Python, and a small remote Workflow client.

Sections:
- Requirements
- Path management
- Running Python code from Ruby
- Binding scopes and imports
- Scripting: run ad‑hoc Python text
- Iteration utilities
- Data conversion and pandas helpers
- Python-side helper package (scout)
  - Workflow wrapper (local)
  - Remote workflows over HTTP
- Error handling, logging, and threading
- API quick reference
- Examples

---

## Requirements

- Ruby gem: pycall (PyCall).
- Python 3 with:
  - pandas (for DataFrame helpers),
  - numpy (for numeric conversions),
- Ruby gems used in certain paths: python/pickle (for reading pickle files back into Ruby), json.

Make sure a Python3 interpreter is available in PATH.

---

## Path management

ScoutPython manages Python import paths and pre-populates them with known package Python dirs.

- Sources of Python paths:
  - Scout.python.find_all returns Python directories registered via the Path subsystem; these are added automatically at load time.
  - You can add more at runtime.

API:
```ruby
# Add one or many paths for Python imports
ScoutPython.add_path("/path/to/python/package")
ScoutPython.add_paths(%w[/opt/mypkg/py /usr/local/mytools/py])

# Apply registered paths to sys.path (idempotent; called on init and before run_simple)
ScoutPython.process_paths
```

process_paths executes in a Python context:
```ruby
ScoutPython.run_direct 'sys' do
  ScoutPython.paths.each { |p| sys.path.append p }
end
```

---

## Running Python code from Ruby

ScoutPython wraps PyCall to simplify imports and execution. The central methods accept optional import directives and a block of Python-interacting Ruby.

Imports argument forms:
- String/Symbol module only: pyimport "numpy"
- Array of names to import from module: pyfrom "module.submodule", import: [:Class, :func]
- Hash passed to pyimport (e.g., aliases): pyimport "numpy", as: :np

Methods:

- run(mod = nil, imports = nil) { ... }
  - Initialize PyCall once (init_scout), ensure paths, run block. Garbage collects after run.
- run_simple(mod = nil, imports = nil) { ... }
  - Same as run but without init_scout and extra GC. Synchronizes and calls process_paths.
- run_direct(mod = nil, imports = nil) { ... }
  - Run without synchronization; perform a single pyimport/pyfrom (if provided) and module_eval the block.
- run_threaded(mod = nil, imports = nil) { ... }
  - Execute in a dedicated background thread (see Threading below). Optional import executed in thread context.
- run_log(mod = nil, imports = nil, severity = 0, severity_err = nil) { ... }
  - Wrap the execution with Log.trap_std to capture/route Python stdout/stderr.
- run_log_stderr(mod = nil, imports = nil, severity = 0) { ... }
  - Capture only Python stderr via Log.trap_stderr.
- stop_thread
  - Stop the background Python thread, join/kill, GC, and PyCall.finalize (if available).

Examples:
```ruby
# Simple import and call
ScoutPython.run 'numpy', as: :np do
  a = np.array([1,2,3])
  a.sum         # => Py object; can call PyCall on it
end

# From submodule and alias
ScoutPython.run "tensorflow.keras.models", import: :Sequential do
  defined?(self::Sequential) # => true in this scope
end

# Threaded execution
arr = ScoutPython.run_threaded :numpy, as: :np do
  np.array([1,2])
end
ScoutPython.stop_thread
```

---

## Binding scopes and imports

Use a dedicated Binding (includes PyCall::Import) to localize imported names so they don’t leak into other scopes.

- new_binding → returns a Binding instance with PyCall::Import mixed in.
- binding_run(binding = nil, *args) { ... }
  - Create a new Binding, instance_exec the block, then discard.

Example (from tests):
```ruby
raised = false
ScoutPython.binding_run do
  pyimport :torch
  pyfrom :torch, import: ["nn"]
  begin
    torch
  rescue
    raised = true
  end
end
raised # => false (torch available inside)

raised = false
ScoutPython.binding_run do
  begin
    torch    # not defined in this fresh binding
  rescue
    raised = true
  end
end
raised # => true
```

Import helpers:
- import_method(module_name, method_name, as=nil) → Method
- call_method(module_name, method_name, *args)
- get_module(module_name) → imported module object (aliased safely as name with dots replaced by underscores)
- get_class(module_name, class_name)
- class_new_obj(module_name, class_name, args={}) → instantiate class with keyword args
- exec(script) → PyCall.exec(script) one-liner

---

## Scripting: run ad‑hoc Python text

script(text, variables = {}) runs a Python script in a subprocess and returns the value of the Python variable result. It:

- Serializes provided variables into Python assignments at the top of the script:
  - Ruby primitives (String, Numeric, true/false/nil) mapped to Python literals.
  - Arrays and Hashes transformed recursively.
  - TSV values are written to a temporary file and loaded using the companion Python function scout.tsv(file), yielding a pandas DataFrame.
- Appends a “save result” snippet to persist the result to a temporary file (default: Pickle).
- Executes the script with python3 via CMD.cmd_log, wiring PYTHONPATH from ScoutPython.paths.
- Loads the result back (default: pickled result via python/pickle gem) and returns it.

By default, pickle is used:
- save_script_result_pickle(file) → Python code to pickle.dump(result, file)
- load_pickle(file) → Ruby loads via Python::Pickle

Alternatively, you can alias to JSON-based persistence:
- save_script_result_json(file)
- load_json(file)
- Overwrite aliases if desired:
  ```ruby
  class << ScoutPython
    alias save_script_result save_script_result_json
    alias load_result load_json
  end
  ```

Examples (from tests):
```ruby
# Simple arithmetic
res = ScoutPython.script <<~PY, value: 2
  result = value * 3
PY
res # => 6

# Using pandas via the 'scout' Python helper
tsv = TSV.setup({}, "Key~ValueA,ValueB#:type=:list")
tsv["k1"] = %w[a1 b1]; tsv["k2"] = %w[a2 b2]

TmpFile.with_file(tsv.to_s) do |tsv_file|
  TmpFile.with_file do |target|
    res = ScoutPython.script <<~PY, file: tsv_file, target: target
      import scout
      df = scout.tsv(file)
      result = df.loc["k2", "ValueB"]
      scout.save_tsv(target, df)
    PY
    res # => "b2"
    TSV.open(target, type: :list)["k2"]["ValueB"] # => "b2"
  end
end

# Pass a TSV directly; script receives a pandas DataFrame
res = ScoutPython.script <<~PY, df: tsv, target: target
  result = df.loc["k2", "ValueB"]
  scout.save_tsv(target, df)
PY
```

Errors:
- If the Python subprocess fails (syntax error, exception), script raises ConcurrentStreamProcessFailed (via CMD and ConcurrentStream), with stderr logged if logging enabled.

---

## Iteration utilities

Helpers to traverse Python iterables from Ruby, with optional progress bars:

- iterate(iterator, bar: nil|true|String) { |elem| ... } → nil
  - Accepts PyCall iterable objects (with __iter__/__next__) or indexable sequences.
  - bar: true creates a default bar; String sets desc.
- iterate_index(sequence, bar: ...) { |elem| ... } → nil
  - Index-based loop using len and [i].
- collect(iterator, bar: ...) { |elem| block.call(elem) } → Array
  - Convenience to map Python iterables to Ruby arrays.

StopIteration is respected and terminates traversal. Errors mark the bar as error and re-raise.

---

## Data conversion and pandas helpers

Low-level converters:
- py2ruby_a(listlike) / to_a → convert PyCall::List-like into a Ruby Array.
- list2ruby(list) → deep-convert nested Py lists to Ruby arrays.
- numpy2ruby(numpy_array) → numpy.ndarray.tolist to Ruby arrays.
- obj2hash(py_mapping) → build a Ruby Hash by iterating keys and indexing values.

pandas ↔ TSV:
- tsv2df(tsv) → pandas.DataFrame with:
  - index: tsv.keys, columns: tsv.fields, df.columns.name = tsv.key_field.
- df2tsv(df, options = {})
  - Default options[:type] = :list
  - Builds a TSV with key_field = df.columns.name (or provided), fields from df.columns, and values from df rows.

Example (from tests):
```ruby
tsv = TSV.setup([], key_field: "Key", fields: %w(Value1 Value2), type: :list)
tsv["k1"] = %w(V1_1 V2_1)
tsv["k2"] = %w(V1_2 V2_2)

df = ScoutPython.tsv2df(tsv)
new_tsv = ScoutPython.df2tsv(df)
new_tsv == tsv # => true
```

---

## Python-side helper package (scout)

The repository also ships a small Python package named scout (python/scout), intended to be importable from Python code run by ScoutPython or independently.

Top-level utilities (scout/__init__.py):
- cmd(ruby_string=nil) → execute Ruby via rbbt_exec.rb; returns stdout.
- libdir() → resolve Ruby lib directory via cmd.
- add_libdir() → prepend libdir/python to sys.path.
- path(subdir=None, base_dir=None) → convenience location helper ("base" uses ~/.rbbt, "lib" uses libdir).
- read(subdir, base_dir=None) → read a file via path.
- inspect(obj) / rich(obj) → inspection helpers (rich requires rich).
- tsv_header/tsv_preamble/tsv_pandas(tsv_path, ...) → read TSV respecting Scout headers (:sep, :type, headers).
- tsv(*args, **kwargs) → alias to tsv_pandas.
- save_tsv(filename, df, key=None) → write pandas DataFrame to TSV with header and key (index_label).
- save_job_inputs(data: dict) → materialize Python values into files for Workflow inputs.
- run_job(workflow, task, name='Default', fork=False, clean=False, **kwargs) → shell out to CLI (`rbbt workflow task`) to execute or fork a job and return path or value.

Notes:
- The CLI used in run_job is named rbbt in this package; in Scout-based installs, a compatible executable should be available (often named scout). Setup a symlink or adjust if needed.

### Workflow wrapper (local)

Pythonic interface to run workflows and get results (python/scout/workflow.py):

- Workflow(name)
  - tasks() → list of task names.
  - task_info(name) → JSON string from Workflow.task_info.
  - run(task, **kwargs) → execute and return stdout (uses run_job).
  - fork(task, **kwargs) → submit with fork=True, return a Step(path).

- Step(path)
  - info() → job info (JSON parsed via Ruby Step.load(path).info).
  - status(), done(), error(), aborted()
  - join() → poll until completion.
  - load() → load job result via Ruby Step.load(path).load.

Example (python/test.py):
```python
if __name__ == "__main__":
    import sys
    sys.path.append('python')
    import scout
    import scout.workflow
    wf = scout.workflow.Workflow('Baking')
    step = wf.fork('bake_muffin_tray', add_blueberries=True, clean='recursive')
    step.join()
    print(step.load())
```

### Remote workflows over HTTP

A minimal client for remote Workflow services (python/scout/workflow/remote.py):

- RemoteWorkflow(url)
  - init_remote_tasks() → populate available tasks.
  - task_info(name) → JSON
  - job(task, **kwargs) → start a job, returns RemoteStep.

- RemoteStep(url)
  - info(), status()
  - done(), error(), running()
  - wait(time=1)
  - raw() → GET bytes of result
  - json() → GET JSON result

Requests are made via requests; results are obtained by GET/POST using a _format parameter (raw/json).

---

## Error handling, logging, and threading

- Logging:
  - run_log and run_log_stderr wrap execution in Log.trap_std/stderr; stdout/stderr lines are routed to the Scout Log with chosen severity.
- script:
  - Uses CMD.cmd_log to launch python3; stderr is logged; non-zero exit raises ConcurrentStreamProcessFailed on join (see CMD and ConcurrentStream docs).
- Threaded execution:
  - A dedicated thread processes queued blocks (Queue IN/OUT).
  - stop_thread sends a :stop sentinel, joins or kills the thread, triggers GC, and calls PyCall.finalize if available.
  - At exit, ScoutPython attempts to stop non-main threads, run GC while Python is still initialized, and touch PyCall.builtins.object to validate GIL access.

---

## API quick reference

Path management:
- ScoutPython.paths → Array of Python paths
- ScoutPython.add_path(path)
- ScoutPython.add_paths(paths)
- ScoutPython.process_paths

Execution:
- ScoutPython.run(mod=nil, imports=nil) { ... }
- ScoutPython.run_simple(mod=nil, imports=nil) { ... }
- ScoutPython.run_direct(mod=nil, imports=nil) { ... }
- ScoutPython.run_threaded(mod=nil, imports=nil) { ... }
- ScoutPython.stop_thread
- ScoutPython.run_log(mod=nil, imports=nil, severity=0, severity_err=nil) { ... }
- ScoutPython.run_log_stderr(mod=nil, imports=nil, severity=0) { ... }

Binding/import helpers:
- ScoutPython.new_binding
- ScoutPython.binding_run(binding=nil, *args) { ... }
- ScoutPython.import_method(module_name, method_name, as=nil)
- ScoutPython.call_method(module_name, method_name, *args)
- ScoutPython.get_module(module_name)
- ScoutPython.get_class(module_name, class_name)
- ScoutPython.class_new_obj(module_name, class_name, args={})
- ScoutPython.exec(script)

Iteration:
- ScoutPython.iterate(iterator, bar: nil|true|String) { |elem| ... }
- ScoutPython.iterate_index(sequence, bar: ...) { |elem| ... }
- ScoutPython.collect(iterator, bar: ...) { |elem| ... } → Array

Scripting:
- ScoutPython.script(text, variables={}) → result
- ScoutPython.save_script_result_pickle(file) / load_pickle(file)
- ScoutPython.save_script_result_json(file) / load_json(file)
- Aliases (defaults): save_script_result → pickle; load_result → load_pickle

Data conversion:
- ScoutPython.py2ruby_a(obj) / ScoutPython.to_a(obj)
- ScoutPython.list2ruby(list)
- ScoutPython.numpy2ruby(numpy_array)
- ScoutPython.obj2hash(py_mapping)
- ScoutPython.tsv2df(tsv) → pandas.DataFrame
- ScoutPython.df2tsv(df, options={}) → TSV

Python package (scout):
- scout.tsv(path, ...) → pandas DataFrame (header-aware)
- scout.save_tsv(path, df, key=None)
- scout.run_job(workflow, task, name='Default', fork=False, clean=False, **inputs) → job path or stdout
- scout.workflow.Workflow(name).run/fork/tasks/task_info
- scout.workflow.Step(path).info/status/join/load
- scout.workflow.remote.RemoteWorkflow/RemoteStep for HTTP services

---

## Examples

Direct PyCall use with imports:
```ruby
# Print sys.path in a background Python thread
ScoutPython.run_threaded :sys do
  paths = sys.path()
  puts paths
end
ScoutPython.stop_thread
```

Script with result:
```ruby
res = ScoutPython.script <<~PY, value: 2
  result = value * 3
PY
# => 6
```

Script with TSV and pandas:
```ruby
tsv = TSV.setup({}, "Key~ValueA,ValueB#:type=:list")
tsv["k1"] = ["a1", "b1"]; tsv["k2"] = ["a2", "b2"]

TmpFile.with_file do |target|
  res = ScoutPython.script <<~PY, df: tsv, target: target
    result = df.loc["k2", "ValueB"]
    scout.save_tsv(target, df)
  PY
  res # => "b2"
  TSV.open(target, type: :list)["k2"]["ValueB"] # => "b2"
end
```

Numpy conversion:
```ruby
ra = ScoutPython.run :numpy, as: :np do
  na = np.array([[[1,2,3], [4,5,6]]])
  ScoutPython.numpy2ruby(na)
end
ra[0][1][2] # => 6
```

pandas ↔ TSV:
```ruby
tsv = TSV.setup([], key_field: "Key", fields: %w(Value1 Value2), type: :list)
tsv["k1"] = %w(V1_1 V2_1)
tsv["k2"] = %w(V1_2 V2_2)

df = ScoutPython.tsv2df(tsv)
new_tsv = ScoutPython.df2tsv(df)
new_tsv == tsv # => true
```

Binding-local imports:
```ruby
ScoutPython.binding_run do
  pyimport :torch
  # torch is available here
end
# torch is not defined here
```

Python-side Workflow usage:
```python
import scout.workflow as sw

wf = sw.Workflow('Baking')
print(wf.tasks())
step = wf.fork('bake_muffin_tray', add_blueberries=True, clean='recursive')
step.join()
print(step.load())
```

---

ScoutPython gives you a compact, production-friendly toolbox to interoperate with Python: safe imports, threaded or synchronous execution, TSV/pandas integration, and Workflow orchestration from both Ruby and Python. Use run/script for quick integrations, the conversion helpers to pass data efficiently, and the Python scout package to drive Scout Workflows from Python environments.