# Python `scout` Package Analysis

> **Non-normative.** Investigation artifact.

## Overview

The Python `scout` package (`python/scout/`) is the Python-side companion
to scout-rig. It provides:

1. **TSV I/O** — Read and write Scout-style TSV files as pandas DataFrames.
2. **Workflow execution** — Run Scout workflows from Python via the CLI.
3. **Task definition** — Register Python functions as Scout-compatible tasks
   via `scout.task`.
4. **Remote workflows** — Interact with Scout REST workflow servers.

## Module layout

```
scout/
├── __init__.py       (231 lines)  # TSV I/O, cmd, run_job
├── runner.py         (536 lines)  # scout.task, describe_function, CLI dispatch
├── workflow.py       (64 lines)   # Workflow, Step (local)
└── workflow/
    └── remote.py     (103 lines)  # RemoteWorkflow, RemoteStep (HTTP)
```

## scout/__init__.py — Core utilities

### cmd(ruby_string)

Executes Ruby code via `rbbt_exec.rb`:

```python
def cmd(cmd=None):
    return subprocess.run('rbbt_exec.rb', input=cmd.encode('utf-8'),
                          capture_output=True).stdout.decode()
```

This is the foundational bridge: the entire `scout` Python package shells out
to the Ruby Scout CLI. Used by `libdir()`, `path()`, `Workflow.tasks()`,
`Step.info()`, etc.

**Note:** The command is hardcoded as `rbbt_exec.rb`. In Scout-based
installs, the binary may be named `scout` or `scout_exec`. This is a
potential portability issue (see Improvements).

### libdir()

```python
def libdir():
    return cmd('puts Rbbt.find(:lib)').rstrip()
```

Returns the Ruby library directory via the `Rbbt.find(:lib)` Path lookup.

### add_libdir()

Prepends `libdir() + '/python'` to `sys.path`, making the `scout` Python
package discoverable when running from Python scripts that aren't already
in the path.

### path / read

`path(subdir, base_dir)` resolves paths using Scout's `Rbbt` conventions:
- `base_dir='base'` → `~/.rbbt`
- `base_dir='lib'` → `libdir()`
- default: tries `lib` first, then `base`

`read(subdir, base_dir)` reads a file at the resolved path.

### TSV I/O

The TSV reading functions parse Scout-style TSV headers:

- **Preamble line** (`#:key=value#...`): Parsed into a dict (e.g., type, sep).
- **Header line** (`#Key\tField1\tField2`): Extracts field names and key field.
- **Flat TSV**: Single-column files with custom separator.

Functions:
- `tsv_header(filename)` — Parse header metadata.
- `tsv_preamble(line)` — Parse preamble key=value entries.
- `tsv_pandas(filename, **kwargs)` — Read TSV into pandas DataFrame, respecting
  header metadata.
- `tsv(*args, **kwargs)` — Alias for `tsv_pandas`.
- `save_tsv(filename, df, key=None)` — Write DataFrame to Scout-style TSV.

**Header format example:**
```
#:type=:list#:sep=:
#Key	Field1	Field2
k1	v1	v2
```

### save_job_inputs(data)

Materializes Python values into files in a temp directory, suitable for
Scout's `--load_inputs` CLI option:

| Python type       | File extension | Format                     |
|-------------------|----------------|----------------------------|
| `str`             | `.txt`         | Raw string                 |
| `bool`            | (none)         | `true` or `false`          |
| `int` / `float`   | (none)         | String representation      |
| `pandas.DataFrame`| `.tsv`         | Scout-style TSV (via save_tsv) |
| `list` / `ndarray`| `.list`        | Newline-separated          |

**Observation:** The file naming uses the input name directly (e.g., input
`add_blueberries` becomes file `add_blueberries` with no extension for bool,
`.txt` for str). Scout's `--load_inputs` expects this convention.

### run_job(workflow, task, ...)

Shells out to the Scout CLI:

```python
cmd = ['rbbt', 'workflow', 'task', workflow, task,
       '--jobname', jobname, '--load_inputs', inputs_dir, '--nocolor']
```

Options:
- `fork=True` → `--fork --detach` (async execution).
- `exec=True` → `--exec`.
- `clean` → `--clean` or `--recursive_clean`.

Returns `proc.stdout.strip()`. On error, raises `RuntimeError` with stderr.

**Note:** Hardcoded as `rbbt` command. See portability note above.

## scout/runner.py — Task definition

This is the largest and most complex file (536 lines). It provides:

### describe_function(func)

Introspects a Python function's signature and docstring to produce a
metadata dict:

```json
{
  "name": "hello",
  "description": "Greet a user.",
  "returns": "string",
  "params": [...]
}
```

Key logic:
- `_python_type_to_string(ann)` — Maps Python type annotations to Scout type strings.
- `_parse_numpy_params(doc)` — Parses Google-style `Args:` sections (preferred)
  or NumPy-style `Parameters` sections (fallback).
- `_extract_description(docstring)` — Extracts the docstring preamble (everything
  before `Args:`/`Parameters`/etc.).
- `_required_from_default(default, ann)` — Determines if a parameter is required
  (no default, not `Optional[T]`).

### Type annotation mapping

| Python annotation        | Scout type string |
|--------------------------|-------------------|
| `str` / `bytes`          | `string` / `binary` |
| `int`                    | `integer`         |
| `float`                  | `float`           |
| `bool`                   | `boolean`         |
| `pathlib.Path`           | `path`            |
| `List[str]`              | `list[string]`    |
| `List[int]`              | `list[integer]`   |
| `Optional[T]` (= `T | None`) | Type of `T` (required=False) |
| No annotation            | `string`          |

### scout.task(func)

The `task` function serves two purposes:
1. Introspects the function and stores metadata via `func.__scout_meta__`.
2. Registers the function in `_SCOUT_TASK_REGISTRY`.

If the defining module is `__main__` (the file is run as a script), it
registers an `atexit` handler that handles CLI dispatch.

### CLI dispatch (_scout_run_deferred)

When a Python file with `scout.task` is run as a script:

1. If `--scout-metadata` in argv: print JSON of all registered metas and exit.
2. If `-h`/`--help`: show argparse help for the selected function.
3. Otherwise: parse args via argparse and call the function.

For multi-function files, the first positional argument selects the function.
If no positional arg is given, the last registered task is used as default.

### Output serialization (_run_cli)

The function's return value is serialized to stdout:
- `bytes` → raw to stdout.buffer.
- `str/int/float/bool/None` → `print()`.
- `list/tuple` → newline-separated items.
- Other → JSON dump (`json.dumps(result, default=str)`).

This serialization is what the Ruby side decodes in `python_task` execution.

## scout/workflow.py — Local workflow wrapper

### Workflow(name)

- `tasks()` → list of task names (via Ruby `Workflow.require_workflow(name).tasks.keys`).
- `task_info(name)` → JSON string from Ruby.
- `run(task, **kwargs)` → calls `run_job`, returns stdout.
- `fork(task, **kwargs)` → calls `run_job` with `fork=True`, returns `Step(path)`.

### Step(path)

- `info()` → Ruby `Step.load(path).info.to_json`.
- `status()`, `done()`, `error()`, `aborted()` → convenience accessors.
- `join()` → poll until done/error/aborted (1s sleep).
- `load()` → Ruby `Step.load(path).load.to_json` → JSON parse.

## scout/workflow/remote.py — HTTP workflow client

### RemoteWorkflow(url)

- `init_remote_tasks()` → GET the workflow URL, parse task list.
- `task_info(name)` → GET `url/name/info`.
- `job(task, **kwargs)` → POST `url/task` with params, returns `RemoteStep`.

### RemoteStep(url)

- `info()` → GET `url/info` as JSON.
- `status()`, `done()`, `error()`, `running()`, `wait()`.
- `raw()` → GET result as raw bytes.
- `json()` → GET result as JSON.

Uses the `_format` query parameter (`json` or `raw`) to control response format.

## Key findings

1. **The `scout` package is a thin CLI wrapper** — It shells out to `rbbt` /
   `rbbt_exec.rb` for all Ruby-side operations. No persistent Ruby process
   is kept alive.

2. **`scout.task` is both a decorator and a registration mechanism** — It
   works as `@scout.task` (decorator) or `scout.task(func)`. The metadata
   extraction is the same either way.

3. **Multi-function CLI dispatch is deferred to atexit** — This ensures all
   functions in the file are registered before dispatch. Clever but
   potentially confusing for debugging.

4. **Hardcoded command names** — `rbbt_exec.rb` and `rbbt` are hardcoded.
   Scout installs may use `scout` or `scout_exec` instead. This is a
   portability concern.

5. **`save_job_inputs` is a bridge for `--load_inputs`** — It materializes
   Python values into the file format Scout expects for inputs. This is
   essential for the Python-side `run_job` to work correctly.

6. **RemoteWorkflow is minimal** — It's a thin HTTP client that speaks the
   Scout REST API. No authentication, no retry, no timeout configuration.

7. **Google-style docstrings preferred** — The metadata extractor prefers
   Google-style `Args:` sections over NumPy-style `Parameters`. This is for
   better interoperability with LLM tool schemas.

8. **`save_inputs` in workflow.py is a no-op** — `def save_inputs(directory,
   inputs, types): return`. This is dead code that was never implemented.
