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
- Column name: the key field (`Gene`) — `tsv2df` sets `df.columns.name`,
  **not** `df.index.name`, which stays `nil`. Keep this in mind if you build
  DataFrames both ways: `scout.tsv()` (the file loader used by `script()`)
  does the opposite and sets `df.index.name` only.

Also note the values are passed through **unchanged**: a TSV column of
strings becomes a pandas `object` dtype column holding those exact strings
(`"1.5"` stays `"1.5"`), because the values travel as Python objects through
PyCall rather than being parsed by `read_table`. Type inference only happens
when a TSV goes through a file, i.e. in `script()` variables — see below.

### DataFrame to TSV

```ruby
new_tsv = ScoutPython.df2tsv(df)
# new_tsv is a Ruby TSV with type :list by default
```

The round-trip is lossless **for well-formed `:list` TSVs of string values**:
`df2tsv(tsv2df(tsv)) == tsv`. Verified round-tripping includes values that
contain `;`, `,` and `"` (the dump path escapes them), and the Ruby `:NA`
sentinel string (which stays the literal string `":NA"`).

Things that do **not** survive, verified by probe:

- **`tsv.key_field` is taken from `df.columns.name`, not the index name.**
  Round-tripping a DataFrame that was loaded by `scout.tsv()` (whose
  `columns.name` is unset) yields `key_field == ""`.
- **Type is forced to `:list`** (the default); the original TSV type is not
  remembered, and a `:flat`/`:single` TSV comes back as `:list` with nested
  single-element arrays.
- **Ragged rows** (a row with more values than the header has fields) raise
  `ValueError: Length mismatch` when loaded through `scout.tsv()` in
  `script()`, while the Ruby TSV tolerates them — the two loaders are
  asymmetric.
- **Numbers keep their TSV string form in-process** (`"1.5"` stays `"1.5"`);
  going through a file in `script()` converts the column to `float64`.

## Numpy arrays to Ruby arrays

```ruby
result = ScoutPython.run :numpy, as: :np do
  na = np.array([[1, 2, 3], [4, 5, 6]])
  ScoutPython.numpy2ruby(na)
end
# result is a nested Ruby Array: [[1, 2, 3], [4, 5, 6]]
```

`numpy2ruby` calls `.tolist()` on the numpy array (Python-side conversion),
then converts the result with `list2ruby`, which recurses into nested
`PyCall::List` objects.

Dtype behaviour, verified by probe:

| numpy dtype | Result in Ruby |
|-------------|----------------|
| `int64` (2-D) | nested Ruby `Array` of `Integer`: `[[1, 2], [3, 4]]` |
| `float64` with `NaN` | `Float`, with `NaN` as `Float::NAN` |
| `str` / `object` (strings) | `Array` of `String` |
| `object` (mixed `1`, `"a"`) | **all strings**: `["1", "a"]` — PyCall stringifies mixed objects |
| `bool` | `[true, false]` |
| `datetime64[D]` | **opaque objects**: Ruby `Object` whose `to_s` is `datetime.date(2020, 1, 1)`; call `.to_s`/`strftime` on the Python side first |

Note `numpy2ruby` requires numpy to be importable in the running session
(`ScoutPython.run(:numpy, as: :np)` above takes care of that); without it
`.tolist` is undefined.

## Python lists to Ruby arrays

```ruby
result = ScoutPython.run do
  pyimport :json
  pylist = json.loads('[1, 2, 3]')
  ScoutPython.py2ruby_a(pylist)
end
# result is a Ruby Array: [1, 2, 3]
```

For nested lists, use `list2ruby`, which recurses into `PyCall::List`
members:

```ruby
nested = ScoutPython.run do
  pyimport :json
  ScoutPython.list2ruby(json.loads('[[1, 2], [3, 4]]'))
end
# nested is [[1, 2], [3, 4]] — genuinely nested Ruby Arrays
```

By contrast `py2ruby_a` (and its `ScoutPython.to_a` alias) is **flat**: with
`[[1, 2], [3, 4]]` it returns a Ruby `Array` whose elements are still
PyCall list objects. They compare equal to the corresponding Ruby arrays
(`r.first == [1, 2]` is true) but are not `Array`s — use `list2ruby` when
you need real nested arrays.

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

`obj2hash` and `dict2hash` differ in one important way:

- **`dict2hash` reads values with `obj.get(k)`** and returns **eagerly
  converted** values (`{"x" => 1, "y" => 2}`). Use it for real dicts.
  On a DataFrame `get` resolves to something else entirely and you get the
  Series back anyway (`{"x" => <Series proxy>}`), so it is not a way to
  obtain converted DataFrame columns.
- **`obj2hash` reads values with `obj[k]`**, which on a DataFrame yields the
  **column as a live proxy** (a pandas `Series`), not a converted value.
  Convert it yourself (`ScoutPython.list2ruby(h["x"].tolist)`) or use
  `df2tsv` when you want native Ruby data out of a DataFrame.

Both build plain Ruby `Hash`es with the keys converted to Ruby strings.

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

### Assuming the file path preserves your types

Because `script()` TSV variables go through `scout.tsv()`
(`pandas.read_table`), pandas applies its own NA and type inference:
`NA`, `""`, `nan`, `None` all become `NaN` and a numeric-looking column
becomes `float64`. The Ruby `:NA` sentinel is protected by its leading
colon (`":NA"` survives as the literal string `":NA"`), but a plain `"NA"`
does **not** survive. If you need exact string round-tripping, keep the data
in-process (`tsv2df`) or quote/escape it yourself.

## See also

- [Scripting Python](ScriptingPython.md) — The subprocess scripting facility.
- [Running Python from Ruby](RunningPythonFromRuby.md) — Execution modes.
- [Annotating Data](https://github.com/mikisvaz/scout-essentials/blob/main/doc/user/AnnotatingData.md)
  in scout-essentials — The TSV data structure.
