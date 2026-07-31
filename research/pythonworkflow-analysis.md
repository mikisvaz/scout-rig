# PythonWorkflow Analysis

> **Non-normative.** Investigation artifact.

## Overview

PythonWorkflow (`lib/scout/workflow/python.rb` + sub-files) is a Ruby module
that lets workflow authors define Scout tasks whose logic is implemented in
Python. The Python function's signature (type hints, defaults, docstring)
is introspected at workflow definition time to automatically create the
corresponding Scout inputs and task declarations.

## Architecture

```
PythonWorkflow (lib/scout/workflow/python.rb)
  ├── load_directory           # Load all .py files from a directory
  ├── inputs.rb
  │   └── build_python_argv    # Build CLI args from Ruby values
  └── task.rb
      ├── read_python_metadata # Run python file --scout-metadata
      ├── map_returns          # Python return type → Scout return type
      ├── map_param            # Python param → Scout input
      └── python_task          # Define a Scout task from a Python file
```

## Lifecycle: From Python function to Scout task

### Phase 1: Metadata discovery (workflow definition time)

When you call `python_task :hello`, the following happens:

1. Locate the Python file:
   - If `file:` option is given, use it directly.
   - Otherwise, look in `python_task_dir[task_name].find_with_extension('py')`.
   - `python_task_dir` defaults to `Scout.python.task.find(:lib)`.

2. Run the Python file with `--scout-metadata`:
   ```ruby
   out = ScoutPython.run_file file, '--scout-metadata'
   metas = JSON.parse(out.read)
   ```

3. Parse the metadata JSON. Each metadata object has:
   ```json
   {
     "name": "hello",
     "description": "Greet a user.",
     "returns": "string",
     "params": [
       {"name": "name", "type": "string", "required": true, "default": null, "help": "..."},
       {"name": "excited", "type": "boolean", "required": false, "default": false, "help": "..."}
     ]
   }
   ```

4. For each metadata object (the Python file may define multiple functions):
   - Map the return type via `map_returns`.
   - Map each param via `map_param` to a Scout input declaration.
   - Declare the task via `task(name => return_type) { ... }`.

### Phase 2: Task execution (job run time)

When a Python-backed task job is run:

1. Collect input values from the job.
2. Build CLI argv via `PythonWorkflow.build_python_argv(meta['params'], values)`.
3. Prefix with the function name: `[meta['name']] + argv`.
4. Execute: `ScoutPython.run_file(file, Shellwords.shelljoin(full_argv))`.
5. Decode the return value:
   - Try `JSON.parse(txt)`.
   - If JSON parse fails and return type is `:array`/`:file_array`, split
     on newlines.
   - Otherwise, return stripped text.

## Type mapping

### Python type → Scout input type (map_param)

| Python type string | Scout input type |
|--------------------|------------------|
| `string`           | `:string`        |
| `integer`          | `:integer`       |
| `float`            | `:float`         |
| `boolean`          | `:boolean`       |
| `binary`           | `:binary`        |
| `path`             | `:file`          |
| `list[string]`     | `:array`         |
| `list[integer]`    | `:array`         |
| `list[float]`      | `:array`         |
| `list[path]`       | `:file_array`    |
| (other)            | `:string`        |

### Python return type → Scout return type (map_returns)

| Python type string | Scout return type |
|--------------------|-------------------|
| `nil` / `string`   | `:string`         |
| `integer`          | `:integer`        |
| `float`            | `:float`          |
| `boolean`          | `:boolean`        |
| `binary`           | `:binary`         |
| `path`             | `:string`         |
| `list`, `array`    | `:array`          |
| `list[...]`        | `:array`          |
| (other)            | `:string`         |

### build_python_argv (inputs.rb)

This method translates Ruby input values into CLI arguments for the Python
script. Key behaviors:

- **nil values**: Skipped (no flag emitted).
- **booleans**: For boolean params with default `true`, the flag is emitted
  as `--name` or `--no-name`. For default `false`, the flag is `--name` if
  value is true, nothing if false.
- **list/array values**: If the Ruby value is a String, it is split by comma.
  If it is a file path that exists, the file is read line-by-line. If it
  is an Array, each element is passed as a repeated `--name value`.
- **path/file types**: Passed as-is (the Python side handles them).
- **scalars**: Passed as `--name value`.

**Observation:** The boolean handling logic is complex. For booleans with
default `true`, it uses the value directly. For booleans with default
`false`, it only emits the flag if the value is true. This mimics
argparse's `BooleanOptionalAction` (for default true) and `store_true`
(for default false) on the Python side.

## Multi-function files

A single Python file can register multiple functions with `scout.task`:

```python
import scout

@scout.task
def add(a: int, b: int) -> int:
    return a + b

@scout.task
def multiply(a: float, b: float) -> float:
    return a * b
```

When `python_task :math` is called, `read_python_metadata` returns an array
of metadata objects (one per function). The Ruby side iterates over all
metadata objects and creates one Scout task per function. This means a single
`python_task` call can create multiple tasks.

At execution time, the function name is passed as the first positional
argument to the Python script so the runner knows which function to dispatch
to.

## Key findings

1. **Metadata-driven design is elegant** — The Python function signature
   fully drives the Scout task declaration. No manual input declarations
   are needed on the Ruby side.

2. **CLI-based execution provides isolation** — Each task run spawns a new
   Python process, avoiding GIL contention and state leakage between tasks.
   This is slower but safer than in-process execution.

3. **Return value decoding is heuristic** — Ruby tries JSON first, then
   falls back to line-splitting for arrays or plain text. This works for
   most cases but could fail for edge cases where a string return value
   happens to be valid JSON.

4. **The `python_task_dir` defaults to `Scout.python.task.find(:lib)`** —
   This uses the Scout Path subsystem to locate Python task files shipped
   with the gem. Override with `self.python_task_dir = path` for custom
   locations.

5. **No caching of metadata** — `read_python_metadata` is called every time
   `python_task` is invoked. Since the Python file must be executed, this
   is a subprocess call per task at definition time. For workflows with
   many tasks, this could be slow.

6. **`load_directory`** (`python.rb`) — Discovers all `.py` files in a
   directory and registers each as a `python_task`. Sets
   `python_task_dir` to the directory. Uses `path.glob_names("*.py")`,
   which requires `path` to be a Scout `Path` object.

7. **Potential issue: string split for list values** — In
   `build_python_argv`, if a list input has a Ruby String value, it is
   split by comma. But if the string value contains commas as part of the
   data (not as delimiters), this would incorrectly split it. Using a file
   or Ruby Array avoids this.

8. **Error messages** — `read_python_metadata` raises with the raw error
   variable `err` which is never assigned. The error message would be
   misleading. See Improvements.
