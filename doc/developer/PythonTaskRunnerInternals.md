# Python Task Runner Internals

## Audience

This page is for scout-rig contributors who need to know exactly how
`python/scout/runner.py` turns a Python function into Scout metadata and a
CLI. Everything here is verified by probes against HEAD 290ee22 unless
marked otherwise.

- ✓ Framework contributors working on the Python side of the bridge
- ✓ Agents that must predict `--scout-metadata` or CLI output exactly
- ✗ Users who just want to write Python tasks (see
  [Defining Python Tasks](../user/DefiningPythonTasks.md))

## The two roles of runner.py

`runner.py` serves both sides of the bridge:

1. **Metadata producer.** `scout.task(func)` computes the attribute
   `func.__scout_meta__` via `describe_function(func)` and registers the
   function in a module-global registry.
2. **CLI dispatcher.** On `atexit`, if `sys.argv` is not empty, it parses
   argv, dispatches to one registered function, prints the result, and
   exits.

The Ruby side never imports the module; it runs the file as a program and
reads the `--scout-metadata` output. See
[PythonWorkflow Internals](PythonWorkflowInternals.md).

## Type mapping

`_python_type_to_string(ann)` maps a type hint to one of the Scout input
type strings `map_param` on the Ruby side understands.

- No annotation -> `"string"`.
- `Optional[X]` / `X | None` -> the mapping of `X`.
- `list[X]` (a parameterized generic, including `typing.List[X]`) ->
  `"list[<subtype>]"` where `<subtype>` is the mapping of `X`. A **bare**
  `list` annotation has `get_origin(list) is None`, so it falls through the
  branch and maps to `"string"` — `list` and `list[str]` do not behave
  alike.
- `pathlib.Path` -> `"path"`.
- `str` -> `"string"`, `bytes` -> `"binary"`, `int` -> `"integer"`,
  `float` -> `"float"`, `bool` -> `"boolean"`.
- Anything else (including `dict[...]`, `set`, custom classes) ->
  `"string"`; nothing raises.

`_required_from_default(default_val, ann)` returns False when the parameter
has a default, or when its annotation is `Optional`. A parameter with no
default and no `Optional` is required (verified: `a: str` and `b: "str |
None"` are both required; `c=None` and `d: int = 3` are not).

The `BooleanOptionalAction` special case on the CLI comes from
`_add_arg_for_param`, not from `describe_function`: the flag code branches
on `default is True`, so only a parameter that *declares* `= True` gets the
`--flag | --no-flag` pair. An `Optional[bool]` with no default keeps
`default: None` in the metadata and therefore becomes
`action="store_true"` (verified: `Optional[bool]` shows a bare `--flag`
that turns the value on, and running without it yields `flag=False`).

`describe_function` also works on callables without Python source: a
builtin such as `len` is described by name, signature, and docstring, with
all parameters typed `"string"`. `*args`/`**kwargs` parameters are
included as ordinary (required, `"string"`) parameters rather than
skipped.

## Docstring grammar

`describe_function` derives the description and per-parameter help from the
docstring. There are **two independent parsers**, tried in order, plus a
separate description extractor. All rules below are probe-verified.

### Description: `_extract_description`

Walks the (dedented) docstring line by line and **stops at the first line
whose stripped, lower-cased form is in this set**:

    args:  arguments:  returns:  raises:  examples:  example:  notes:  note:
    parameters  returns  raises  examples  notes

Blank lines and everything else are kept; leading/trailing blanks are
trimmed and internal blank lines preserved. Consequences (verified):

- The set is matched **exactly after strip+lower**, so `Args :` (space
  before the colon) or `ARGUMENTS:` are *not* stop headers and end up inside
  the description.
- `Options:`, `option:`, `Attributes`, `Yields:`, `See Also:`, `Todo:`,
  `description` are *not* in the set, so they also stay inside the
  description.
- reST fields (`:param a: ...`) are not recognized at all and remain in the
  description.
- A docstring with no recognized header puts the **whole docstring** into
  `description`.

### Parameter help, attempt 1: Google style `parse_google_args`

Scans for a line whose stripped form is exactly `Args:` or `Arguments:`
(anywhere in the docstring, indentation irrelevant). If found, it parses
entries until an **unindented line ending with `:`** (the next section
header) or end of docstring.

An entry is an **indented** line matching

    ^\s*([A-Za-z_]\w*)\s*(\([^)]*\))?\s*:\s*(.*)$

i.e. `name: text` or `name (type): text`; the parenthesized type is parsed
and **discarded** (the signature decides `type`). Continuation behaviour:

- Any later line that is not itself an entry header is appended (stripped)
  to the current parameter's help, joined with a single space — including
  lines at the left margin that merely fail the regex. A non-matching
  indented line after an entry is therefore *swallowed into the previous
  parameter's help*.
- Blank lines inside a section are dropped (they append `""` which
  `" ".join` collapses).
- An entry with an empty description yields the empty string, and a
  parameter named in `Args:` but absent from the function signature is
  silently dropped later by `describe_function`.

### Parameter help, attempt 2: NumPy style

Runs only when the Google parser found nothing. Looks for a line whose
stripped, lower-cased form is `parameters` followed by a line consisting
only of dashes. Entries are then **unindented** lines containing a colon;
the text before the first colon is the parameter name and the following
indented lines are its help (joined with single spaces).

- The classic NumPy layout `a : int` on the entry line puts the *type* into
  the name split: `a` becomes the name (`a : int` splits at the first colon
  giving `a `, stripped to `a`), and the type is silently dropped.
- An **unindented** line that does not contain a colon terminates the
  section — which is why a NumPy `Returns` header with its dashes swallows
  the dashes into the last parameter's help instead of stopping.

### What the parser does not capture

- Return descriptions. The emitted metadata has only the `returns` type
  string derived from the annotation; `Returns:` text is never stored.
- reST `:param:`/`:type:` fields.
- `Options:`, `Attributes:`, `Yields:`, `See Also:`, `Notes:` content —
  these merely terminate the Google section (any unindented `...:` line
  does) or stay in the description.

### Verified probe outcomes

| docstring | result |
|-----------|--------|
| none | `description: ""`, `help: ""` |
| Google `name: text` + wrapped line | help = `text` + `" "` + wrapped |
| Google `name (type): text` | type ignored, help = `text` |
| Google entry with empty text | help = `""` |
| NumPy `Parameters` + dashes + `a : int` + indented help | help = indented lines joined |
| NumPy followed by `Returns` + dashes | dashes land in the last help string |
| `Args :` (space before colon) | not a header: rest goes into description, help `""` |
| reST `:param a:` / `:type a:` | fields stay in description, help `""` |
| `Arguments:` | recognized like `Args:` |
| `Params:` | **not** recognized by either parser |
| documented name not in signature | dropped |
| parameter with no entry | help `""` |

## The generated CLI

When `scout.task` files are run as programs, the deferred dispatcher builds
one `argparse` parser per invocation.

### Flags

- Every parameter becomes `--name` (`--scout-output` is reserved; see below).
- `list[...]` parameters get `nargs='+'` with a caster for the declared
  element type (`integer` -> `int`, `float` -> `float`, `path` -> `str(Path(s))`,
  otherwise `str`).
- `boolean` parameters: only `default is True` (an explicit `= True`)
  yields `argparse.BooleanOptionalAction`, so both `--flag` and
  `--no-flag` work; any other default (including `None` and `False`) yields
  `action="store_true"` with `default=False`, i.e. the flag can only turn
  it **on** (verified: `flag: bool = False` shows `--flag` with no value,
  and running without it returns `flag=False`).
- `integer` -> `int`, `float` -> `float`, `path` -> `str(Path(s))`, anything
  else (including `string`, `binary`, `array`, and unmapped types) -> `str`.
- `--scout-metadata` is not an argparse flag at all: it is tested directly
  against `sys.argv` before parsing. `--scout-output` is the only argparse
  flag the runner adds itself.
- `required` comes from `describe_function`: a parameter with no default
  and no `Optional` is required; `help` is the parsed docstring entry.
- `*args`/`**kwargs` parameters are described like ordinary required
  parameters with type `"string"` (`--args ARGS`, `--kw KW`); they are not
  filtered out (verified), so such a task is nearly unusable from the CLI
  unless you pass them explicitly.

### Dispatch rules (verified)

| argv | behaviour |
|------|-----------|
| `--scout-metadata` (anywhere in argv) | print the JSON array with the metadata of **all** tasks registered so far, exit 0 |
| `-h` / `--help` in `argv[1:]` | show the help of the selected task (`argv[1]`), or of the **last** registered task when `argv[1]` is missing/not a task name |
| `<taskname> --flags...` | run that task; exit 0 on success, 1 on exception |
| unknown `<taskname>` (run path) | stderr `[scout.task] Unknown task '<name>'`, exit code stays **0** (the `sys.exit(2)` there is swallowed by atexit) |
| unknown `<taskname>` + `-h` (help path) | same message on stderr but **exit 2**, because the help branch uses `os._exit(2)` |
| no `argv[1]`, no `-h` | run the **last** registered task with the given flags |

Notes (verified):

- `--scout-metadata` is matched as a literal element of `sys.argv`, so it
  wins even when placed after a task name, and `--scout-metadata=1` would
  not match.
- A single-function file still prints a **list** with one element; there is
  no single-object variant. The deferred handler checks `--scout-metadata`
  first and prints the whole registry; `_run_cli` has a second,
  unreachable-in-practice check of its own that would print a single
  object. So the list-of-objects form is the contract the Ruby side sees
  (`read_python_metadata` does `JSON.parse(out.read)` on the process output
and iterates the result).
- After a successful run the handler calls `os._exit(code)` (not
  `sys.exit`), so nothing after it runs — and no `atexit` callbacks run
  either; stdout/stderr are flushed explicitly beforehand.
- Help with an **unknown** task name is different from help with no task
  name: `<bogus> -h` prints `[scout.task] Unknown task '<bogus>'` on stderr
  and exits **2** via `os._exit(2)` in the help branch (verified with
  `two_task.py bogus -h`), whereas `-h` alone picks the last task and
  exits 0.
- After a help request the process exits 0; `argparse` writes the help to
  stdout.

### Output serialization

The dispatcher in `_scout_run_deferred` applies these rules to the function's
return value when no `--scout-output` was given (all verified with
`od -c`):

1. `bytes`/`bytearray` -> written raw to `sys.stdout.buffer`, **no trailing
   newline**.
2. `None`, `str`, `int`, `float`, `bool` -> `print(...)`; `None` prints an
   empty line.
3. `list`/`tuple` -> one `print` per item:
   - `None` items print an empty line,
   - `bytes`/`bytearray` items are written raw **followed by a newline**,
   - everything else is printed via `print(item)`.
4. Anything else -> `json.dumps(result, default=str, ensure_ascii=False)`.
   `default=str` means a `set` serializes as the *string* `"{1, 2}"` and an
   arbitrary object as `"OBJ"` (its `str()`), wrapped in JSON quotes.
   When even `json.dumps` raises, `str(result)` is printed as a last
   resort.

When `--scout-output PATH` **is** given the code takes a **different**
branch: `_write_output(path, result)` does
`path.parent.mkdir(parents=True, exist_ok=True)` and then writes either
`path.write_bytes(result)` for `bytes`/`bytearray`, or
`path.write_text(str(result))` for everything else. So with a file
destination:

- a `dict` is written as its Python `str()` (`{'a': {'b': [1, 2]}}`, not
  JSON),
- a `list` is written as `[1, 2, 'z']` (the `repr`, not newline-separated),
- only `bytes` keep their raw form.

The stdout cascade and the file branch therefore **do not agree**: stdout
gives JSON for dicts and newline-separated items for lists, the file gives
`str()` for both.

A parameter literally named `scout_output` collides with the reserved flag
destination. The collision is invisible at the *flag* level (argparse
derives `--scout_output`, single underscore, from the parameter name, while
the reserved flag is `--scout-output`), but both flags write the same
namespace key `scout_output`. Verified outcomes for such a parameter: the
result is written to whatever path was given and the function receives
`None` for its own `scout_output` argument — regardless of whether the
reserved `--scout-output V` or the user's `--scout_output V` form was used.
A parameter with a default that merely happens to be named something else
keeps its value normally (verified: the default is only shadowed by the
name `scout_output`).

### Exit codes

| situation | exit code |
|-----------|-----------|
| success | 0 |
| task function raised | 1 (message `[scout.task] Error: ...` on stderr; `os._exit(1)`) |
| argparse usage error | 2 |
| unknown task name | 0 when running, 2 when `-h` was also given (message on stderr) |

## Import-time vs run-time

`scout.task(func)` computes `describe_function(func)` eagerly and stores the
result as the attribute `func.__scout_meta__` (the actual attribute name —
**not** `__scout_task_metadata__`), and appends `func` to the module-global
`_SCOUT_TASK_REGISTRY`. Only when the *defining module is `__main__`* does
it also register the `atexit` dispatcher `_scout_run_deferred`.

Consequences (verified):

- Importing a module that decorates functions is safe as long as
  `inspect.signature` can read each signature; no CLI runs, because the
  module's `__name__` is not `__main__` (verified: importing such a module
  registers the task in `scout.runner._SCOUT_TASK_REGISTRY` but the body
  never executes).
- Running such a file **as a program always dispatches**, even when the
  import was made for library purposes: the dispatcher checks
  `sys.argv[1]`, and when no task name matches it falls back to the **last
  registered task** — which will then demand its required arguments
  (exit 2) or execute.
- Both the unknown-task and the argparse-error paths raise `SystemExit`
  inside the `atexit` callback. Python ignores `SystemExit` coming from an
  `atexit` handler (it prints the traceback and keeps going), so the code
  requested there is not honoured. Concretely CPython prints
  `Exception ignored in atexit callback <function task.<locals>._scout_run_deferred ...>`
  plus a short traceback before exiting normally. The **observable** codes
  (verified) are: missing required argument -> 2, unknown task name -> 0 on
  the run path but 2 when combined with `-h` (message on stderr either way),
  successful run -> 0, function exception -> 1.

## Known gaps (verified)

- `python/pyproject.toml` declares `version = "0.2.4"` while the gem is at
  `0.2.6` (`gem` `VERSION` file and the regenerated gemspec at HEAD 290ee22);
  the two are not synchronized. The classifiers also stop at Python 3.12
  while `requires-python` is `>=3.10`.
- `python/build/lib/scout/` and `python/scout_rig.egg-info/` are stale
  build artifacts sitting in the tree (verified: at HEAD the copies are
  byte-identical to `python/scout/`, and the egg-info still records
  `Version: 0.2.4`). They are ignored by `python/.gitignore` (`build/`
  and `*.egg-info/`), so git does not track them, but any packaging run
  that consults them (an editable install, a wheel built from the stale
  tree) can ship the old version string; delete them before packaging.
- `python/test.py` is an ad-hoc script (it shells out to the `Baking`
  example workflow and requires it installed); the Ruby rake tasks do not
  run any Python test, and no test framework is configured for the Python
  package at all (no `[tool.pytest]` in `pyproject.toml`, no tests
  directory).
- `scout.workflow` is a module, not a package, so
  `scout.workflow.remote` cannot be imported normally (see
  [Driving Workflows from Python](../user/DrivingWorkflowsFromPython.md)).
- `requests` is imported unconditionally at the top of `remote.py` although
  the pyproject lists it only under the `remote` extra.
- `save_inputs` in `python/scout/workflow.py` is a `return`-only stub: dead
  code, never called by anything in `python/`, `lib/`, or `test/` (only
  `save_job_inputs` in `scout/__init__.py` is used, by `run_job`). This
  confirms Improvements item B4 as still open.

## See also

- [PythonWorkflow Internals](PythonWorkflowInternals.md) — the Ruby side
  that consumes this metadata.
- [Driving Workflows from Python](../user/DrivingWorkflowsFromPython.md) —
  the user-facing view of the `scout` package.
