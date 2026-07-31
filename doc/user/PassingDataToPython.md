# Passing Data to Python

This document explains how to convert Ruby data structures to Python and
back, so you can pass data between the two languages efficiently.

## Audience

This page is intended for:

- ✓ Workflow authors passing data between Ruby and Python
- ✓ Agent developers building cross-language tools
- ✗ Framework contributors (see [Data Conversion Internals](../developer/DataConversionInternals.md))

## When to use this

Use the data conversion helpers when you need to:

- Pass a Ruby TSV to Python as a pandas DataFrame.
- Get a Python numpy array back as a Ruby array.
- Convert Python dicts/lists to Ruby hashes/arrays.
- Read Python computation results into Ruby data structures.

## Core concepts

ScoutPython provides two categories of converters:

1. **In-process converters** — Used inside `run` blocks where PyCall keeps
   Ruby and Python objects alive in the same process. Fast, no serialization.

2. **Serialization for `script()`** — Used when passing Ruby variables into
   a Python subprocess via `script()`. Slower (involves file I/O) but works
   across process boundaries.

## TSV ↔ pandas DataFrame

### TSV to DataFrame

```ruby
tsv = TSV.setup([], key_field: "Gene", fields: %w(LogFoldChange PValue), type: :list)
tsv["BRCA1"] = [2.5, 0.001]
tsv["TP53"]  = [-1.8, 0.003]

df = ScoutPython.tsv2df(tsv)
```

The resulting DataFrame has:
- Index: the TSV keys (`BRCA1`, `TP53`)
- Columns: the TSV fields (`LogFoldChange`, `PValue`)
- Column name: the key field (`Gene`)

### DataFrame to TSV

```ruby
new_tsv = ScoutPython.df2tsv(df)
# new_tsv is a Ruby TSV with type :list by default
```

The round-trip is lossless: `df2tsv(tsv2df(tsv)) == tsv`.

## Numpy arrays to Ruby arrays

```ruby
result = ScoutPython.run :numpy, as: :np do
  na = np.array([[1, 2, 3], [4, 5, 6]])
  ScoutPython.numpy2ruby(na)
end
# result is a nested Ruby Array: [[1, 2, 3], [4, 5, 6]]
```

`numpy2ruby` calls `.tolist()` on the numpy array (Python-side conversion),
then maps the result to Ruby arrays.

## Python lists to Ruby arrays

```ruby
result = ScoutPython.run do
  pyimport :json
  pylist = json.loads('[1, 2, 3]')
  ScoutPython.py2ruby_a(pylist)
end
# result is a Ruby Array: [1, 2, 3]
```

For deeply nested lists, use `list2ruby` which recurses:

```ruby
nested = ScoutPython.run do
  pyimport :json
  ScoutPython.list2ruby(json.loads('[[1, 2], [3, 4]]'))
end
# nested is [[1, 2], [3, 4]] (all nested PyCall::List converted)
```

## Python dicts to Ruby hashes

```ruby
result = ScoutPython.run do
  pyimport :json
  d = json.loads('{"a": 1, "b": 2}')
  ScoutPython.obj2hash(d)
end
# result is {"a" => 1, "b" => 2}
```

`obj2hash` works with any Python object that has `.keys` and `[]` access
(dicts, DataFrames, etc.).

## Passing data via `script()`

When using `script()` to run Python in a subprocess, variables are
serialized differently — see [Scripting Python](ScriptingPython.md) for
details. The key difference is:

- **In-process (`run`):** PyCall maintains object identity. Use `tsv2df`,
  `py2ruby_a`, `numpy2ruby`.
- **Subprocess (`script`):** Data goes through files. TSVs become temp
  files loaded via `scout.tsv()`. Results are pickled or JSON-encoded.

## Common mistakes

### Using `py2ruby_a` on non-list objects

`py2ruby_a` expects a list-like Python object. For dicts, use `obj2hash`
or `dict2hash`.

### Not importing numpy before `numpy2ruby`

`numpy2ruby` calls `.tolist()` on the numpy object. The numpy array must
already exist in the Python environment. This happens naturally inside a
`run` block.

### Forgetting that script() TSV variables become DataFrames

When you pass a TSV to `script()`, the Python variable is a pandas
DataFrame, not a file path:

```ruby
# df is a pandas DataFrame in Python, not a file path
ScoutPython.script <<~PY, df: tsv
  result = df.shape  # DataFrame attribute
PY
```

## See also

- [Scripting Python](ScriptingPython.md) — The subprocess scripting facility.
- [Running Python from Ruby](RunningPythonFromRuby.md) — Execution modes.
- [Annotating Data](https://github.com/mikisvaz/scout-essentials/blob/main/doc/user/AnnotatingData.md)
  in scout-essentials — The TSV data structure.
