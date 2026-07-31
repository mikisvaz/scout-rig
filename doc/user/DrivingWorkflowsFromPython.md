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
- numpy, pandas
- `requests` (for remote workflows)
- Scout/Rbbt Ruby stack installed and on PATH

## Local workflow execution

### List tasks

```python
import scout
import scout.workflow as sw

wf = sw.Workflow('Baking')
print(wf.tasks())
# ['bake_muffin_tray', 'prepare_dough', 'oven_temperature']
```

### Get task information

```python
info = wf.task_info('bake_muffin_tray')
print(info)
```

### Run a task (synchronous)

```python
result = wf.run('bake_muffin_tray', add_blueberries=True)
print(result)
```

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
from scout.workflow.remote import RemoteWorkflow

wf = RemoteWorkflow('http://localhost:1900/Baking')
print(wf.tasks())

# Run a job
step = wf.job('bake_muffin_tray', add_blueberries=True)

# Poll
step.wait()

# Get result
print(step.json())
```

### RemoteStep methods

| Method | Description |
|--------|-------------|
| `info()` | Get job info as JSON |
| `status()` | Get job status string |
| `done()` | Check if done |
| `error()` | Check if errored |
| `running()` | Check if currently running |
| `wait()` | Block until done/error |
| `raw()` | Get result as raw bytes |
| `json()` | Get result as JSON |

## How inputs are passed

When you call `wf.run('task', param=value)`, the Python package:

1. Materializes each input value to a file in a temp directory
   (via `save_job_inputs`).
2. Passes the temp directory to Scout via `--load_inputs`.
3. Scout reads the files and matches them to task inputs.

Input types are mapped to file formats:

| Python type | File format |
|-------------|-------------|
| `str` | `.txt` file |
| `bool` | File containing `true` or `false` |
| `int`/`float` | File containing the value as string |
| `pandas.DataFrame` | `.tsv` file (Scout-style) |
| `list`/`ndarray` | `.list` file (newline-separated) |

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

## See also

- [Defining Python Tasks](DefiningPythonTasks.md) — Writing Python-backed
  Scout tasks.
- [Passing Data to Python](PassingDataToPython.md) — Data conversion between
  Ruby and Python.
- [Cookbook](Cookbook.md) — Recipes for common patterns.
