# Design Principles

This document explains the coding philosophy and idiomatic patterns behind
scout-rig. Scout-rig is part of the Scout ecosystem and follows its
conventions, but has its own emphasis because of its unique role bridging
Ruby and Python.

## Audience

This page is intended for:

- ✓ Framework contributors
- ✓ Advanced workflow authors who want to write idiomatic code
- ✗ Users looking for usage instructions (see [User Documentation](../user/))

## Core philosophy

Scout-rig bridges two language runtimes. The hardest part of a bridge is not
the mechanics of crossing the boundary — it's deciding where the abstraction
boundaries go and keeping them clean.

The Scout philosophy is:

1. **Thin wrappers, not thick abstractions** — Wrap existing tools (PyCall,
   CLI, pandas) ergonomically without hiding them behind layers of indirection.
2. **Unix philosophy** — Text, files, and processes as universal interfaces.
3. **Explicit over implicit** — Make the user say what they mean (e.g.,
   explicit converters) rather than guessing.

## Key patterns

### 1. Layered execution modes

Each mode adds exactly one concern to the layer below. This is the Scout
"setup pattern" applied to execution semantics:

```ruby
# run_direct: raw PyCall.eval
# run_simple: + MUTEX.synchronize
# run:        + init_scout + GC
# run_threaded: + dedicated thread + queue
# run_log:    + Log trapping
```

This is idiomatic Scout: compose by layering, not by branching. The user
picks the layer that matches their isolation/overhead needs.

**Anti-pattern:** A single `run` method with flags (`run(threads: true,
log: true, direct: true)`) would be harder to read and test.

### 2. The `script()` facility as a Unix pipe

`script()` treats the Ruby→Python boundary like a Unix pipe:

1. Ruby variables are serialized (Ruby → Python literals or temp files).
2. A Python script is assembled (assignments + body + save result).
3. Python runs in a subprocess.
4. The result is read back from a file.

This follows the Unix principle of using text/files as the universal
interface. The advantage is complete isolation (no GIL, no state leakage).
The tradeoff is process startup overhead.

### 3. Metadata-driven task definition

`python_task` discovers a Python function's inputs from its type hints and
docstring, automatically declaring the Scout task:

```ruby
python_task :hello
# Discovers: name (str), excited (bool, default=False), returns str
```

This eliminates double-declaration and keeps the Python function as the
single source of truth. It follows the Scout principle of **annotated
objects**: metadata is attached to the object itself, not declared
elsewhere.

### 4. CLI-first cross-language communication

For PythonWorkflow, Ruby and Python communicate via CLI arguments and
stdout:

```
Ruby task input → CLI argument → Python function parameter
Python return value → stdout → Ruby result decoding
```

This mirrors how Scout itself operates: tasks are CLI-callable. Python
tasks are first-class Scout citizens.

### 5. Explicit converters, not transparent proxies

PyCall wraps Python objects in Ruby proxies. Scout-rig does not try to make
these proxies transparent. Instead, it provides explicit converters:

```ruby
# Idiomatic: explicit conversion
arr = ScoutPython.numpy2ruby(na)
hash = ScoutPython.obj2hash(dict)
list = ScoutPython.py2ruby_a(pylist)
```

**Anti-pattern:** Making PyCall proxies automatically respond to `each`,
`[]`, etc. This would require heavy `method_missing` usage and would hide
the cross-language boundary from the user.

### 6. Threading model: dedicated thread + queue

`run_threaded` uses a dedicated background thread with input/output queues.
All threaded access is serialized through the queue. This is simpler and
safer than trying to allow concurrent Python execution (which would require
managing GIL acquisition patterns beyond PyCall's capabilities).

### 7. The `scout` Python package as a thin CLI wrapper

The Python `scout` package does not embed the Ruby runtime. It shells out
to the Ruby CLI for all operations:

```python
# scout.workflow.Workflow.run() →
#   subprocess.run(['rbbt', 'workflow', 'task', ...])
```

This follows the Unix philosophy: compose processes, don't embed runtimes.
The tradeoff is CLI startup overhead per call.

## Idiomatic vs non-idiomatic examples

### Creating a Python task

**Idiomatic:**
```ruby
module MyWF
  extend Workflow
  extend PythonWorkflow
  self.name = 'MyWF'

  python_task :greet  # metadata-driven, zero boilerplate
end
```

**Non-idiomatic:**
```ruby
module MyWF
  extend Workflow
  self.name = 'MyWF'

  # Redundant declaration
  input :name, :string, "Name"
  input :excited, :boolean, "Excited?", false
  task :greet => :string do |name, excited|
    # Manual subprocess management
    cmd = "python greet.py --name #{name}"
    cmd += " --excited" if excited
    `#{cmd}`.strip
  end
  self.input :name  # Bookkeeping
  self.input :excited
end
```

### Running Python from Ruby

**Idiomatic:**
```ruby
# Import + execute in one call, use the right mode for the job
result = ScoutPython.run :numpy, as: :np do
  np.array([1, 2, 3]).mean()
end
```

**Non-idiomatic:**
```ruby
# Manual PyCall management
require 'pycall/import'
include PyCall::Import
pyimport :numpy, as: :np
# No mutex, no GC, no error handling
result = np.array([1, 2, 3]).mean()
```

### Converting data

**Idiomatic:**
```ruby
# Explicit conversion, clear intent
df = ScoutPython.tsv2df(tsv)
result = ScoutPython.run do
  df.shape
end
rows = ScoutPython.py2ruby_a(result[0])
```

**Non-idiomatic:**
```ruby
# Trying to use the PyCall proxy as a native Ruby object
df = ScoutPython.run do
  pandas.DataFrame.new(tsv.values)
end
df.each { |row| ... }  # Doesn't work — PyCall proxy
df.shape[0]            # Works but opaque
``

### Passing data to script()

**Idiomatic:**
```ruby
# Let ruby2python handle serialization
result = ScoutPython.script <<~PY, numbers: [1, 2, 3]
  result = sum(numbers)
PY
```

**Non-idiomatic:**
```ruby
# Manual serialization
json_str = JSON.generate([1, 2, 3])
result = ScoutPython.script <<~PY, numbers_json: json_str
  import json
  numbers = json.loads(numbers_json)
  result = sum(numbers)
PY
```

## Extension points

If you need to extend scout-rig, here are the natural extension points:

| Extension | Where | How |
|-----------|-------|-----|
| New execution mode | `lib/scout/python/run.rb` | Compose on top of existing modes |
| New data converter | `lib/scout/python/util.rb` | Add a class method to ScoutPython |
| New serialization format | `lib/scout/python/script.rb` | Re-point aliases |
| New type mapping | `lib/scout/workflow/python/task.rb` | Extend map_param / map_returns |
| New Python-side helper | `python/scout/` | Add module + `scout.task` |
| New remote client | `python/scout/workflow/remote.py` | Add class + HTTP methods |

## Principles summary

1. **Layering over branching.** Compose by stacking modes, not by flags.
2. **Files and text as universal interfaces.** Cross-process
   communication uses files and CLI.
3. **Metadata as single source of truth.** Type hints + docstrings drive
   task definition.
4. **Explicit over implicit.** Users call converters explicitly.
5. **Thin wrappers over thick abstractions.** ScoutPython wraps PyCall
   ergonomically; the Python package wraps the CLI ergonomically.

## See also

- [Architecture](Architecture.md) — Overall module map.
- [Scout-essentials Design Principles](https://github.com/mikisvaz/scout-essentials/blob/main/doc/developer/DesignPrinciples.md)
- [Scout-ai Design Principles](https://github.com/mikisvaz/scout-ai/blob/main/doc/developer/DesignPrinciples.md)
