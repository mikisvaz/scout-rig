# Data Conversion and Scripting Analysis

> **Non-normative.** Investigation artifact.

## Overview

This analysis covers two related subsystems:

1. **ruby2python serialization** (`script.rb`) — How Ruby values are turned
   into Python literal strings for the `script()` facility.
2. **Data conversion helpers** (`util.rb`) — How PyCall objects are
   converted back to Ruby types.
3. **The `script()` facility** — Running ad-hoc Python text in a subprocess
   and returning the result.

## ruby2python (script.rb)

`ScoutPython.ruby2python(object)` converts Ruby objects to Python literal
strings. This is used by `script()` to inject Ruby variables into Python
source code.

### Type mapping

| Ruby type        | Python literal                      |
|------------------|-------------------------------------|
| `Float::INFINITY`| `inf`                               |
| `nil`            | `None`                              |
| `":NA"` (Symbol) | `None`                              |
| `Symbol`         | Quoted string: `"symbol"`           |
| `String`         | Quoted string (re escapes escaped)  |
| `Numeric`        | Literal number                      |
| `true`           | `True`                              |
| `false`          | `False`                             |
| `Array`          | `[ruby2python(e1), ...]`            |
| `Hash`           | `{k: v, ...}` (keys are symbols)    |
| `TSV`            | Written to temp file, loaded via `scout.tsv(file)` → pandas DataFrame |

### TSV handling in ruby2python

When a TSV is passed as a variable to `script()`:

1. A temporary file is created with the TSV content.
2. The Python code is prepended with `import scout; df = scout.tsv(file)`.
3. The variable name in the Python script refers to the DataFrame.

This means the script body can operate on the DataFrame directly:

```ruby
ScoutPython.script <<~PY, df: tsv
  result = df.loc["k2", "ValueB"]
PY
```

## script() facility

`ScoutPython.script(text, variables = {})`:

1. Serializes each key-value in `variables` into a Python assignment line.
2. For TSV values, writes them to a temp file and inserts a `scout.tsv()`
   loading line.
3. Appends a "save result" snippet to persist the Python variable `result`
   to a temp file (pickle by default).
4. Sets `PYTHONPATH` from `ScoutPython.paths`.
5. Executes the script via `CMD.cmd_log("env PYTHONPATH=... python3 ...")`.
6. Loads the result back (pickle via `python/pickle` gem by default).

### Result persistence alternatives

Default uses pickle:
- `save_script_result_pickle(file)` → `pickle.dump(result, file)`
- `load_pickle(file)` → Ruby reads via `python/pickle` gem

JSON alternative:
- `save_script_result_json(file)` → `json.dump(result, file)`
- `load_json(file)` → Ruby reads and parses JSON

The aliases `save_script_result` and `load_result` can be re-pointed:

```ruby
class << ScoutPython
  alias save_script_result save_script_result_json
  alias load_result load_json
end
```

### run_file

`ScoutPython.run_file(file, arg_str)` — Executes a Python file as a
subprocess with `PYTHONPATH` set from `ScoutPython.paths`:

```ruby
CMD.cmd("env PYTHONPATH=#{path_env} python '#{file}' #{arg_str}")
```

Returns a `ConcurrentStream` that responds to `.exit_status`, `.read`.

## Data conversion helpers (util.rb)

These convert PyCall-wrapped Python objects back into Ruby types:

### py2ruby_a / to_a

```ruby
ScoutPython.py2ruby_a(array_like)  # PyCall::List → Ruby Array
ScoutPython.to_a(array_like)        # alias
```

Uses `PyCall::List.(array).to_a`. Note: this is `PyCall::List` as a callable
(`call` method), not a constructor call with `new`.

### list2ruby

```ruby
ScoutPython.list2ruby(list)
```

Deeply converts nested PyCall::List objects to Ruby arrays. Only recurses
if the element is a `PyCall::List`.

### numpy2ruby

```ruby
ScoutPython.numpy2ruby(numpy_array)
```

Calls `numpy_array.tolist` (Python-side conversion to nested lists), then
passes through `list2ruby`.

### obj2hash

```ruby
ScoutPython.obj2hash(mapping_object)
```

Builds a Ruby Hash by iterating `mapping_object.keys` (using
`ScoutPython.iterate`) and reading `mapping_object[key]`. Works with any
Python object that has `.keys` and `[]` access (dicts, pandas DataFrames,
etc.).

### dict2hash

```ruby
ScoutPython.dict2hash(dict)
```

Similar to `obj2hash` but uses `py2ruby_a(obj.keys)` and `obj.get(k)` for
key extraction. Uses the PyCall `.get()` method instead of `[]`.

### tsv2df

```ruby
ScoutPython.tsv2df(tsv)
```

Converts a Ruby TSV to a pandas DataFrame:

```python
pandas.DataFrame.new(tsv.values, columns: tsv.fields, index: tsv.keys)
df.columns.name = tsv.key_field
```

Requires Python pandas to be available.

### df2tsv

```ruby
ScoutPython.df2tsv(dataframe, options = {})
```

Converts a pandas DataFrame back to a Ruby TSV:

1. Default `options[:type] = :list`
2. Key field: `dataframe.columns.name`
3. Fields: `py2ruby_a(dataframe.columns.values)`
4. Keys: `py2ruby_a(dataframe.index.values)`
5. Iterates rows with `PyCall.len(tuple.index)` and `tuple.values[i]`.

## Key findings

1. **The script() facility is powerful but subprocess-based** — Each call
   spawns a new Python process. This is clean (no GIL issues) but slow for
   repeated calls. For frequent calls, use `run`/`run_direct` instead.

2. **The TSV↔DataFrame conversion is bidirectional and tested** —
   `df2tsv(tsv2df(tsv)) == tsv` is verified by tests.

3. **ruby2python string escaping is minimal** — Uses `value.inspect` for
   strings, which handles Ruby string escaping but may not perfectly match
   Python string semantics for all edge cases (e.g., Python-specific escape
   sequences).

4. **obj2hash vs dict2hash** — Two very similar methods with subtle
   differences. `obj2hash` uses `ScoutPython.iterate` and `obj[k]`; `dict2hash`
   uses `py2ruby_a` and `obj.get(k)`. The existence of both suggests an
   evolution that wasn't fully consolidated.

5. **pickle dependency** — The default `load_pickle` depends on the
   `python/pickle` Ruby gem. If not installed, `script()` will fail unless
   aliases are re-pointed to JSON.
