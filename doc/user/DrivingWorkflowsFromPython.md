# Driving Workflows from Python

This document explains how to use the Python `scout` package to run Scout
workflows from Python code, both locally (via the Ruby CLI) and remotely
(via HTTP).

## Audience

This page is intended for:

- ✓ Python developers who want to use Scout workflows
- ✓ Agent developers building Python-side workflow clients
- ✗ Framework contributors

## When to use this

Use the Python `scout` package when:

- You're working primarily in Python and need to call Scout workflows.
- You want to drive Scout workflows from a Jupyter notebook.
- You're building a Python application that uses Scout for computation.
- You need to interact with a remote Scout workflow server over HTTP.

## Core concepts

The Python `scout` package is a **thin CLI wrapper**. It does not embed the
Ruby runtime — it shells out to the Scout CLI (`rbbt` / `rbbt_exec.rb`) for
all operations. This means:

- You need Scout and Rbbt installed and available on your PATH.
- The package is not a replacement for the Ruby stack.
- Performance is bounded by CLI process startup time.

Every Ruby call the package makes is a fresh subprocess: `scout.cmd()` runs
`rbbt_exec.rb` with the Ruby source on stdin, and `run_job()` runs
`rbbt workflow task ...`. There is no persistent Ruby process, so a
`Workflow` object is pure state — `wf.tasks()` and `wf.task_info()` shell out
each time they are called.

Both `numpy` and `pandas` are imported at module import time, so
`import scout` fails if either is missing; the two are hard requirements of
the local package, not conveniences.

## Installation

```bash
pip install "scout-rig @ git+https://github.com/mikisvaz/scout-rig.git@main#subdirectory=python"
```

With remote workflow support:

```bash
pip install "scout-rig[remote] @ git+https://github.com/mikisvaz/scout-rig.git@main#subdirectory=python"
```

Requirements:
- Python >= 3.10
- numpy, pandas (imported at `import scout` time; hard requirements)
- `requests` (for remote workflows — see the caveat under
  "Remote workflow execution")
- Scout/Rbbt Ruby stack installed and on PATH, specifically the
  `rbbt_exec.rb` and `rbbt` commands

## Local workflow execution

### List tasks

```python
import scout
import scout.workflow as sw

wf = sw.Workflow('Baking')
print(wf.tasks())
# ['bake_muffin_tray', 'prepare_batter', 'whisk_eggs', 'bake_blueberry_muffin_tray']
```

`tasks()` shells out once and splits stdout on newlines, so it reflects the
workflow as currently installed. Requiring a workflow that is not installed
triggers Scout's auto-install (a `git clone` of the workflow's repository
under `~/.rbbt/workflows/`) on the first call — verified with `Baking`,
which was cloned from `https://github.com/Rbbt-Workflows/Baking.git` and
then listed normally. If the repository cannot be resolved the Ruby side
raises `Workflow repo does not exist: <url>` and `tasks()` surfaces that
text as the return value, since `cmd()` ignores the exit status.

Note the naming convention the lookup uses: the workflow *class* `Baking` maps
to the lowercase repository `baking`. In this environment `rbbt workflow task
Baking bake_muffin_tray` failed to resolve
`https://github.com/Scout-Workflows/baking.git` (no such repo) even though
`rbbt_exec.rb` and `Workflow.require_workflow` had installed
`Rbbt-Workflows/Baking` — i.e. the two entry points consult different repo
lists. Metadata calls (`tasks()`, `task_info()`) worked; actually *running*
`Baking` jobs did not. If `wf.run()` raises
`RuntimeError: Workflow repo does not exist: ...`, check which repository your
`rbbt` resolves the workflow name to before blaming the Python layer.

### Get task information

```python
info = wf.task_info('bake_muffin_tray')
print(info)
```

`task_info` returns the **raw JSON string** produced by the Ruby side, not a
parsed dict — call `json.loads(info)` yourself if you need the fields. The
keys observed for the `Baking` example are `id`, `description`, `inputs`,
`input_types`, `input_defaults`, `input_descriptions`, `input_options`,
`input_use`, `returns`, `dependencies`, `extension`; a task with no declared
return type has `"returns": null`.

### Run a task (synchronous)

```python
result = wf.run('bake_muffin_tray', add_blueberries=True)
print(result)
```

`run` returns the **stripped stdout** of the underlying
`rbbt workflow task` invocation. That is the task's log/progress output
first and the final result last; for multi-line output you normally want the
last line. On a non-zero exit it raises `RuntimeError` carrying the
command's stderr (or stdout when stderr is empty).

(Verified at the `run_job` level in this environment — the flags, the temp
input directory, the `RuntimeError` on failure and the stripped-stdout return
were all observed with a local workflow. The exact shape of a successful
`Baking` result line was **not** observed, because this checkout could not
resolve that workflow's repository; treat the "log then result" description
as Scout CLI behaviour, not something probed here.)

### Run a task asynchronously

```python
# Fork the job (runs in background)
step = wf.fork('bake_muffin_tray', add_blueberries=True)

# Poll for completion
step.join()  # Blocks until done, error, or aborted

# Get the result
data = step.load()
print(data)
```

`fork` passes `--fork --detach`, so the Ruby CLI returns as soon as the job
is issued; `Step` then re-shells out once per poll. `step.path` is the job
directory path printed by the CLI, and every accessor on `Step`
(`info`, `status`, `load`) invokes `rbbt_exec.rb` again.

Note the polling granularity: `join()` sleeps a fixed **1 second** between
checks with **no timeout**, and `Step.info()` only reads the job's `.info`
file — a path that was never issued (or was cleaned) yields an empty dict,
and `status()` then raises `KeyError: 'status'`. Treat `Step.info()` as
"the info Scout currently has on disk", not a guaranteed schema.

## Reading Scout TSV files

The `scout` package provides helpers for reading Scout-style TSV files
directly into pandas DataFrames:

```python
import scout

df = scout.tsv('data.tsv')
print(df.head())
```

The reader handles Scout TSV conventions:
- Preamble lines (`#:type=:list#:sep=:`) are parsed into metadata.
- Header lines (`#Key\tField1\tField2`) become column names.
- The key field becomes the DataFrame index.

Verified behaviour of `tsv()` / `tsv_pandas()` worth knowing before you rely
on it:

- `#:type=:flat` files are read with `header=None, skiprows=[0,1]` and the
  preamble's own `sep` if it declares one, so the whole body becomes the
  index of a zero-column DataFrame.
- A file whose first line is a plain `#name` header (no preamble, no field
  header) is read as a **flat single-column** frame: the label becomes the
  index name and there are no data columns (verified).
- A `#:type=:list` file with **no** field header is likewise read flat: the
  preamble is consumed and the body becomes a zero-column index. A list file
  that *does* carry a `#Key<TAB>Field` header line falls into the generic
  branch instead, and `header=start` then consumes the first data row as
  the pandas header — a four-row body yields a three-row frame whose first
  body row becomes the column labels (verified: `#K\tF` header over
  `x\ty / 1\t2 / 3\t4` gives one column literally named `y` and rows
  `x` and `1`). This looks like a bug rather than a design decision.
- A file with **no** `#` header at all (`fields: None`, `type: "list"`) is
  passed to `read_table` with `index_col=0` and no column names, which
  raises `TypeError: Index(...) must be called with a collection ...`
  in recent pandas. Header-less files are therefore not readable as-is.
- The reader only inspects the **first two** lines; a preamble without a
  following field header is fine (`start` stays 1, `fields` absent).
- Extra `**kwargs` go straight to `pandas.read_table`; passing `header=`
  yourself conflicts with the internally computed one and raises
  `TypeError: ... got multiple values for keyword argument 'header'`.

`save_tsv(filename, df, key=None)` writes `#<key>\t<cols>\n...`. The key
label defaults to the DataFrame's `index.name`, then to `"Key"`, and an
explicit `key=` overrides both.

### Writing Scout TSV files

```python
import scout
import pandas as pd

df = pd.DataFrame({'Gene': ['BRCA1', 'TP53'], 'Score': [1.2, 3.4]})
df = df.set_index('Gene')
scout.save_tsv('output.tsv', df)
```

## Remote workflow execution

For interacting with Scout REST workflow servers:

```python
# NOTE: `from scout.workflow.remote import RemoteWorkflow` does NOT work at
# HEAD — see the caveats below this example. Load the module by file path:
import importlib.util
spec = importlib.util.spec_from_file_location(
    'scout.workflow.remote', 'python/scout/workflow/remote.py')
remote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote)

wf = remote.RemoteWorkflow('http://localhost:1900/Baking')
print(wf.tasks)

# Run a job
step = wf.job('bake_muffin_tray', add_blueberries=True)

# Poll
step.wait()

# Get result
print(step.json())
```

Two caveats before you use this module:

- **`requests` is imported at module level**, so importing
  `scout.workflow.remote` without `requests` installed raises
  `ModuleNotFoundError: No module named 'requests'`. The `[remote]` pip
  extra installs the dependency but does not make the import optional.
- **There is no `scout/workflow/__init__.py`.** `scout.workflow` is the
  module `scout/workflow.py`, and Python resolves that *module* before it
  would consider the `scout/workflow/` directory a package, so
  `from scout.workflow.remote import ...` fails with
  `ModuleNotFoundError: No module named 'scout.workflow.remote';
  'scout.workflow' is not a package` on Python 3.12/3.13 (verified). The
  remote client is currently unreachable through the normal import path;
  load it with `importlib.util.spec_from_file_location` if you need it.

Note also that `RemoteWorkflow` exposes the task list as the attribute
`wf.tasks` (a plain list, not a method) — the code above prints it
directly. Constructing a `RemoteWorkflow` immediately GETs the workflow URL
and expects the JSON export shape `{"asynchronous": [...],
"synchronous": [...], "exec": [...]}`.

### RemoteStep methods

| Method | Description |
|--------|-------------|
| `info()` | Get job info as JSON |
| `status()` | Get job status string |
| `done()` | Check if done |
| `error()` | Check if errored (`error` **or** `aborted`) |
| `running()` | Check if currently running |
| `wait(time=1)` | Poll `status()` every `time` seconds until done/error |
| `raw()` | Get result as raw bytes |
| `json()` | Get result as JSON |

Failure behaviour (verified against a stub server):

- Any HTTP status other than 200 makes `get_json`/`get_raw` log
  `ERROR:root:Failed to initialize remote tasks` and return `None`; callers
  that subscript the result then fail with `TypeError` on `None`. Nothing
  raises a typed error on its own.
- A connection that cannot be established propagates `requests`'
  `ConnectionError` directly (the constructor does not catch it).
- `wait()` has **no timeout**: a job whose status never leaves `running`
  polls forever. Polling is a plain `sleep`-based loop with no backoff.
- `job(task, **kwargs)` POSTs with `_format=jobname`; on success the jobname
  is used to build the step URL `url/task/jobname`.
- `task_info(name)` builds its URL as `join(self.url, name, '/info')`, and
  `join` is a plain string concat with `/`, so the requested path is
  `<url>/<name>//info` (a double slash — verified against a stub server).
  The local `Workflow.task_info` (no slash) is the reliable one.

## How inputs are passed

When you call `wf.run('task', param=value)`, the Python package:

1. Materializes each input value to a file in a temp directory
   (via `save_job_inputs`).
2. Passes the temp directory to Scout via `--load_inputs`.
3. Scout reads the files and matches them to task inputs.

Input types are mapped to file formats (file name = input name, extension
appended):

| Python type | File name | Content |
|-------------|-----------|---------|
| `str` | `<name>.txt` | raw string |
| `bool` | `<name>` | `true` or `false` |
| `int`/`float` | `<name>` | decimal string |
| `pandas.DataFrame` | `<name>.tsv` | Scout-style TSV via `save_tsv` |
| `list`/`ndarray` | `<name>.list` | newline-separated |

Verified details:

- `list` / `ndarray` values are joined with `"
".join(value)`, so they must
  contain **strings**; a numpy integer array raises
  `TypeError: sequence item 0: expected str instance, numpy.int64 found`.
  Convert with `.astype(str)` first.
- Any other type raises
  `TypeError: Unsupported data type for argument '<name>': <type>`.
- The temp directory is removed immediately after the subprocess returns
  (including on the error path), so the input files are not inspectable
  afterwards.
- Keyword arguments other than the documented ones
  (`jobname`, `fork`, `clean`, `exec`) are all treated as job inputs and
  materialized; there is no validation against the task's declared inputs.
- `clean=True` adds `--clean`, `clean='recursive'` adds `--recursive_clean`;
  `exec=True` adds `--exec`; `fork=True` adds `--fork --detach`. Note that
  `exec` shadows the builtin inside `run_job` — that is the parameter's
  actual name.

## Command-line interaction

The `scout.cmd()` function is the foundation of the Python package. It
executes Ruby code via `rbbt_exec.rb`:

```python
import scout

# Run arbitrary Ruby via the Scout CLI
result = scout.cmd('puts Time.now')
print(result)
```

This is useful for quick introspection or when the higher-level wrappers
don't cover your use case.

Verified details of `cmd()`:

- The Ruby source is passed on **stdin** (`input=cmd.encode('utf-8')`) and
  only stdout is returned, decoded as text. **stderr is discarded** — a Ruby
  exception surfaces as a `#:rbbt_exec Error` marker on *stdout* followed by
  the backtrace, not as a Python exception, and the exit status is ignored.
- `rbbt_exec.rb` must be on `PATH`; otherwise `subprocess.run` raises
  `FileNotFoundError: [Errno 2] No such file or directory: 'rbbt_exec.rb'`.
- `cmd(None)` prints the literal string `Rbbt` and returns `None` (an
  easter egg / status ping rather than an error).
- `libdir()` is `cmd('puts Rbbt.find(:lib)').rstrip()`: it resolves through
  Scout's path lookup, so it returns the Scout **library root** of whatever
  environment `rbbt_exec.rb` picks up — from a checkout of this repository
  that is the checkout itself (trailing `/` included), and from an unrelated
  directory it can degrade to `/` when nothing matches.
- `scout.path(subdir)` resolves `lib` then `base` (`~/.rbbt`) and returns
  the first existing; `scout.read()` opens the resolved path and raises
  plain `FileNotFoundError` when nothing exists.

## Common mistakes

### Scout not on PATH

The Python package shells out to `rbbt` and `rbbt_exec.rb`. If these
commands aren't on your PATH, you'll get `FileNotFoundError`. Ensure the
Ruby Scout stack is installed.

### Confusing `run` and `fork`

`run()` is synchronous — it blocks until the job completes and returns the
result. `fork()` is asynchronous — it starts the job in the background and
returns a `Step` you can poll.

### Printing to stdout in Python tasks

When running a Python task via the CLI, the function's return value is
printed to stdout. If your function also prints to stdout, the output will
be corrupted. Use `sys.stderr` for debug output.

### Assuming `run()` returns only the result

`run()` returns the whole stripped stdout of
`rbbt workflow task`, which includes Scout's progress log lines. Parse the
last line, or write the result to a file and read it back, when a task logs
while it runs.

### Assuming `Step.info()` always has a `status`

`Step.info()` parses the job's `.info` file. For a path with no info file
(the job was never issued under that name, or was cleaned) Ruby returns an
empty object, and `status()` raises `KeyError: 'status'` (verified with a
path that was never issued). `load()` on the same path fails later, with
`json.JSONDecodeError`, because Ruby prints nothing for an empty `.load`.
Guard on `info().get('status')` instead.

### Expecting remote errors to raise

`scout.workflow.remote` logs HTTP failures through `logging.error` and
returns `None`. Configure the `logging` module if you want to see those
messages, and check for `None` before subscripting.

## See also

- [Defining Python Tasks](DefiningPythonTasks.md) — Writing Python-backed
  Scout tasks, including the `scout.task` docstring format.
- [Python Task Runner Internals](../developer/PythonTaskRunnerInternals.md)
  — The exact docstring grammar `describe_function` parses, the generated
  CLI's serialization rules, and its exit codes.
- [Passing Data to Python](PassingDataToPython.md) — Data conversion between
  Ruby and Python.
- [Cookbook](Cookbook.md) — Recipes for common patterns.
