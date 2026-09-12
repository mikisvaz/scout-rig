# Scripting Python

This document explains how to run ad-hoc Python scripts from Ruby using
the `script()` facility, inject Ruby variables, and retrieve results.

## Audience

This page is intended for:

- ✓ Workflow authors who need to run Python code as a script
- ✓ Agent developers running one-off Python computations
- ✗ Framework contributors (see [Data Conversion Internals](../developer/DataConversionInternals.md))

## When to use this

Use `script()` when you need to:

- Run a Python code block that uses multiple libraries (pandas, numpy, sklearn).
- Pass Ruby variables (including TSV) into Python.
- Get a result value back in Ruby.
- Avoid the complexity of managing PyCall sessions and imports.

For short one-liners or when you need to interact with Python objects
in-memory, use [Running Python from Ruby](RunningPythonFromRuby.md) instead.

## Core concepts

`ScoutPython.script(text, variables = {})` runs a Python script in a
**subprocess** and returns the value of the Python variable `result`.

This is fundamentally different from `run`:
- `run` executes in the current Ruby process via PyCall.
- `script` spawns a new Python process, runs the script, and reads back
  the result from a file.

The advantage of `script()` is isolation: each call gets a clean Python
environment with no state leakage. The tradeoff is overhead (process
startup + file I/O).

## Typical usage

### Basic script

```ruby
result = ScoutPython.script <<~PY, value: 2
  result = value * 3
PY
puts result  # => 6
```

What happens:
1. The variable `value: 2` is serialized as `value = 2` (Python literal).
2. The script body sets `result`.
3. A "save result" snippet is appended: `result` is pickled to a temp file.
4. Ruby reads the pickle and returns `6`.

Note that the script text is fed to `python` on **stdin** — `script()` never
writes a `.py` file. The temp files involved are the pickle result file and
one TSV dump per TSV variable (see "Failure semantics and temp files" below).

### Passing a TSV

When you pass a TSV as a variable, it is written to a temporary file and
loaded into Python as a pandas DataFrame via the Python `scout.tsv()`
function:

```ruby
tsv = TSV.setup({}, "Key~ValueA,ValueB#:type=:list")
tsv["k1"] = ["a1", "b1"]
tsv["k2"] = ["a2", "b2"]

result = ScoutPython.script <<~PY, df: tsv
  result = df.loc["k2", "ValueB"]
PY
puts result  # => "b2"
```

### Passing multiple variables

```ruby
result = ScoutPython.script <<~PY, numbers: [1, 2, 3], factor: 10
  result = [n * factor for n in numbers]
PY
puts result.inspect  # => [10, 20, 30]
```

Variable types are serialized as follows:

| Ruby type | Python representation |
|-----------|----------------------|
| `nil`     | `None`               |
| `true`    | `True`               |
| `false`   | `False`              |
| Integer/Float | Literal number   |
| String    | Single-quoted literal |
| Symbol    | Bare identifier       |
| Array     | Python list literal   |
| Hash      | Python dict literal   |
| TSV       | pandas DataFrame (via temp file + `scout.tsv()`) |

Details worth knowing, verified against the implementation:

- **Strings become single-quoted Python literals without escaping.** The
  string `"it's"` is emitted as `'it's'`, which is a Python `SyntaxError`.
  Strings containing a newline break the generated program for the same
  reason. Double quotes (`'a"b'`), backslashes (Ruby `"a\\b"` → Python
  `a\b`), tabs and non-ASCII text round-trip fine. If you must pass arbitrary
  text, pass a filename or a TSV instead of a string variable.
- **`Symbol` values are emitted as bare Python names**, not strings: `:abc`
  becomes `abc`. This only works for symbols that are also valid Python
  identifiers; a symbol like `:d-f` is emitted verbatim and the generated
  program then fails with a Python `SyntaxError`/`NameError`.
- **A `String` that starts with `":"` is stripped of the leading colon**: the
  string `":abc"` becomes the bare Python name `abc`, and the exact string
  `":NA"` becomes `None`. This is one way to pass `nil`, but it also means a
  literal string beginning with `:` never reaches Python as itself.
- **`Float::INFINITY` becomes the Python name `inf`**, which is undefined
  unless your script defines it (`from math import inf`).
- **Hash keys are coerced to strings**, including inside nested structures:
  `{1 => 'a'}` becomes `{'1':'a'}` and `{[1,2] => 'a'}` becomes
  `{'[1, 2]':'a'}`.
- **Only these types are accepted.** Anything else raises
  `Type of object not known: ...`; a `Path` is serialized as its string
  value.

### Getting results back with pandas

You can also use the `scout` Python package inside scripts to save
DataFrames back to TSV:

```ruby
tsv = TSV.setup({}, "Key~ValueA,ValueB#:type=:list")
tsv["k1"] = ["a1", "b1"]

TmpFile.with_file do |target|
  ScoutPython.script <<~PY, df: tsv, target: target
    import scout
    df['ValueA'] = df['ValueA'].str.upper()
    scout.save_tsv(target, df)
    result = "done"
  PY
  TSV.open(target, type: :list)["k1"]["ValueA"]  # => "A1"
end
```

## Result persistence

By default, results are pickled and loaded via the `python/pickle` Ruby gem.
If you prefer JSON (or if the pickle gem is unavailable), re-point the
aliases:

```ruby
class << ScoutPython
  alias save_script_result save_script_result_json
  alias load_result load_json
end
```

Now results will be serialized as JSON instead of pickle.

### What actually round-trips

The two back-ends are **not** equivalent, and neither is universal. Both
columns were verified with probes against the current stack (Ruby 3.3,
Python 3.13, `python-pickle` 0.2.0):

| Result value | pickle (default) | JSON backend |
|--------------|------------------|--------------|
| `True` / `False` | `true` / `false` | `true` / `false` |
| float `1.5` | `1.5` | `1.5` |
| string `"a"` | `"a"` | `"a"` |
| list / dict | list / hash | array / hash |
| `bytes b"x"` | `"x"` | not JSON-serializable |
| float `inf`, `nan` | `Float::INFINITY`, `Float::NAN` | Ruby raises `JSON::ParserError` |
| integer `1`..`255` | `1`..`255` | OK |
| integer `256`, `300`, `-1` | **`Python::Pickle::InvalidFormat`** | OK |
| datetime / numpy array / DataFrame | opaque `Python::Pickle::PyObject` or `InvalidFormat` | `TypeError` on the Python side unless converted first |

Two consequences follow:

- **The default pickle backend cannot read most integers.** Protocol 4 emits
  `BININT2`/`BININT` opcodes for anything outside `0..255`, and
  `python/pickle` 0.2.0 does not implement those opcodes, so `result = 300`
  raises `Python::Pickle::InvalidFormat: invalid opcode (74) for protocol 4`
  even though the pickle was written by the same Python that scout-rig
  launches. Small positive integers (0-255), floats, strings, booleans,
  `None`, lists and dicts decode fine. Prefer returning floats or strings,
  or switch to the JSON backend, when the result is numeric.
- **`result = None` is indistinguishable from "script failed to set
  `result`"** — both return Ruby `nil`. The save snippet writes nothing when
  `result` is `None` or undefined, and `script()` returns `nil` whenever the
  result file is absent.

## Common mistakes

### Forgetting to set the `result` variable

The script must set a Python variable named `result`. If it doesn't (or sets
it to `None`), no result file is written and `script()` silently returns
`nil`; it does **not** raise. The save snippet is wrapped in
`try: result / except NameError: result = None`, so a missing variable is
absorbed rather than reported:

```python
# Bad — no result variable
ScoutPython.script <<~PY
  x = 42
PY
# => nil, no error

# Good
ScoutPython.script <<~PY
  result = 42
PY
```

### Exceptions and error reporting

Any unhandled Python exception, syntax error or non-zero exit makes
`script()` raise `ConcurrentStreamProcessFailed`. The message contains only
the **last line of the Python traceback** (scout-essentials keeps a rolling
one-line log of the subprocess):

```
Process 12 failed - Error joining fd 8. Last log line: ValueError: BOOM
```

So the exception class and message survive, but the traceback body (file and
line numbers) is lost. To see it, set `Log.severity = 0` (or run with
`SCOUT_LOG=debug`), which makes `CMD.cmd_log` mirror the full stderr to the
Scout log/terminal. Note that the exception has no structured payload — it
only exposes `pid` and `msg`.

### Temp files and cleanup

- The generated program is passed on **stdin** to `env PYTHONPATH=... python`;
  there is no `.py` temp file.
- TSV variables are each dumped to one temp file under Scout's `tmp/`
  directory (name `tmp-<random>` from `TmpFile.tmp_file`, content = the TSV
  text). The generated assignment is `name = scout.tsv('<path>')`, which is
  a **single-quoted** Python literal interpolated directly into the program —
  a TSV variable name containing an apostrophe would break it.
  They are deleted right after the subprocess finishes, **including when the
  script raises** — the cleanup line sits outside any error handling.
- The result file is a temp file that is **never** deleted by `script()`;
  it stays behind on both success and failure (on failure it simply never
  gets written).

### Using pickle for non-picklable objects

The default pickle persistence works for most Python objects, but some
objects (e.g., file handles, lambda functions) cannot be pickled. Use JSON
persistence if your result is a simple data structure (dict, list, str,
number).

### Performance for repeated calls

Each `script()` call spawns a new Python process. For repeated calls, use
`run` or `run_direct` to execute multiple operations in a single Python
session.

### Environment of the subprocess

The subprocess is launched as `env PYTHONPATH=<ScoutPython.paths joined by
':'> python`, which means:

- `ScoutPython.paths` is what makes `import scout` work; it is populated
  from `Scout.python.find_all` (in this checkout, the repository's
  `python/` directory).
- **Any `PYTHONPATH` you set in the parent process is discarded**, because
  the `env` prefix replaces it rather than extending it. If your script
  needs another Python path, add it with `ScoutPython.add_path(...)` before
  calling `script()` (that list is also used for the in-process `sys.path`).
- The rest of the environment is inherited normally.

## See also

- [Passing Data to Python](PassingDataToPython.md) — In-process data conversion.
- [Running Python from Ruby](RunningPythonFromRuby.md) — In-process execution.
- [Data Conversion Internals](../developer/DataConversionInternals.md) — How
  serialization works internally.
