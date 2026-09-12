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
   become Python literals (and TSVs become temp files), plus a pickle/JSON
   result file read back on the Ruby side.

## In-process converters

These methods convert PyCall proxy objects to native Ruby types.

### numpy2ruby

```ruby
def self.numpy2ruby(numpy)
  list2ruby(numpy.tolist)
end
```

Calls `.tolist` on the numpy array (Python-side conversion to nested lists)
and recursively converts the result. Because it goes through `list2ruby`,
the result is a genuinely nested Ruby `Array` — but the elements inside are
whatever PyCall yields:

| numpy dtype | `numpy2ruby` result |
|-------------|---------------------|
| `int64` (2D) | `[[1, 2], [3, 4]]` |
| `float64` with `NaN` | `[1.0, NaN]` (Ruby `Float::NAN`) |
| `bool` | `[true, false]` |
| `<U1` strings | `["x", "y"]` |
| `object` mixed (`1`, `"a"`) | `["1", "a"]` — PyCall stringifies mixed-object elements |
| `datetime64[D]` | opaque objects inspecting as `datetime.date(2020, 1, 1)` |

### py2ruby_a

```ruby
def self.py2ruby_a(array)
  PyCall::List.(array).to_a
end
```

Converts a Python list to a Ruby array **one level deep**. Nested members
stay as PyCall proxies (they compare equal to the equivalent Ruby array but
are not `Array`s), so use `list2ruby` for nested data. `to_a` is aliased
to this method.

### list2ruby

```ruby
def self.list2ruby(list)
  return list unless PyCall::List === list
  list.collect do |e|
    list2ruby(e)
  end
end
```

Recursive conversion: every `PyCall::List` member is converted again,
everything else is returned unchanged (including other PyCall proxies such
as tuples or dicts nested inside the list).

### obj2hash / dict2hash

```ruby
def self.obj2hash(obj)
  hash = {}
  ScoutPython.iterate obj.keys do |k|
    hash[k] = obj[k]
  end
  hash
end
```

Iterates `obj.keys` and builds a Ruby hash. Values are **not** converted:
on a DataFrame `h["x"]` is the live pandas `Series` proxy, so convert it
yourself or use `df2tsv`.

```ruby
def self.dict2hash(obj)
  keys = py2ruby_a(obj.keys)
  hash = {}
  keys.each do |k|
    hash[k] = obj.get(k)
  end
  hash
end
```

Reads values with `obj.get(k)`, so it is intended for real `dict`s; it
returns eagerly converted values (`{"x" => 1}`). Calling it on a DataFrame
does not fail loudly — `get` resolves to something else and the value is
the Series proxy anyway — so it is not a route to converted DataFrame
columns.

### tsv2df / df2tsv

The implementation is significantly different from what earlier drafts of
this page described; the code below is the real code.

```ruby
def self.tsv2df(tsv)
  df = nil
  ScoutPython.run_direct 'pandas' do
    df = pandas.DataFrame.new(tsv.values, columns: tsv.fields, index: tsv.keys)
    df.columns.name = tsv.key_field
  end
  df
end
```

Builds a pandas DataFrame from TSV values, fields and keys, and records the
key field as the **column** axis name (`df.columns.name`), not
`df.index.name`. `tsv.values` is passed as the data argument, which PyCall
converts to a Python list-of-lists. Because the data is built in-process,
no pandas inference happens: a `:list` TSV of strings yields an `object`
column of exactly those strings (including `"NA"` and `"1.5"`).

```ruby
def self.df2tsv(tuple, options = {})
  options = IndiferentHash.add_defaults options, :type => :list
  IndiferentHash.setup options
  tsv = TSV.setup({}, options)
  tsv.key_field = options[:key_field] || tuple.columns.name.to_s
  tsv.fields = py2ruby_a(tuple.columns.values)
  keys = py2ruby_a(tuple.index.values)
  PyCall.len(tuple.index).times do |i|
    k = keys[i]
    tsv[k] = py2ruby_a(tuple.values[i])
  end
  tsv
end
```

The reverse. Notes:

- The result is always `type: :list` (overridable with `options[:type]`),
  and `key_field` falls back to `tuple.columns.name.to_s` — which is why
  `tsv2df` setting `columns.name` (not `index.name`) matters for
  round-tripping the key field name.
- Values are read row-wise with `tuple.values[i]` and converted **flat**
  with `py2ruby_a`; for a DataFrame the row is a numpy array, and this
  works because `py2ruby_a` handles array-likes whose elements are scalars.
- A `tsv2df` → `df2tsv` round-trip on a well-formed `:list` TSV preserves
  keys, fields, key field name, type and values (verified for values
  containing `;`, `,`, quotes and `":NA"`). It does **not** preserve
  `:double`/`:flat` types (everything becomes `:list`) and it cannot
  preserve values that pandas had already coerced (e.g. a DataFrame read
  from a file by `scout.tsv()`, where `"NA"` is already `NaN`).

## ruby2python serializer (for script())

The `ruby2python` method serializes Ruby values to Python literal strings:

```ruby
def self.ruby2python(object)
  case object
  when Float::INFINITY
    "inf"
  when nil
    "None"
  when ":NA"
    "None"
  when Symbol
    "#{ object }"
  when String
    object = object.dup if Path === object
    object[0] == ":" ? object[1..-1] : "'#{ object }'"
  when Numeric
    object
  when TrueClass
    "True"
  when FalseClass
    "False"
  when Array
    "[#{object.collect{|e| ruby2python(e) } * ", "}]"
  when Hash
    "{" << object.collect{|k,v| [ruby2python(k.to_s), ruby2python(v)] * ":"} * ", " << "}"
  else
    raise "Type of object not known: #{ object.inspect }"
  end
end
```

Divergences from a "safe" serializer, all verified by probe:

- Strings are emitted inside **single quotes with no escaping**, so `"it's"`
  and strings containing newlines produce invalid Python. Double quotes,
  backslashes, tabs and non-ASCII round-trip.
- A leading `":"` in a `String` **strips the colon** (`":abc"` → the bare
  name `abc`), and the exact string `":NA"` maps to `None`.
- `Symbol`s are emitted **unquoted**, so they must be valid Python
  identifiers; `:d-f` emits `d-f` and the subprocess fails.
- `Float::INFINITY` emits the name `inf`, which is undefined unless the
  script imports it.
- `Hash` keys are coerced with `k.to_s` (so `1` → `"1"`, arrays/booleans →
  their `to_s`) and are then subject to the same leading-colon stripping.
- `Numeric` (including `Integer`) is interpolated via `to_s`, not quoted.
- Unknown classes raise `Type of object not known: ...`; a `Path` is dup'd
  into a plain `String` first and serialized as a quoted literal.

### TSV handling in ruby2python

When a TSV is passed to `script()`, it doesn't become a Python literal.
Instead (`load_script_variables`, not `ruby2python` itself):

1. The TSV is dumped to a temp file with `Open.write(tmp_file, value.to_s)`,
   where `tmp_file` comes from `TmpFile.tmp_file` (a `tmp-<random>` name in
   Scout's tmp dir). Note this is a raw `to_s` dump, **not** an escaped dump.
2. A Python assignment is generated: `df = scout.tsv('<tmp_file>')` — the
   path is interpolated into a single-quoted literal.
3. The Python `scout.tsv()` function (`pandas.read_table`) reads the file
   into a pandas DataFrame.

This avoids embedding large datasets as inline Python literals. Because
step 3 goes through `read_table`, the DataFrame the script sees carries
pandas' own inference (`NA`/`""`/`nan`/`None` → `NaN`, numeric-looking
columns → `float64`), unlike the in-process `tsv2df` which preserves the
Ruby strings as an `object` column.

### script() assembly

The actual implementation (simplified only by eliding the no-variable
branch, which skips the preamble):

```ruby
def self.script(text, variables = {})
  if variables.any?
    variable_definitions, tmp_files = load_script_variables(variables)
    text = variable_definitions + "\n" + text
  end

  tmp_file = TmpFile.tmp_file
  path_env = ScoutPython.paths * ":"

  CMD.cmd_log("env PYTHONPATH=#{path_env} python", {in: text})

  tmp_files.each{|file| Open.rm_rf file } if tmp_files
  if Open.exists?(tmp_file)
    load_result(tmp_file)
  end
end
```

Points the previous documentation got wrong or omitted:

- The program is **not written to a `.py` file**. It is piped on **stdin**
  to `env PYTHONPATH=<ScoutPython.paths joined by ':'> python` via
  `CMD.cmd_log`, so no script file appears in the tmp dir and the assembled
  text never needs a filename-safe encoding.
- `CMD.cmd_log` (as opposed to `CMD.cmd`) does not return output; it logs
  the subprocess stdout to the Scout log and raises
  `ConcurrentStreamProcessFailed` when the process exits non-zero. That
  exception is the only failure signal `script()` surfaces.
- The variable preamble (`# Variables\nimport scout\n` plus one
  assignment per variable) is prepended to the user text; `import scout`
  is always present, which is why `scout.tsv` is available even in scripts
  that never import anything themselves.
- The result file path (`tmp_file`) is **generated but never deleted**;
  the TSV variable dumps (`tmp_files`) are deleted right after
  `cmd_log` returns, on success or failure, because the `each` sits after
  the call rather than in an `ensure`.
- `load_result(tmp_file)` is only reached when the result file exists; a
  script that never sets `result` (or sets it to `None`) therefore returns
  Ruby `nil` silently.

## Result persistence

### save_script_result_pickle

`save_script_result_pickle` (aliased as `save_script_result`) generates the
snippet appended to every script. The real text is:

```python
# Save
try: result
except NameError: result = None
if result is not None:
  import pickle
  file = open('<result_file>', 'wb')
  pickle.dump(result, file)
```

Three consequences:

- An undefined `result` is **absorbed** (`except NameError: result = None`),
  so a script that forgets to set `result` runs to completion and
  `script()` returns `nil`.
- `result = None` writes nothing, for the same reason: the file is only
  created when `result is not None`. It is therefore impossible to
  distinguish "returned None" from "returned nothing".
- The default protocol is whatever the running Python chooses
  (`pickle.DEFAULT_PROTOCOL`); on Python 3.13 that is protocol 4.

`save_script_result_json` emits the same `try/except NameError` and
`if result is not None` guard and then writes
`file.write(json.dumps(result))` — so with the JSON backend a missing
`result` also yields `nil`, and a `None` result writes nothing (not
`null`).

### load_result / load_pickle

`load_result` (aliased to `load_pickle`) reads the file with the
`python/pickle` gem. The aliases can be re-pointed to the JSON variants:

```ruby
class << ScoutPython
  alias save_script_result save_script_result_json
  alias load_result load_json
end
```

### Pickle protocol limitations

The `python/pickle` gem (0.2.0) does not implement every opcode of the
default protocol. Empirically, on the installed Python 3.13:

- Integers outside `0..255` fail. `pickle.dumps(256)` uses `BININT2`
  (opcode `M`, 0x4D) and `pickle.dumps(-1)`/`70000` use `BININT` (opcode
  `J`, 0x4A); the gem's protocol-4 reader only handles `BININT1` (`K`,
  0x4B), so `Python::Pickle::InvalidFormat: invalid opcode (74)` (and 77)
  is raised for any integer that does not fit in one unsigned byte.
- `dict` values pickled with `NEWOBJ` (e.g. numpy scalars such as
  `np.float64`) come back as raw `Python::Pickle::PyObject` wrappers with
  no conversion to a Ruby number.
- `datetime.date` similarly yields an opaque `PyObject` describing the
  `datetime.date` constructor rather than a Ruby `Date`.

Strings, bools, small integers, `inf`/`NaN` floats, lists, dicts, tuples
and bytes round-trip; bytes decode to their ASCII contents.

**Practical rule:** if the result is not a plain scalar/list/dict of basic
types, prefer the JSON backend, or convert to basic types inside the script
(`int(x)`, `x.item()`, `str(x)`).

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

The `python_task` row is described in
[PythonWorkflow Internals](PythonWorkflowInternals.md); its decoding is
`JSON.parse(txt)` first, then a newline split for array returns, then the
raw string — which is where the A2 ambiguity (a string return that is
itself valid JSON being decoded as a structure) lives.

## Key design decisions

1. **PyCall proxies are opaque** — Rather than trying to make PyCall proxy
   objects behave like native Ruby objects, scout-rig provides explicit
   converters. This is clearer and avoids surprising behavior.

2. **TSV ↔ DataFrame is the primary cross-language data type** — Scout's
   TSV and Python's pandas DataFrame are natural equivalents. The
   converters are bidirectional, but "lossless" needs qualification:
   the in-process pair `tsv2df`/`df2tsv` round-trips a well-formed
   `:list` TSV exactly (values including `;`, `,`, quotes and `":NA"`),
   while the `script()` file path necessarily passes through pandas'
   NA and dtype inference and therefore is not lossless for `"NA"`,
   empty strings, or numeric-looking strings.

3. **Files as serialization boundary** — For subprocess communication,
   data goes through files. This is the Unix philosophy: files as the
   universal interface.

4. **Pickle by default, JSON optional** — Pickle handles all Python objects
   on the writing side, but the `python/pickle` Ruby gem reading it back is
   far less capable than CPython (see "Pickle protocol limitations" above);
   integers outside `0..255` already fail. JSON is simpler and, for basic
   types, the more reliable direction on this gem version.

5. **No auto-conversion of PyCall objects** — Users must explicitly call
   `py2ruby_a`, `numpy2ruby`, or `obj2hash`. This prevents accidental
   conversion overhead.

## See also

- [ScoutPython Internals](ScoutPythonInternals.md) — The execution modes.
- [PythonWorkflow Internals](PythonWorkflowInternals.md) — CLI-based data flow.
- [Passing Data to Python](../user/PassingDataToPython.md) — User-facing guide.
- [Scripting Python](../user/ScriptingPython.md) — User-facing guide.
