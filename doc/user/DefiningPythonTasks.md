# Defining Python Tasks

This document explains how to write Scout workflow tasks whose logic is
implemented in Python, using the `python_task` declaration and the
`scout.task` Python decorator.

## Audience

This page is intended for:

- ✓ Workflow authors who want to write task logic in Python
- ✓ Agent developers building Python-backed workflows
- ✗ Framework contributors (see [PythonWorkflow Internals](../developer/PythonWorkflowInternals.md))

## When to use this

Use Python tasks when:

- You have existing Python code that should become part of a Scout workflow.
- Your task logic depends on Python libraries (pandas, scikit-learn, etc.).
- You want to leverage Python's ecosystem while keeping Scout's dependency
  management, persistence, and provenance.
- You're building a workflow that serves both Ruby and Python users.

## Core concepts

A Python task is defined by two parts:

1. **A Python file** that defines one or more functions and registers them
   with `scout.task`.
2. **A Ruby workflow** that calls `python_task` to import the function
   definitions as Scout tasks.

The Python function's type hints and docstring fully determine the Scout
task's inputs and return type. You don't need to declare inputs manually
on the Ruby side.

### The contract

```
Python function signature (types, defaults)  →  Scout task inputs
Python return annotation                     →  Scout task return type
Python docstring                             →  Task description + input help
```

## Typical usage

### Step 1: Write the Python task file

Create a Python file (e.g., `python/tasks/greet.py`):

```python
import scout

def hello(name: str, excited: bool = False) -> str:
    """
    Greet a person.

    Args:
        name: The name of the person to greet.
        excited: Whether to add an exclamation mark.

    Returns:
        A greeting message.
    """
    return f"Hello, {name}{'!' if excited else ''}"

scout.task(hello)
```

### Step 2: Define the Ruby workflow

```ruby
require 'scout'

module GreetingWorkflow
  extend Workflow
  extend PythonWorkflow

  self.name = 'Greeting'

  python_task :hello
end
```

That's it. The workflow now has a `hello` task with inputs `name` (string,
required) and `excited` (boolean, default false), returning a string.

### Step 3: Run it

```ruby
job = GreetingWorkflow.job(:hello, name: "World")
puts job.run  # => "Hello, World"

job = GreetingWorkflow.job(:hello, name: "World", excited: true)
puts job.run  # => "Hello, World!"
```

Or from the command line:

```bash
scout workflow task Greeting hello --name World
```

## Type mapping

The Python function's type annotations are mapped to Scout types
automatically:

### Input types

| Python type hint   | Scout input type |
|--------------------|------------------|
| `str`              | `:string`        |
| `int`              | `:integer`       |
| `float`            | `:float`         |
| `bool`             | `:boolean`       |
| `bytes`            | `:binary`        |
| `pathlib.Path`     | `:file`          |
| `list[str]`        | `:array`         |
| `list[int]`        | `:array`         |
| `list[float]`      | `:array`         |
| `list[pathlib.Path]` | `:file_array`  |
| `Optional[str]`    | `:string` (required unless it has a default) |
| unannotated parameter | `:string` (required) |

Unsupported annotations (dict, bare `list`, `int | str`, custom classes)
raise a clear error at task-registration time instead of silently mapping
to `:string`.

Notes, verified at HEAD:

- The mapping keys on the *Python type string* produced by
  `describe_function`, so `list[...]` (typing or builtin generics) yields
  `:array`/`:file_array`, while a bare `list` annotation raises at
  registration time.
- A parameter is `required` iff it has no Python default (so
  `Optional[str]` without a default is still required).
- Python defaults are propagated verbatim as Scout input defaults, whatever
  their JSON type (e.g. `5`, `'hi'`, `True`).
- The Python parameter's `help` text (from the docstring) becomes the Scout
  input description.
- **Postponed annotations** (`from __future__ import annotations`) are fully
  supported and map identically to plain ones: `str→:string`,
  `pathlib.Path→:file`, `list[Path]→:file_array`, `Path | None→:file`, and
  `Annotated[Path, …]→:file`. `python_annotation` preserves the complete
  annotation form: bare classes keep their short name (`str`, `Path`), while
  anything parameterized renders in full — `Annotated[Path, 'extra']` is
  recorded as `typing.Annotated[pathlib._local.Path, 'extra']`,
  `Optional[Path]` as `typing.Optional[pathlib._local.Path]` and `Path | None`
  as `pathlib._local.Path | None`. The value is diagnostic only; it never
  affects the annotation→Scout-type mapping. Annotations are resolved eagerly
  with
  `inspect.signature(..., eval_str=True)`, so a postponed or quoted annotation
  is evaluated against the module namespace at registration time. A name that
  does not resolve fails **loudly** — never a silent `:string` mapping — and
  the error explains that a quoted annotation stays a string unless the type
  is importable or defined at registration time; a genuinely undefined name
  raises `NameError` at import.

### Return types

| Python return annotation | Scout return type |
|--------------------------|-------------------|
| `str`                    | `:string`         |
| `int`                    | `:integer`        |
| `float`                  | `:float`          |
| `bool`                   | `:boolean`        |
| `bytes`                  | `:binary`         |
| `pathlib.Path`           | `:string`         |
| `list[str]`              | `:array`          |
| no return annotation     | `:string`         |

Unsupported return annotations raise the same registration-time error as
parameters. Note the asymmetry: a `pathlib.Path` **input** maps to
`:file`, but a `pathlib.Path` **return** maps to `:string` (there is no
`:file` return type in this mapping).

## What a task returns

The Python function's return value is serialized by the runner and decoded
by Ruby. The *decoded* Ruby type depends on the actual runtime value, not on
the declared return annotation (the annotation only sets the Scout task
return type):

| Python return value | Ruby result (verified) |
|---------------------|------------------------|
| `str` | String (stripped) |
| `int` | Integer |
| `float` | Float |
| `bool` | `True`/`False` printed as text → String `"True"`/`"False"` |
| `None` | `""` (empty String) |
| `bytes` | String (raw bytes passed through) |
| `pathlib.Path` | String path |
| `list`/`tuple` of scalars | one item per line; with a `list[...]` return annotation the task is `:array` and Ruby splits the lines back into an Array of **Strings** (ints come back as `"1"`, `"2"`; a nested list comes back as the strings `"[1, 2]"`, `"[3]"`) |
| `dict` (or other object) | JSON object → Hash |

Note the JSON-first heuristic: anything whose stdout is valid JSON is
parsed as JSON regardless of the annotation.

## Multi-function files

A single Python file can define multiple functions. All registered functions
become Scout tasks:

```python
import scout

def add(a: int, b: int) -> int:
    """Add two numbers."""
    return a + b

def multiply(a: float, b: float) -> float:
    """Multiply two numbers."""
    return a * b

scout.task(add)
scout.task(multiply)
```

```ruby
module MathWF
  extend Workflow
  extend PythonWorkflow
  self.name = 'Math'

  python_task :math  # Creates both :add and :multiply tasks
end
```

The `python_task :math` call discovers all functions in `math.py` and creates
one Scout task per function.

The name you pass to `python_task` selects the *file*
(`python_task :math` → `math.py`), not the function. The registered
function names become the task names, so they may differ from the file
name — `python_task :math_ops` on the file above still yields `:add` and
`:multiply` tasks.

Consequently, calling `python_task` twice on the same file (or on a file
whose function name matches another file's) re-registers the task under the
same name; the last registration silently wins. The Python-side
`--scout-metadata` output keeps **both** entries (verified: two `@task`
functions with the same name both appear in the JSON array), so which one
wins is decided by whoever consumes the array last.

### Result file extension

Pass `extension:` to `python_task` to set the suffix on the Scout result path:

```ruby
python_task :network, extension: 'sif'
```

This sets a filename suffix only; it does not convert or validate the
Python function's return value or make the result conform to a file format.
For example, `json`, `tsv`, and `sif` can be used as suffixes, but `sif`
does not imply special SIF-format support. If `extension:` is omitted (or
`nil`), Scout's normal extension behavior for the task's result type applies.

The option belongs to the Python task-file registration and is a fallback for
all functions registered from that file. A function may override it by adding
one standalone `Extension:` field to its docstring:

```python
def network() -> str:
    """Create a network result.

    Extension: json
    """
    ...
```

The field may be indented with the surrounding docstring, and its value is
trimmed but must be one non-empty suffix token (no whitespace). Duplicate
`Extension:` fields are rejected. It is removed before description and
parameter-help extraction. A function-level value takes precedence over the
file-level `extension:` option; without it, the file option and then Scout's
normal result-type behavior apply. In a multi-function file each function's
field affects only that function.

This changes only the result path suffix; it does not change serialization,
conversion, or format validation.

## Docstring format

Use Google-style docstrings for the best metadata extraction and CLI help:

```python
def search(query: str, max_results: int = 10) -> list[str]:
    """
    Search for items.

    Args:
        query: Natural language search query.
        max_results: Maximum number of results to return.

    Returns:
        A list of matching items.
    """
    ...
```

The metadata extractor reads:
- **Description:** Everything before `Args:`/`Returns:`.
- **Parameter help:** The text after each parameter name in the `Args:` section.

`Args:` and `Arguments:` are both accepted; `Params:` is **not**
recognized. A docstring is not required at all: with no docstring the
description is `""` and every parameter's help is `""`. Two spellings of a
parameter entry work in `Args:` — `name: text` (Google style) and
`name : type\ntext` (numpydoc style, one blank line between entries).
Documenting a name that is not in the signature is silently dropped, and
not documenting a parameter simply leaves its help empty. The full rules
live in [Python Task Runner Internals](../developer/PythonTaskRunnerInternals.md).

Two corrections to that picture (both verified against
`describe_function` at HEAD):

- **Return descriptions are not captured.** Only the *return type* is
  derived from the annotation; `Returns:` text is dropped. It is useful to
  humans, but it never reaches the task metadata.
- **`name (type): text` and bare `name: text` behave the same**: the
  parenthesized type in a Google-style entry is parsed and discarded — the
  signature decides the type.

## Metadata execution at definition time

Every `python_task` call — and every `load_directory` — **re-runs the Python
file as a subprocess** to obtain the metadata (`python file.py
--scout-metadata`), even for an unchanged file. There is no cache and no
keying on content or mtime. Measured on this checkout, a single
`python_task` registration costs roughly 0.4–0.5 s and
`load_directory` over a three-file directory roughly 1.3 s, almost all of it
interpreter startup. Keep Python task files import-light (heavy imports run
once per registered task) and expect definition time to scale linearly with
the number of registered functions.

If the metadata subprocess fails, registration aborts:

| Failure | What you see (verified) |
|---------|-------------------------|
| Python syntax error in the file | `ProcessFailed` from `CMD.cmd` with the interpreter's `SyntaxError` and exit status 1 in the message |
| File runs fine but does not register any `scout.task` | `--scout-metadata` succeeds with exit status 0 and prints nothing, so Ruby raises `JSON::ParserError: unexpected token at ''` |
| File prints non-JSON to stdout at import time | `JSON::ParserError` whose message shows the offending output |
| File exits non-zero | `ProcessFailed` |

## Running Python tasks standalone

Python task files are also valid CLI tools. You can run them directly:

```bash
# Get metadata
python greet.py --scout-metadata

# Run a function
python greet.py --name World --excited

# For multi-function files, specify the function name
python math.py add --a 3 --b 4
```

Caveats (verified):

- A single-function file ignores any positional function name:
  `python greet.py hello --name X` still runs `hello`, and so does
  `python greet.py bogus --name X`.
- A multi-function file **expects** the function name as the first
  positional argument; without it the **last registered** function is
  selected. That may still work (when it has defaults for everything) or
  fail with exit status 2 (`error: the following arguments are required:
  --a ...` for the missing arguments of *that* function).
- Asking a multi-function file for an unregistered function prints
  `[scout.task] Unknown task 'x'` on stderr. Beware: the message is
  emitted, then `SystemExit(2)` is raised inside the `atexit` callback, and
  Python reports it as "Exception ignored in atexit callback", so **the
  process still exits 0**; you must check stderr, not the exit code.
- The `--scout-output` flag exists on every generated CLI and is reserved.
  Ruby never passes it. A parameter literally named `scout_output` gets a
  flag of its own (`--scout_output`, single underscore — argparse derives
  flags from the parameter name, while the reserved flag is
  `--scout-output`), so the two do **not** collide at the flag level, but
  they do share the argparse *destination* `scout_output`: passing
  `--scout_output V` silently loses the value (the function receives
  `None`) and instead creates a file `V` with the result. Parameters that
  simply have a default but are not named `scout_output` are unaffected.

## Auxiliary files from a running Scout task

When PythonWorkflow runs a task as a Scout job, the Python subprocess receives
`SCOUT_JOB_FILES_DIR`, set to that job's `.files` sidecar directory. Write
auxiliary outputs there so they are kept with the job and its provenance:

```python
import os
from pathlib import Path

files_dir = Path(os.environ["SCOUT_JOB_FILES_DIR"])
report = files_dir / "report.txt"
report.write_text("Generated by this job\\n", encoding="utf-8")
```

The variable is scoped to the task's Python child; Ruby's environment is not
modified. Metadata discovery (`--scout-metadata`) and direct
`ScoutPython.run_file` calls are not running in a Scout Step, so they do not
receive this variable. Those invocations explicitly remove an inherited
`SCOUT_JOB_FILES_DIR` rather than accidentally using a stale job's sidecar.
Standalone Python CLI execution also does not set it. Do not assume the
variable exists outside a PythonWorkflow task job.


## Task file discovery


By default, `python_task` looks for `.py` files via the Scout Path subsystem:
`python_task_dir` defaults to `Scout.python.tasks.find`, which resolves the
first existing `python/tasks` directory in the usual Scout search order (the
workflow's own `python/tasks` first, then the user's `~/.scout/python/tasks`).
If none exists, the default falls back to the user path even when it does not
exist. You can override this:

```ruby
module MyWF
  extend Workflow
  extend PythonWorkflow

  # Use a custom directory
  self.python_task_dir = Path.setup("python/task")

  python_task :hello
end
```

Or load all Python files from a directory at once:

```ruby
PythonWorkflow.load_directory(Path.setup("python/task"), :MyWF)
```

`load_directory` returns a new named workflow module registered as a constant (it does not extend
the receiver) and registers one task per `scout.task`-decorated function
across **every** `*.py` file in the directory. It takes a `Path` object, not
a plain `String`; a `String` raises
`NoMethodError: undefined method 'glob_names'`.

With one argument, `load_directory(dir)` uses the fixed constant name
`PythonWorkflow`; pass an explicit second argument
(`load_directory(dir, :MyPyWF)`) to name the module. Both forms **overwrite
an existing constant of that name** (with an "already initialized constant"
warning).

`python_task` also accepts an explicit `file:` option, which bypasses
`python_task_dir` entirely. If the file does not exist, registration fails
with `RuntimeError: Python task file not found: <file>`; the same message
appears when the name resolves through `python_task_dir` but no `.py` file
exists at the resolved path.

### Loading a Python task directory

To configure a workflow with a directory of Python task files, extend the
Ruby workflow first and PythonWorkflow second, then assign the directory:

```ruby
module TestWF
  extend Workflow
end
TestWF.extend PythonWorkflow
TestWF.python_task_dir = Path.setup("python/tasks")
```

The extension hook does not preload tasks. Assigning `python_task_dir` loads
the assigned directory using batch metadata discovery (one Python runner
invocation for the directory). The lower-level
`PythonWorkflow.load_directory(path, name, batch: false)` explicitly requests
per-file metadata discovery (one Python invocation per file); its default is
`batch: true`. `load_directory(path, name, literal_strings: true)` also
initializes `python_literal_strings` **before** any task is registered, so
string inputs get `noload` from the start — the plain
`python_literal_strings=` setter does not re-register already-loaded tasks. Use
per-file mode when process isolation is needed; batch and per-file loading are
not guaranteed to be semantically equivalent for Python files with
process-global state or shared imports.

Batch mode executes each task file as `__main__` to preserve registrations
inside `if __name__ == '__main__'` blocks. The runner reuses one interpreter
for the directory, so imported Python modules are cached across files. In
particular, registrations performed only as a side effect of a shared import
may not appear in later files' metadata. This behavior was reproduced by the
workflow tests; choose default per-file loading if such imports are significant.

## Missing and optional inputs

A Python parameter without a default becomes a **required** Scout input.
What happens then depends on how it is missing:

| Situation | Behaviour (verified) |
|-----------|----------------------|
| Input omitted entirely, or passed as `nil` | Scout raises `ParameterException` (`Input 'x' is required but was not provided or is nil`; plural form lists all missing) before any Python process starts |
| Required input passed as `nil` through a path that bypasses the check (e.g. explicit `nil` accepted by `job`) | No `--x` flag is emitted; Python's argparse then fails with exit status 2 and its usage message, surfaced by Ruby as `ProcessFailed` |
| Optional input omitted | No flag is emitted; the Python default applies |

Omitted optional inputs are simply **not passed** to the CLI: the Python
side sees its own default (`None` if the default was `None`, the literal
default otherwise). The Scout input default records the Python default but
is not itself injected into the call.

## Boolean inputs

How a boolean input is passed depends on its Python default:

| Python default | Ruby `true` | Ruby `false` / omitted |
|---------------|-------------|------------------------|
| none (required) | `--flag` | no flag → the Python-side argparse default (`False` for a required bool, which argparse registers with `action="store_true"`) |
| `False` | `--flag` | no flag → `False` |
| `True` | `--flag` | `--no-flag` → `False` |

Only the `default = True` case can express `false` explicitly (via
`--no-flag`). For a boolean without a default, passing `false` from Ruby
emits no flag at all, so `true` and `false` are indistinguishable on the
wire; the function always receives `False`.

## List inputs

List inputs accept several value shapes on the Ruby side. The bridge
serializes an `Array` **literally** — one flag, elements as separate argv
words, no re-reading of files. Array elements are never reinterpreted:
the file name `'tmp/probes/listfile.txt'` in an `Array` is passed as path
text.

| Ruby value | Resulting argv |
|------------|----------------|
| `Array` | `--items a b c` (one flag, elements as separate argv words, taken literally) |
| `String` containing commas | `--items a b c` (split on commas, each part stripped) |
| Any other single value | `--items value` |

Caveats (verified):

- **Two layers.** The bridge itself never reads a file for a list value.
  But the *Scout input layer* is a separate layer: a bare-filename
  `String` may still be expanded into its lines by Scout's `:array` input
  before the task block runs. That behaviour is Scout-native and out of
  scope here — pass an `Array` when you need the literal path text.
- **Comma ambiguity.** A single-element array whose element contains a
  comma, `['a,b']`, is passed faithfully as one argv word when it comes
  from an `Array`; but the same text given as a `String`, `'a,b'`, is
  **split into two elements** `a` and `b`. Pass arrays when elements may
  contain commas.
- **Leading-dash elements.** An element beginning with `-` (e.g. `['a','-b']`)
  is emitted as a bare argv word; argparse then interprets it as an option
  and the run fails with exit status 2.
- Empty-string elements are preserved (`['a','','b']` → `--items a '' b`).
- **Empty-string scalars.** A scalar input whose value is the empty string
  always emits `--word ''`, so `''` is distinguishable from a missing input
  (only `nil` is skipped and produces no flag).

## Literal strings

One workflow flag controls whether Scout expands filename-like values
before they reach Python.

### `python_literal_strings`

Default `false`: for a `str`-annotated parameter, Scout loads a Ruby
`String` naming an existing file into that file's contents (the Scout
input-layer convention for `:string` inputs), so the Python function
receives the file contents.

With `workflow.python_literal_strings = true`, `str` parameters register
their Scout input with `noload`, so a Ruby `String` reaches Python
literally as the text (or path text) you passed — no file read happens.

The flag is read **at registration time**, when the input options are
built: set it *before* `load_directory` / any `python_task` registration.
Flipping it afterwards requires `refresh_python_tasks!` (or re-registering
the tasks) to rebuild the input options; `Workflow.job_cache` can also
memoize old steps, so clear it (`workflow.job_cache.clear`) when switching
modes inside one process. List inputs are not affected by this flag: an
`Array` list value is always serialized literally by the bridge (see
[List inputs](#list-inputs)).

## Input contracts

`workflow.python_input_contracts` returns one string-keyed entry per
registered Python task — index it as `python_input_contracts['task']` — and
`python_input_contract('task', 'input')` inspects a single input (both
arguments are strings, not symbols). There is **one authoritative view per
task**, built from the stored registration metadata — not from a fresh
extraction of the live task's inputs.

Each input entry carries the Python annotation (`python_annotation`, the
complete annotation form as described above), the Scout type (`scout_type`),
the default, requiredness, and a `behavior` column describing what the Ruby
value becomes:

- `:file` / `:file_array` → `'filename'`
- `:string` → `'literal text'` when `python_literal_strings` was set at
  registration time, otherwise `'text or loaded file contents'`
- `:array` → `'list of strings'`; `:file_array` → `'list of filenames'`

A `flags` field records active options such as `noload`.

**The contract comes from stored registration metadata, not live
extraction** — after editing a Python file, run `refresh_python_tasks!`
before the contract reflects the new source.

## Refreshing registered Python tasks

`workflow.refresh_python_tasks!` re-reads the Python task directory and
reconciles the registered tasks with what the files currently export:

| Situation | Result |
|-----------|--------|
| New Python function | registered (`:added`) |
| Changed signature or metadata | re-registered (`:changed`) |
| Deleted Python function | its registration is removed (`:removed`) |
| Unchanged definition | left alone (`:unchanged`) — the task object and cached job results survive |
| Name collision, including with an existing native (Ruby-defined) task | raises a clear error, nothing changed |
| Body changed, metadata unchanged | still `:unchanged`: the registration is kept, execution uses the current source on a fresh run, cached results remain |

It returns a summary hash `{added:, changed:, removed:, unchanged:}` and is
idempotent (a second refresh with unchanged sources reports everything as
`unchanged`). A failed refresh mutates nothing: the complete desired
registry — shape, duplicates, names exported by two files, native
collisions — is validated **before** the first mutation, so a raise leaves
the registry and the tracking map exactly as they were. Only the tasks whose
metadata actually changed are re-registered; their unchanged siblings keep
the task objects and in-process cached results the previous registration
installed. Editing the `python_literal_strings` flag alone (without a source
change) also shows up as `:changed`, because the flag is fixed at
registration time. It is the right call after editing Python sources
in-process (e.g. from a ScoutCoder `reload_workflow`).

## Common mistakes

### Missing type hints

Type hints are required for proper type mapping. Without them, parameters
default to `:string`:

```python
# Bad — no type hints, everything becomes :string
def add(a, b):
    return a + b

# Good
def add(a: int, b: int) -> int:
    return a + b
```

### Missing `scout.task` registration

The Python file must end with `scout.task(function)` calls. Without
registration, `--scout-metadata` won't produce output:

```python
# Bad — function won't be discovered
def hello(name: str) -> str:
    return f"Hello, {name}"

# Good
def hello(name: str) -> str:
    return f"Hello, {name}"

scout.task(hello)
```

### Expecting the raw string back for JSON-looking returns

Return decoding tries `JSON.parse` on the whole stdout first. A function
that returns the plain string `"[1, 2]"` yields a Ruby `Array` `[1, 2]`,
not the string; `"1"` yields the Integer `1`. Use a `:string`-typed
wrapping or avoid JSON-shaped plain text if you need it verbatim.

### Expecting JSON when the Python function prints to stdout

Any `print()` in the task body is concatenated with the serialized return
value, so the whole stdout is no longer valid JSON and decoding falls back
to the array/text heuristics (see the next section).

### Forgetting `result` is returned via stdout

The Python function's return value is printed to stdout and decoded by Ruby
(see [PythonWorkflow Internals](../developer/PythonWorkflowInternals.md) for
the decoding order). Avoid printing debug output to stdout, as it will
interfere with result decoding — with a dict/list return the process output
stops being valid JSON and Ruby raises `JSON::ParserError`; with a string
return the stray text is silently glued onto the result:

```python
# Bad — debug print corrupts the return value
def compute(x: int) -> int:
    print("Processing...")  # This goes to stdout!
    return x * 2

# Good — use stderr for debug output
def compute(x: int) -> int:
    import sys
    print("Processing...", file=sys.stderr)
    return x * 2
```

## See also

- [PythonWorkflow Internals](../developer/PythonWorkflowInternals.md) — How
  metadata discovery and type mapping work internally.
- [Driving Workflows from Python](DrivingWorkflowsFromPython.md) — Using the
  Python `scout` package.
- [Cookbook](Cookbook.md) — Recipes combining Python tasks with other features.
