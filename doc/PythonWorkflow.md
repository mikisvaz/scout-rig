PythonWorkflow lets you define Ruby Scout workflows whose tasks are implemented as standalone Python functions.

This module is meant for workflow authors who prefer to write task logic in Python, while still benefiting from Scout/Rbbt features such as dependency management, persistence, provenance, and CLI integration.

A Python-backed task is defined in a `.py` script (typically under a `python/task` directory). The script registers one or more functions using `scout.task(...)`. The Ruby workflow then calls `python_task` to import those function definitions as regular Scout tasks.

Key ideas

- Python tasks are ordinary Python functions with type hints, defaults, and a docstring.
- The Python script can be run on its own:
  - `--scout-metadata` prints machine-readable JSON task metadata (consumed by Ruby to define inputs and return types).
  - without `--scout-metadata` it behaves like a CLI that runs the function.
- Ruby side (`PythonWorkflow`) reads metadata and auto-creates Workflow inputs and tasks.
- At execution time, the Ruby task block runs the Python script in a subprocess using `ScoutPython.run_file`.

Minimal directory layout

- `workflow.rb` defines the Ruby workflow.
- `python/task/<name>.py` defines one or more Python functions and registers them.

Example Python task

```python
import scout

def hello(name: str, excited: bool = False) -> str:
    """Greet a user."""
    return f"Hello, {name}{'!' if excited else ''}"

scout.task(hello)
```

Example Ruby workflow

```ruby
require 'scout'

module TestPythonWF
  extend Workflow
  extend PythonWorkflow

  self.name = 'TestPythonWF'

  python_task :hello
end
```

Type mapping (Python metadata to Scout inputs/returns)

PythonWorkflow relies on `scout.task` metadata type strings (produced by `python/scout/runner.py`) and maps them to standard Workflow types.

- Scalars
  - `string` -> `:string`
  - `integer` -> `:integer`
  - `float` -> `:float`
  - `boolean` -> `:boolean`
  - `binary` -> `:binary`
  - `path` -> `:file` for inputs (passed as a path string on the CLI)
- Lists
  - `list[string]`, `list[integer]`, `list[float]` -> `:array`
  - `list[path]` -> `:file_array`

List inputs in Ruby

When building the Python command line, list parameters accept several Ruby-side formats:

- A Ruby Array (`['a', 'b', 'c']`)
- A comma-separated String (`"a,b,c"`)
- A path to an existing file (the file is read line-by-line and passed as items)

Return value decoding

The Python runner prints function results to stdout, and Ruby tries to interpret them as follows:

- If stdout is valid JSON, it is parsed with `JSON.parse` and returned.
- Otherwise, if the declared Scout return type is `:array` or `:file_array`, stdout is split on newlines.
- Otherwise, stdout is returned as a stripped string.

This means you can return complex objects from Python, as long as the runner prints JSON and your declared return type can sensibly persist that Ruby value.

Python CLI behavior (standalone execution)

A Python task file registered via `scout.task(...)` can be used directly as a command-line tool.

- Metadata:
  - `python hello.py --scout-metadata`
  - For files that register multiple functions, `--scout-metadata` prints a JSON array of metadata objects.
- Run:
  - `python hello.py --name Alice --excited`
  - If multiple functions are registered in the same file, you can select one by passing its name as the first positional argument:
    - `python tasks.py hello --name Alice`

Python import paths

Python tasks are executed as subprocesses with a `PYTHONPATH` composed from `ScoutPython.paths`. These are initialized from `Scout.python.find_all` and can be extended at runtime using `ScoutPython.add_path` or `ScoutPython.add_paths`.

# Tasks

## python_task
Register one or more Python functions as Workflow tasks.

`python_task` discovers and reads metadata from a Python script (by running it with `--scout-metadata`) and then defines one Workflow task per function found.

Inputs and return type are inferred from the Python function signature and type hints.

If the Python script registers multiple functions, multiple Workflow tasks are created (one per registered function). The `task_sym` argument selects the default filename to locate, but does not limit how many functions will be imported from that file.

The task execution runs the Python script as a subprocess and passes CLI options that correspond to the declared inputs.

## python_task_dir
Configure where Python task scripts are discovered.

By default, `python_task_dir` is taken from `Scout.python.task.find(:lib)`, so tasks can be shipped as part of a Scout package and located via the Path subsystem.

You can override it by setting `self.python_task_dir` in your workflow module to a different Path or directory-like object that supports `[]` indexing and `find_with_extension('py')`.

## scout.task
Register a Python function as a Scout-compatible task and enable metadata/CLI execution.

A Python task script should end with one or more `scout.task(function)` calls. This:

- Captures signature, type hints, and docstring to build a metadata object.
- Enables `--scout-metadata` output for Ruby to consume.
- Enables standalone CLI execution using argparse, including support for list and boolean arguments.

For scripts that register multiple functions, `scout.task` defers CLI dispatch until interpreter shutdown so all functions are registered before selecting a target function.
