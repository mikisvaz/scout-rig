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

## Phase 1: Metadata discovery

### read_python_metadata(file)

Actual code at HEAD (`lib/scout/workflow/python/task.rb`):

```ruby
def self.read_python_metadata(file)
  out = ScoutPython.run_file file, '--scout-metadata'
  raise "Error getting metadata from #{file}: #{err}" unless out.exit_status == 0
  JSON.parse(out.read)
end
```

Two consequences:

- **The `raise` line is dead in practice.** `ScoutPython.run_file` calls
  `CMD.cmd` without error tolerance, so a non-zero exit raises
  `ProcessFailed` from `CMD` before the line is reached. The intended
  `err` variable is never assigned (Improvements B1); had the line ever
  run it would raise `NameError` for the undefined local.
- **JSON errors are not wrapped.** A zero exit with non-JSON stdout raises
  a bare `JSON::ParserError` from `JSON.parse(out.read)`.

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
either a list or a bare dict (`metas = [metas] unless Array === metas`). A
file that registers no function prints nothing at all, and registration
then fails with `JSON::ParserError`.

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

### map_param(param)

Maps a Python parameter to a Scout input type declaration.

`map_param` matches the exact strings emitted by
`describe_function` — those are `string`, `integer`, `float`, `boolean`,
`binary`, `path`, `list[...]` or `None` (no `str`/`int`/`bool` aliases, no
`task`):

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
| (any other string) | `:string`  |

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
the plain type string, not `list[...]`):

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

Translates Ruby input values into CLI arguments for the Python script.

The decision tree, in the order the code applies it:

1. `values[name]` nil → emit nothing, **regardless of `required`** (the
   `next unless required; next` pair is a no-op: both branches skip). The
   missing-required check happens earlier, in Scout's `job`/`run` path
   (`ParameterException`), not here.
2. Type string starts with `list[` → build the item list:
   - `String` naming an **existing file** → the file's lines become the
     items (checked first, so a literal comma-less string that happens to
     be an existing file path is silently expanded).
   - `String` containing a comma → split on commas, each part stripped.
   - any other `String` → one item.
   - `Array` (anything responding to `to_ary`) → `to_s` of each element.
   - anything else → one item, `to_s`.
   Emit `--name` **once**, followed by every item as its own argv word
   (matching argparse `nargs='+'`).
3. `boolean` → if the Python default is `true`, emit `--no-name` when the
   Ruby value is falsey and nothing when truthy; otherwise (default `false`
   or `nil`) emit `--name` when truthy and nothing when falsey. So a
   boolean **without** a default cannot express `false` on the wire.
4. anything else (scalars, including `path`) → `--name value` with `value`
   passed verbatim; an existing-file string is *not* read or rewritten.

| Input type | Ruby value handling |
|------------|---------------------|
| nil        | Nothing emitted |
| boolean (no default or default false) | `--name` if true, nothing if false |
| boolean (default true)  | `--name` if true, `--no-name` if false |
| list (String naming existing file) | File read line-by-line |
| list (String with comma) | Split by comma, parts stripped |
| list (other String) | Single item |
| list (Array) | One argv word per element |
| path/file   | Passed as-is |
| scalar      | `--name value` |

Ambiguities (Improvements A3): comma-containing elements cannot be
expressed through a comma-separated string (they are split); elements
beginning with `-` are emitted bare and are then parsed by argparse as
options (exit status 2); an empty-string element produces an empty argv
word.

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

1. **Unused `err` variable** (Improvements B1, verified) — In
   `read_python_metadata`:
   ```ruby
   raise "Error getting metadata from #{file}: #{err}" unless out.exit_status == 0
   ```
   `err` is never assigned. In practice the line is unreachable:
   `ScoutPython.run_file` → `CMD.cmd` raises `ProcessFailed` on non-zero
   exit before the check runs, so the user-facing failure is a
   `ProcessFailed` with the interpreter's stderr embedded, not this
   message. Had the line run it would have raised `NameError` (undefined
   local `err`), and `#{err}` in the interpolation would have evaluated to
   the method name as a String, not `nil`.

2. **No metadata caching** (Improvements O1, verified still true at HEAD) —
   `read_python_metadata` runs a Python subprocess every time `python_task`
   is called, with no memoization by path, mtime or content; identical
   calls re-execute the file. Measured: ~0.4–0.5 s per single registration,
   ~1.3 s for `load_directory` over three files (interpreter startup
   dominates). Definition time therefore scales linearly with the number of
   registered functions, and import-heavy Python files pay their import
   cost once per registration.

3. **String split ambiguity** (Improvements A3, verified) — In
   `build_python_argv`, list inputs given as strings are split by comma, so
   `'a,b'` becomes two elements while `['a,b']` stays one. The
   existing-file check runs first, so a comma-separated string naming an
   existing file is expanded to that file's lines. Elements beginning with
   `-` break argparse.

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
