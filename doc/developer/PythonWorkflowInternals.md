# PythonWorkflow Internals

This document explains how `python_task` works internally: how Python
function metadata is discovered, how types are mapped, and how tasks are
executed at runtime.

## Audience

This page is intended for:

- ✓ Framework contributors
- ✗ Workflow authors (see [Defining Python Tasks](../user/DefiningPythonTasks.md))

## Why this exists

The challenge PythonWorkflow solves is: **how do you make a Python function
into a Scout task without requiring the user to redeclare inputs on both
sides?**

The solution is **metadata-driven task definition**. The Python function's
signature (type hints, defaults) and docstring (parameter descriptions) are
introspected at workflow definition time, automatically producing the Scout
task declaration.

## Architecture

```
                    Workflow definition time
                    ────────────────────────
Ruby:  python_task :hello
          │
          ▼
Ruby:  read_python_metadata(file)  ───► Python subprocess: file.py --scout-metadata
          │                                      │
          │ JSON parse                           │ describe_function()
          ▼                                      │ (runner.py: introspect signature + docstring)
Ruby:  metas = [{name, description, returns, params}, ...]
          │
          ▼
Ruby:  For each meta:
        - map_returns(meta['returns']) → Scout return type
        - For each param: map_param → Scout input
        - task(name => return_type) { ... }


                    Task execution time
                    ───────────────────
Ruby:  job.run
          │
          ▼
Ruby:  build_python_argv(params, job.input_values)  ───► CLI argv
          │
          ▼
Ruby:  ScoutPython.run_file(file, arg_str)  ───► Python subprocess
          │
          │ stdout = return value
          ▼
Ruby:  decode result (JSON → array split → string)
```

## Phase 1: Metadata discovery

### read_python_metadata(file)

```ruby
def self.read_python_metadata(file)
  out = ScoutPython.run_file file, '--scout-metadata'
  raise "Error getting metadata for #{File.basename(file)}: #{err}"
    unless out.exit_status == 0

  metas = JSON.parse(out.read)
  metas
end
```

This runs the Python file as a subprocess with `--scout-metadata`. The
Python `scout.runner` module handles this flag:

```python
# runner.py: _scout_run_deferred (atexit handler)
if '--scout-metadata' in sys.argv:
    metas = [getattr(func, '__scout_meta__', None)
             for func in _SCOUT_TASK_REGISTRY]
    print(json.dumps(metas))
    os._exit(0)
```

The metadata is a list of dicts, one per registered function.

### Metadata structure

Each metadata dict from Python has:

```json
{
  "name": "hello",
  "function_name": "hello",
  "description": "Greet a person.",
  "returns": "string",
  "params": [
    {"name": "name", "type": "string", "required": true, "default": null, "help": "..."},
    {"name": "excited", "type": "boolean", "required": false, "default": false, "help": "..."}
  ]
}
```

## Phase 2: Type mapping

### map_param(param)

Maps a Python parameter to a Scout input type declaration.

| Python type string | Scout type |
|--------------------|------------|
| `string`, `str`    | `:string`  |
| `integer`, `int`   | `:integer` |
| `float`            | `:float`   |
| `task`             | `:task`    |
| `boolean`, `bool`  | `:boolean` |
| `binary`           | `:binary`  |
| `path`             | `:file`    |
| `list[string]`     | `:array`   |
| `list[integer]`, `list[int]` | `:array` |
| `list[float]`      | `:array`   |
| `list[path]`       | `:file_array` |
| (other)            | `:string`  |

### map_returns(return_type)

Maps a Python return annotation to a Scout task return type.

| Python type string | Scout type |
|--------------------|------------|
| `nil`, `null`, `string` | `:string` |
| `integer`, `int`   | `:integer` |
| `float`            | `:float`   |
| `boolean`, `bool`  | `:boolean` |
| `binary`           | `:binary`  |
| `path`             | `:string`  |
| `list`, `array`    | `:array`   |
| `list[...]`        | `:array`   |
| (other)            | `:string`  |

**Note:** `path` returns map to `:string` (not `:file`) because the path
value is a string result, not a file input. See [Improvements](../Improvements.md)
for a discussion.

## Phase 3: Task declaration

For each metadata object, PythonWorkflow declares a Scout task:

```ruby
python_task :hello  # reads metadata for all functions in hello.py
```

For a multi-function file, this creates one task per function. The task
body is defined in a block that executes the Python function as a
subprocess.

### Task file discovery

`python_task` locates the Python file using:

1. `file:` option if provided.
2. Otherwise, `python_task_dir[task_name].find_with_extension('py')`.

`python_task_dir` defaults to `Scout.python.task.find(:lib)`, which uses
the Scout Path subsystem to locate Python task files shipped with the gem.

## Phase 4: Execution

### build_python_argv(params, values)

Translates Ruby input values into CLI arguments for the Python script.

Key behaviors:

| Input type | Ruby value handling |
|------------|---------------------|
| nil        | Skipped (no flag) |
| boolean (default false) | `--name` if true, nothing if false |
| boolean (default true)  | `--name` or `--no-name` |
| list/array (String value) | Split by comma |
| list/array (file path) | Read file line-by-line |
| list/array (Array value) | Repeated `--name value` |
| path/file   | Passed as-is |
| scalar      | `--name value` |

**Boolean logic:** The logic mimics argparse's `BooleanOptionalAction`
(default true) and `store_true` (default false).

### run_file

```ruby
ScoutPython.run_file(file, arg_str)
# → CMD.cmd("env PYTHONPATH=... python '#{file}' #{arg_str}")
```

### Return value decoding

The Python function's return value is printed to stdout. Ruby decodes it:

```ruby
txt = run_output.read
begin
  JSON.parse(txt)
rescue
  if ruby_returns == :array || ruby_returns == :file_array
    txt.split("\n").map(&:to_s)
  else
    txt.strip
  end
end
```

The heuristic is:
1. Try JSON first (handles dicts, nested lists, numbers, booleans).
2. If JSON fails and return type is array, split on newlines.
3. Otherwise, return stripped text.

## Key design decisions

1. **Metadata-driven, not attribute-driven** — Task definition is driven by
   Python function metadata, not by Ruby-side configuration. This eliminates
   double-declaration.

2. **Subprocess execution** — Each task run spawns a new Python process.
   This is slower than in-process but avoids GIL contention, memory leaks,
   and state contamination between tasks.

3. **CLI-first communication** — Communication between Ruby and Python is
   via CLI arguments (inputs) and stdout (return value). This is the Unix
   philosophy: text as the universal interface.

3b. **Multi-function files** — A single Python file can define multiple
   tasks. The first positional argument in the CLI argv selects the function.

4. **Heuristic return decoding** — JSON is tried first (handles structured
   data), with fallbacks for arrays (newline-split) and plain text. This
   covers the vast majority of use cases.

5. **Type mapping mirrors Python annotations** — The mapping table is a
   straightforward mapping from Python type strings to Scout types. The
   Python side produces type strings via `describe_function`.

## Known issues

1. **Unused `err` variable** — In `read_python_metadata`:
   ```ruby
   raise "Error getting metadata for #{File.basename(file)}: #{err}"
   ```
   `err` is never assigned. The error message will show `nil` for the error
   detail. See [Improvements](../Improvements.md).

2. **No metadata caching** — `read_python_metadata` runs a Python subprocess
   every time `python_task` is called. For workflows with many Python tasks,
   this could be slow at definition time.

3. **String split ambiguity** — In `build_python_argv`, list inputs with
   string values are split by comma. If the string contains commas as data,
   this would incorrectly split it.

4. **Return decoding ambiguity** — If a string return value happens to be
   valid JSON, it will be JSON-parsed instead of returned as-is.

5. **path return maps to :string** — `path` returns map to `:string` in
   Scout. This may cause issues if the workflow expects a file result type.

## See also

- [Architecture](Architecture.md) — Overall module map.
- [ScoutPython Internals](ScoutPythonInternals.md) — The run_file mechanism.
- [Defining Python Tasks](../user/DefiningPythonTasks.md) — User-facing guide.
