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
| String    | Quoted string         |
| Symbol    | Quoted string         |
| Array     | Python list literal   |
| Hash      | Python dict literal   |
| TSV       | pandas DataFrame (via temp file + `scout.tsv()`) |

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

## Common mistakes

### Forgetting to set the `result` variable

The script must set a Python variable named `result`. If it doesn't, the
script will fail when trying to save the result:

```python
# Bad — no result variable
ScoutPython.script <<~PY
  x = 42
PY

# Good
ScoutPython.script <<~PY
  result = 42
PY
```

### Using pickle for non-picklable objects

The default pickle persistence works for most Python objects, but some
objects (e.g., file handles, lambda functions) cannot be pickled. Use JSON
persistence if your result is a simple data structure (dict, list, str,
number).

### Performance for repeated calls

Each `script()` call spawns a new Python process. For repeated calls, use
`run` or `run_direct` to execute multiple operations in a single Python
session.

## See also

- [Passing Data to Python](PassingDataToPython.md) — In-process data conversion.
- [Running Python from Ruby](RunningPythonFromRuby.md) — In-process execution.
- [Data Conversion Internals](../developer/DataConversionInternals.md) — How
  serialization works internally.
