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

A standalone `Extension: suffix` field in a function docstring is returned as
optional per-function metadata. Ruby applies that suffix to the function's
result path ahead of the file-level `python_task extension:` fallback; absent
the field, the existing file-level/default behavior remains. The suffix only
selects the result path extension and does not alter result conversion.

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
Ruby:  metas = [{name, description, returns, params, extension?}, ...]
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
Ruby:  build_python_argv(meta_params, positional values)  ───► CLI argv
      (block receives inputs positionally, in metadata param order;
       Shellwords.shelljoin([fn_name] + argv)  ───► one shell string)
          │
          ▼
Ruby:  ScoutPython.run_file(file, arg_str)  ───► Python subprocess
          │
          │ stdout = return value
          ▼
Ruby:  decode result (JSON → array split → string)
```

`PythonWorkflow.load_directory(path, workflow_name)` is the bulk form: it
builds a fresh anonymous module (extending both `Workflow` and
`PythonWorkflow`), registers it under a constant, points
`python_task_dir` at `path` (defaulting to `Scout.python.task` when
omitted) and calls `python_task` for every `*.py` file found by
`path.glob_names("*.py")`. Verified details:

- `path` must be a `Path`-like object responding to `glob_names`; a plain
  String raises `NoMethodError: undefined method 'glob_names'`.
- The default `workflow_name` is the constant `PythonWorkflow`, and
  `Kernel.const_set` **overwrites** an existing constant of that name (Ruby
  warns "already initialized constant"). The two-argument form
  `load_directory(dir)` still uses `PythonWorkflow`; `load_directory(dir,
  name)` sets a custom constant name.
- Names containing `/` (or any invalid constant characters) raise
  `NameError: wrong constant name ...` from `const_set`.
- An empty directory yields a module with no tasks and does not fail.
- Only the directory given is scanned; there is no recursion into
  subdirectories (verified: `sub/one.py` is not registered).

## Directory metadata loading

`load_python_tasks(batch: true)` is the reusable directory loader. Its default
is the batch path: all `*.py` task file metadata is gathered with one
`--scout-metadata-files` runner process and passed into task registration. With
`batch: false`, each `*.py` task file is inspected by an individual metadata
subprocess instead.

`PythonWorkflow`'s extension hook does not preload tasks; it prepares the
workflow to use Python tasks. Assigning `python_task_dir=` then loads that
directory in batch mode, so the supported lifecycle is to define/extend the
`Workflow` first, extend `PythonWorkflow` second, and assign the task directory
afterward:

```ruby
module TestWF
  extend Workflow
end
TestWF.extend PythonWorkflow
TestWF.python_task_dir = Path.setup("python/tasks")
```

The setter must call `load_python_tasks`; there is no `load_tasks` method in
this extension. `PythonWorkflow.load_directory(path, name, batch: false)`
explicitly requests per-file metadata discovery; its default is `batch: true`,
and `load_directory(path, name, literal_strings: true)` initializes
`python_literal_strings` before any registration (the plain setter does not
re-register anything). These keyword forms do not change the extension hook's
batch selection.

Batch runner execution sets each file's `__name__` to `__main__` and captures
registrations, including registrations guarded by `if __name__ == '__main__'`.
It reuses one interpreter for all files. A reproduced same-process caveat is
that imported modules are cached: a task registered only as a shared-import
side effect can be included for the first file but absent for a later file.
This establishes that batch behavior is not fully equivalent to separate
per-file processes; use the default per-file mode when isolation from shared
module state is required. These notes describe tested behavior, not a claim
that all stateful Python programs are supported equivalently.

### Re-registration and inspection

- `refresh_python_tasks!` re-runs the directory load and reconciles the
  registered tasks with what the files currently export, returning
  `{added:, changed:, removed:, unchanged:}`. The lifecycle is strictly
  ordered: **collect** the current file metadata (one batch metadata
  subprocess) → **decide** (added/changed/removed/unchanged per *name*,
  including the `python_literal_strings` config-compare path and tasks
  relocated between files) → **validate** the complete desired state →
  **apply**.
- **Failure policy (validate-before-mutate):** the complete desired state —
  metadata shape, duplicates, names exported by two files, collisions with
  native (Ruby-defined) tasks — is validated before the first mutation, so
  a failed refresh raises with the registry and the tracking map exactly
  as they were. There is no snapshot/rollback machinery and none is needed:
  nothing is mutated until everything is known to be valid.
- **Tracking is a plain map:** `@python_task_registrations` is
  `file -> {metas:, literal_strings:}` — names and metadata, no task
  objects. Task-object identity is not tracked at all; unchanged tasks
  simply keep the task object the previous registration installed, and
  ownership is decided from the live task's provenance (a task whose block
  was defined in `python/task.rb` is a PythonWorkflow registration).
- **Registration is per-task:** a file with any added/changed task is
  re-registered through `python_task` with ONLY those metas, so the
  unchanged siblings keep their task objects and the in-process
  `Workflow.job_cache` entries keyed to a surviving sibling stay live and
  retrievable; the file's tracking record is then committed once with
  *all* current metas for that file, so desired tracking equals the
  applied registry.
- **Idempotency:** a second refresh with unchanged sources is a pure no-op
  (empty `added`/`changed`/`removed`, `unchanged` populated, same task
  objects in place). Native Ruby tasks in the workflow are untouched. Use
  it after editing Python sources in-process.
- `python_input_contracts` / `python_input_contract` expose the single
  authoritative input-contract view per task (Python annotation, Scout
  type, default, required, `behavior`, `flags`), built from the stored
  registration metadata — not from a fresh extraction of the live task's
  inputs. See
  [DefiningPythonTasks](../user/DefiningPythonTasks.md) for the
  `behavior` column values.
- `python_literal_strings` is resolved at **registration time** (the input
  options, including `noload`, are built when the task registers). Flip it
  before loading, or refresh afterwards.

## Phase 1: Metadata discovery

### read_python_metadata(file)

Actual code at HEAD (`lib/scout/workflow/python/task.rb`):

```ruby
def self.read_python_metadata(file)
  out = ScoutPython.run_file file, '--scout-metadata'
  raise "Error getting metadata from #{file}" unless out.exit_status == 0
  JSON.parse(out.read)
end
```

Consequences:

- **JSON errors are not wrapped.** A zero exit with non-JSON stdout raises
  a bare `JSON::ParserError` from `JSON.parse(out.read)`.
- **Metadata is validated before any DSL side effect.**
  `validate_python_task_metadata` runs in `register_python_task_metadata`
  before the registrations hash or any `input`/`task` DSL call is touched,
  and raises for: an empty metas list ("No tasks exported by <file>"), a
  meta that is not a Hash, a missing `name` or `params` key, `params`
  that is not a list, a duplicate task name *within* one metas list, and
  a name that collides with a task already registered from a *different*
  file. Re-registering from the same file replaces the previous entry, so
  `refresh_python_tasks!` keeps working.

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

The metadata is a list of dicts, one per registered function. A
single-function file prints a one-element list; `python_task` accepts
either a list or a bare dict (`metas = [metas] unless Array === metas`). An
empty list is rejected by validation ("No tasks exported by <file>")
before any DSL call; a file that registers no function prints nothing at
all and still fails earlier, at the `JSON.parse`.

The metadata keys actually consumed by `python_task` are `name`,
`description`, `returns` and `params`; each param uses `name`, `type`,
`required`, `default` and `help`. Note that `describe_function` keys
`required` on the *absence of a default*, not on the annotation.

### Metadata structure

Each metadata dict from Python has:

```json
{
  "name": "hello",
  "description": "Greet a person.",
  "returns": "string",
  "params": [
    {"name": "name", "type": "string", "required": true, "default": null, "help": "..."},
    {"name": "excited", "type": "boolean", "required": false, "default": false, "help": "..."}
  ]
}
```

(There is no `function_name` key; the emitted keys are `name`,
`description`, `returns`, `params`.)

## Phase 2: Type mapping

### map_param(param, literal_strings: false)

Maps a Python parameter to a Scout input type declaration. The
`literal_strings` flag (resolved from the workflow's
`python_literal_strings` at registration time) adds `noload` to
`str`-mapped inputs so a Ruby `String` naming an existing file is no
longer read into its contents.

`map_param` matches the exact strings emitted by
`describe_function` — those are `string`, `integer`, `float`, `boolean`,
`binary`, `path`, `list[...]` or `None` (no `str`/`int`/`bool` aliases, no
`task`). Unsupported annotations fail loudly at metadata time on the
Python side, so the final `:string` fallback is defensive rather than a
reachable degradation path:

| Python type string | Scout type |
|--------------------|------------|
| `string`           | `:string`  |
| `integer`          | `:integer` |
| `float`            | `:float`   |
| `boolean`          | `:boolean` |
| `binary`           | `:binary`  |
| `path`             | `:file`    |
| `list[string]`, `list[integer]`, `list[float]`, … | `:array` |
| `list[path]`       | `:file_array` |
| `nil` (no annotation) | `:string` |
| (any other string) | `:string` (defensive) |

Only the subtype `path` is inspected inside `list[...]`; every other
subtype (`list[integer]`, `list[bytes]`, …) collapses to `:array`.

`map_param` also sets `required: true` in the input options when the Python
param has no default, and copies `default` and `help` verbatim into the
Scout input declaration.

### map_returns(return_type)

Maps a Python return annotation to a Scout task return type.

`map_returns` matches the exact strings emitted by `describe_function` —
`string`, `integer`, `float`, `boolean`, `binary`, `path`, `array`, or
anything beginning with `list[` (no `int`/`bool` aliases, and a bare
`list` is *not* recognized because a bare `list` annotation is reported as
the plain type string, not `list[...]`). Unsupported return annotations
now fail loudly at metadata time on the Python side, so the final
`:string` fallback below is a defensive default rather than a reachable
degradation path:

| Python type string | Scout type |
|--------------------|------------|
| `nil` / JSON `null` (no annotation) | `:string` |
| `string`           | `:string`  |
| `integer`          | `:integer` |
| `float`            | `:float`   |
| `boolean`          | `:boolean` |
| `binary`           | `:binary`  |
| `path`             | `:string`  |
| `array`            | `:array`   |
| `list[...]` (any subtype) | `:array` |
| (any other string) | `:string`  |

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

Details of the per-meta declaration loop (verified):

- `ruby_inputs` is `[]` when `meta['params']` is `nil` (this guard was
  added in 8c4d941, "Fixed issue with missing parametesr in python tasks");
  an empty `params: []` array behaves the same.
- Each input is declared with `input(name, type, desc, default, options)`;
  `options` carries only `required: true` when applicable.
- `self.desc(task_desc)` is called once per meta, where
  `task_desc = desc || meta['description']`. The `desc:` kwarg therefore
  overrides the docstring description **for every** function in the file.
- `extension(extension)` is likewise applied to every declared task.
- `meta['returns'] = returns.to_s if returns` — the `returns:` kwarg
  overrides the return type string for every function too, and an unknown
  string (`'yaml'`) silently maps through `map_returns` to `:string`.
- The task name is `meta['name']`, i.e. the Python function name, not the
  `python_task` argument. Registering the same function name twice
  overwrites the earlier task silently.
- The declared Scout return type is `map_returns(meta['returns'])`, which
  may be `:string` (never `nil`), so `task(name => type)` always receives
  a concrete type symbol.

### Task file discovery

`python_task` locates the Python file using:

1. `file:` option if provided. The file is used verbatim (no pathmap
   lookup); a missing file raises
   `RuntimeError: Python task file not found: <file>`.
2. Otherwise, `python_task_dir[task_name].find_with_extension('py')`, and
   the same existence check runs on the resolved path.

`python_task_dir` defaults to `Scout.python.tasks.find`, which returns the
first existing `python/tasks` directory in the Scout pathmap order and
otherwise falls back to the user path (`~/.scout/python/tasks`) even when it
does not exist.

## Phase 4: Execution

### build_python_argv(params, values)

Actual code at HEAD (`lib/scout/workflow/python/inputs.rb`):

```ruby
def self.build_python_argv(params, values)
  values = values.transform_values { |v| String === v ? v.strip : v }
  params.map do |param|
    name, value = param.values_at("name", "default")
    ...
  end
end
```

Consequences:

- The value mapping is decided by the **value's class**, not the declared
  Python type: an `Array` emits one argv word per element; a `String`
  containing commas splits on commas; any other single value emits one
  word. Arrays serialize literally, full stop — the bridge never reads a
  file for a list value.
- `nil` is the only "missing" spelling: a `nil` value emits no flag, while
  an empty string still emits `--name ''`
  (so `''` is distinguishable from a missing input).

| Input type | Ruby value handling |
|------------|---------------------|
| nil        | Nothing emitted |
| boolean (no default or default false) | `--name` if true, nothing if false |
| boolean (default true)  | `--name` if true, `--no-name` if false |
| list (String with comma) | Split by comma, parts stripped |
| list (other String) | Single item |
| list (Array) | One argv word per element, taken literally |
| path/file   | Passed as-is |
| scalar      | `--name value` (empty string still emits `--name ''`) |

Ambiguities (Improvements A3): comma-containing elements cannot be
expressed through a comma-separated string (they are split) — pass an
`Array`; elements beginning with `-` are emitted bare and are then parsed
by argparse as options (exit status 2); an empty-string element produces
an empty argv word. Note the *Scout input layer* (`:array` inputs) may
still expand a bare-filename `String` into its lines before the task
block runs; that is Scout-native behaviour, outside this workflow (see
[DefiningPythonTasks](../user/DefiningPythonTasks.md)).

### run_file and shell quoting

```ruby
ScoutPython.run_file(file, arg_str)
# → CMD.cmd("env PYTHONPATH=... python '#{file}' #{arg_str}")
```

`python_task` builds `arg_str` with `Shellwords.shelljoin(full_argv)` where
`full_argv = [function_name] + argv`. This protects values containing
spaces, semicolons, parentheses or commas, but has two consequences:

- The **file path itself** is interpolated with Ruby string quoting
  (`'#{file}'`), not Shellwords. A file named `it's.py` produces a broken
  shell command (`sh: Syntax error: Unterminated quoted string`, exit
  status 2).
- Values beginning with `-` survive shelljoin (they are emitted bare), so
  argparse still rejects them (`argument --s: expected one argument`,
  exit status 2). There is no `--` separator in the generated command.

### Return value decoding
PythonWorkflow task execution passes `SCOUT_JOB_FILES_DIR` through the
`run_file` child-only `env:` option, using the executing Step's `files_dir`.
This identifies the job's `.files` auxiliary-file directory; Python task code
can use it to create outputs that belong with the job. `run_file` first removes
any inherited `SCOUT_JOB_FILES_DIR` from the child, then applies explicit
`env:` values. Thus metadata discovery and direct calls without a Step have no
job directory and cannot accidentally observe a stale parent value. The Ruby
process environment is never mutated. Other runner calls do not set this
variable.


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
1. Try JSON first (handles dicts, nested lists, numbers, booleans — and,
   unintentionally, any plain string that happens to be valid JSON).
2. If JSON fails and the return type is `:array` or `:file_array`, split on
   newlines.
3. Otherwise, return stripped text.

Note that the split applies to the whole stdout including any stray prints;
and the newline split always produces Strings, so a `list[int]` return
yields `["1", "2"]` in Ruby, not integers (verified). The runner serializes
lists one item per line (`runner.py`), so the JSON branch is normally only
taken for dict-like returns.

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
   tasks. The first positional argument in the CLI argv selects the function
   (`full_argv = [meta['name']] + argv`). The selector is the *metadata*
   name, which for a plain `scout.task(fn)` call is the function name; a
   single-function file ignores the positional entirely, while a
   multi-function file without it fails in argparse (exit status 2), and an
   unknown name makes the runner print `[scout.task] Unknown task 'x'` and
   exit non-zero.

4. **Heuristic return decoding** — JSON is tried first (handles structured
   data), with fallbacks for arrays (newline-split) and plain text. This
   covers the vast majority of use cases.

5. **Type mapping mirrors Python annotations** — The mapping table is a
   straightforward mapping from Python type strings to Scout types. The
   Python side produces type strings via `describe_function`.

## Known issues

1. **Unused `err` variable** (Improvements B1 — **resolved**) — the raise
   in `read_python_metadata` no longer interpolates an undefined local;
   it is now `raise "Error getting metadata from #{file}"`. In practice
   `ScoutPython.run_file` → `CMD.cmd` still raises `ProcessFailed` on a
   non-zero exit before this check runs, so the user-facing failure
   remains a `ProcessFailed` with the interpreter's stderr embedded.

2. **No metadata caching** (Improvements O1, verified still true at HEAD) —
   `read_python_metadata` runs a Python subprocess every time `python_task`
   is called, with no memoization by path, mtime or content; identical
   calls re-execute the file. Measured: ~0.4–0.5 s per single registration,
   ~1.3 s for `load_directory` over three files (interpreter startup
   dominates). Definition time therefore scales linearly with the number of
   registered functions, and import-heavy Python files pay their import
   cost once per registration.

3. **String split ambiguity** (Improvements A3 — **resolved**) — In
   `build_python_argv`, list inputs given as strings are split by comma, so
   `'a,b'` becomes two elements while `['a,b']` stays one. Elements
   beginning with `-` break argparse. The bridge serializes an `Array`
   literally, full stop; pass an `Array` to keep comma-containing elements
   intact. The Scout input layer (`:array` inputs) may still expand a
   bare-filename `String` into its lines before the task block runs — that
   is Scout-native behaviour, out of scope here.

4. **Return decoding ambiguity** (verified) — If a string return value
   happens to be valid JSON, it is JSON-parsed instead of returned as-is
   (`"[1, 2]"` → `[1, 2]`, `"1"` → `1`). Conversely a `list` return is
   serialized one item per line, so the JSON branch never sees it and the
   items come back as Strings.

5. **path return maps to :string** (Improvements A4, verified) — `path`
   returns map to `:string` in Scout while `path` inputs map to `:file`.
   The mapped type symbol only affects how Scout treats the value
   downstream (e.g. `Step#stream`, file extension inference); the actual
   path string is returned either way.

## See also

- [Architecture](Architecture.md) — Overall module map.
- [ScoutPython Internals](ScoutPythonInternals.md) — The run_file mechanism.
- [Defining Python Tasks](../user/DefiningPythonTasks.md) — User-facing guide.
