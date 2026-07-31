# Data Conversion Internals

This document explains how scout-rig converts data between Ruby and Python,
both in-process (via PyCall) and across process boundaries (via serialization).

## Audience

This page is intended for:

- ✓ Framework contributors
- ✗ Workflow authors (see [Passing Data to Python](../user/PassingDataToPython.md) and [Scripting Python](../user/ScriptingPython.md))

## Why this exists

Ruby and Python have different object models. PyCall provides live object
proxies, but proxy objects can't be iterated, indexed, or manipulated with
standard Ruby methods. For cross-process communication (`script()` and
`python_task`), data must be serialized to files.

Scout-rig provides two conversion layers:

1. **In-process converters** — For use inside `run` blocks where PyCall
   objects are live.
2. **ruby2python serializer** — For `script()` where Ruby variables must
   become Python literals.

## In-process converters

These methods convert PyCall proxy objects to native Ruby types.

### numpy2ruby

```ruby
def self.numpy2ruby(na)
  ScoutPython.run_direct do
    list = na.tolist()  # numpy.ndarray.tolist()
    py2ruby_a(list)
  end
end
```

Calls `.tolist()` on the numpy array (Python-side conversion to list), then
converts the resulting Python list to a Ruby array.

### py2ruby_a

```ruby
def self.py2ruby_a(pylist)
  arr = []
  ScoutPython.iterate(pylist) { |e| arr << e }
  arr
end
```

Iterates a Python list-like and collects elements into a Ruby array. Uses
the `iterate` helper to handle the PyCall iterator protocol.

### list2ruby

```ruby
def self.list2ruby(pylist)
  list = ScoutPython.iterate_and_collect(pylist)
  list.map { |e| e.is_a?(PyCall::List) ? list2ruby(e) : e }
  list
end
```

Recursive version of `py2ruby_a` for nested lists.

### obj2hash / dict2hash

```ruby
def self.obj2hash(obj)
  hash = {}
  ScoutPython.iterate(obj.keys()) { |k| hash[k] = obj[k] }
  hash
end
```

Iterates `obj.keys()` and builds a Ruby hash. Works with any Python object
that supports `.keys()` and `[]` (dicts, DataFrames).

### tsv2df / df2tsv

```ruby
def self.tsv2df(tsv)
  ScoutPython.run "pandas", as: :pd do
    df = pd.DataFrame.new(
      tsv.values,
      index: tsv.keys,
      columns: tsv.fields
    )
    df.index.name = tsv.key_field
    df
  end
end
```

Builds a pandas DataFrame from TSV fields, keys, and key_field. The
TSV's `values` are passed to `pandas.DataFrame.new` as the data argument,
which PyCall converts to a Python list-of-lists.

```ruby
def self.df2tsv(df)
  ScoutPython.run do
    values = ScoutPython.obj2hash(df.values.tolist())
    keys   = ScoutPython.py2ruby_a(df.index.tolist())
    fields = ScoutPython.py2ruby_a(df.columns.tolist())
    key_field = df.index.name

    TSV.setup(values, key_field: key_field, fields: fields, type: :list)
  end
end
```

The reverse: extracts DataFrame values, index, and columns, then builds a
TSV. Note that `df.values.tolist()` returns a nested list; `obj2hash`
converts it because the DataFrame's `.values` attribute is a 2D array.

## ruby2python serializer (for script())

The `ruby2python` method serializes Ruby values to Python literal strings:

```ruby
def self.ruby2python(value)
  case value
  when nil      then "None"
  when TrueClass  then "True"
  when FalseClass then "False"
  when Integer, Float then value.to_s
  when String   then "\"#{value}\""
  when Symbol   then "\"#{value}\""
  when Array    then "[" + value.map { |v| ruby2python(v) }.join(", ") + "]"
  when Hash     then "{" + value.map { |k, v| "#{ruby2python(k)}: #{ruby2python(v)}" }.join(", ") + "}"
  when TSV      then tsv_to_pyvar(value)  # via temp file + scout.tsv()
  else
    raise "Cannot convert #{value.class} to Python"
  end
end
```

### TSV handling in ruby2python

When a TSV is passed to `script()`, it doesn't become a Python literal.
Instead:

1. The TSV is serialized to a temp file via `TmpFile.with_file`.
2. A Python assignment is generated: `df = scout.tsv("path")`.
3. The Python `scout.tsv()` function reads the file into a pandas DataFrame.

This avoids embedding large datasets as inline Python literals.

### script() assembly

The `script()` method assembles the final Python script from three parts:

```ruby
def self.script(text, variables = {})
  init_scout
  assignments = variables.map do |name, value|
    "#{name} = #{ruby2python(value)}"
  end.join("\n")

  full_script = [
    assignments,
    text,
    save_script_result_script(result_file)
  ].join("\n")

  TmpFile.with_file full_script do |script_file|
    out = CMD.cmd("python #{script_file}")
    load_result(result_file)
  end
end
```

## Result persistence

### save_script_result_script

Generates a Python snippet that saves the `result` variable to a file:

```python
import pickle
with open("{result_file}", "wb") as f:
    pickle.dump(result, f)
```

### load_result / load_json

`load_result` reads the pickle file using the `python/pickle` Ruby gem.
`load_json` reads a JSON file. The aliases `save_script_result` and
`load_result` can be re-pointed to JSON variants:

```ruby
class << ScoutPython
  alias save_script_result save_script_result_json
  alias load_result load_json
end
```

## Serialization format summary

| Context | Direction | Mechanism |
|---------|-----------|-----------|
| `run` block | Ruby → Python | PyCall auto-conversion |
| `run` block | Python → Ruby | py2ruby_a, numpy2ruby, obj2hash |
| `script()` scalar | Ruby → Python | Literal string (ruby2python) |
| `script()` TSV | Ruby → Python | Temp file + scout.tsv() |
| `script()` result | Python → Ruby | Pickle file or JSON file |
| `python_task` inputs | Ruby → Python | CLI arguments |
| `python_task` result | Python → Ruby | stdout (JSON/array/string) |

## Key design decisions

1. **PyCall proxies are opaque** — Rather than trying to make PyCall proxy
   objects behave like native Ruby objects, scout-rig provides explicit
   converters. This is clearer and avoids surprising behavior.

2. **TSV ↔ DataFrame is the primary cross-language data type** — Scout's
   TSV and Python's pandas DataFrame are natural equivalents. The
   converters are bidirectional and lossless.

3. **Files as serialization boundary** — For subprocess communication,
   data goes through files. This is the Unix philosophy: files as the
   universal interface.

4. **Pickle by default, JSON optional** — Pickle handles all Python objects
   but requires the `python/pickle` Ruby gem. JSON is simpler but limited to
   basic types.

5. **No auto-conversion of PyCall objects** — Users must explicitly call
   `py2ruby_a`, `numpy2ruby`, or `obj2hash`. This prevents accidental
   conversion overhead.

## See also

- [ScoutPython Internals](ScoutPythonInternals.md) — The execution modes.
- [PythonWorkflow Internals](PythonWorkflowInternals.md) — CLI-based data flow.
- [Passing Data to Python](../user/PassingDataToPython.md) — User-facing guide.
- [Scripting Python](../user/ScriptingPython.md) — User-facing guide.
