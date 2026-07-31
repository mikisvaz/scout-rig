# ScoutPython Internals

This document explains the internal architecture of ScoutPython, the
Ruby-facing API for executing Python code via PyCall.

## Audience

This page is intended for:

- ✓ Framework contributors
- ✗ Workflow authors (see [Running Python from Ruby](../user/RunningPythonFromRuby.md))

## Why this exists

PyCall provides the raw Ruby↔Python bridge, but it has several gaps that
ScoutPython fills:

1. **No lazy initialization** — PyCall must be initialized before use,
   but doesn't guard against double-init.
2. **No threading safety** — PyCall operations require GIL acquisition.
3. **No shutdown management** — Python objects must be GC'd before the
   GIL becomes unavailable.
4. **No import ergonomics** — PyCall requires verbose `pyimport` calls.
5. **No subprocess alternative** — PyCall is in-process only.

ScoutPython wraps PyCall with layered execution modes, a threading model,
an at_exit hook, import helpers, and a subprocess-based scripting facility.

## Execution mode hierarchy

Each mode composes the one below it. Understanding this layering is key to
understanding the code.

```
run          → init_scout + run_simple + GC
run_simple   → MUTEX.synchronize + module_eval
run_direct   → PyCall.eval (raw)
run_threaded → queue + dedicated thread + init_in_thread + run_simple
run_log      → run + Log.trap_std/trap_stderr
```

### run_direct

```ruby
def self.run_direct(mod = nil, *args, as: mod, import: nil, &block)
  new_binding = Binding.new  # fresh PyCall::Import scope
  new_binding.extend mod, as: as, import: import
  new_binding.instance_exec(*args, &block)
end
```

`run_direct` creates a fresh `Binding`, extends it with the requested import,
and `instance_exec`s the block. No synchronization, no initialization
checking, no GC.

**Warning:** Using `run_direct` before PyCall is initialized will crash.

### run_simple

```ruby
def self.run_simple(mod = nil, *args, as: mod, import: nil, &block)
  MUTEX.synchronize do
    ScoutPython.extend mod, as: as, import: import
    ScoutPython.instance_exec(*args, &block)
  end
end
```

Adds `MUTEX.synchronize` for thread safety and runs the block in the
`ScoutPython` module scope (so imports persist on the module).

### run

```ruby
def self.run(mod = nil, *args, as: mod, import: nil, &block)
  init_scout
  res = run_simple(mod, *args, as: as, import: import, &block)
  GC.start
  res
end
```

Adds initialization check and post-execution GC. This is the recommended
default.

### run_threaded

Uses a dedicated background thread with a queue:

```ruby
QUEUE_IN  = Queue.new
QUEUE_OUT = Queue.new

def self.run_in_thread(mod, *args, as:, import:, &block)
  init_thread  # lazily creates the background thread
  MUTEX.synchronize do
    QUEUE_IN.push [mod, args, as, import, block]
    QUEUE_OUT.pop  # blocks until result is ready
  end
end

# The background thread loop:
Thread.new do
  ScoutPython.init_scout
  ScoutPython.process_paths
  loop do
    item = QUEUE_IN.pop
    break if item == :stop
    result = begin
      mod, args, as, import, block = item
      run_simple(mod, *args, as: as, import: import, &block)
    rescue => e
      e
    end
    QUEUE_OUT.push result
  end
end
```

All threaded access is serialized through the queue. This is safe but
concurrent `run_threaded` calls block each other.

### run_log

```ruby
def self.run_log(mod = nil, *args, as: mod, import: nil, &block)
  Log.trap_stderr do
    Log.trap_std do
      run(mod, *args, as: as, import: import, &block)
    end
  end
end
```

Wraps `run` with Scout's log trapping, capturing Python stdout/stderr into
the Scout logging system.

## Initialization and shutdown

### init_scout

Guarded by `@@__init_scout_python` class variable to ensure one-time
initialization:

```ruby
@@__init_scout_python = nil

def self.init_scout
  return if @@__init_scout_python

  PyCall.init
  process_paths
  pyimport "scout"

  @@__init_scout_python = true

  at_exit do
    Thread.list.each do |thread|
      next if thread == Thread.main
      thread.kill
      thread.join rescue nil
    end
    GC.start
    PyCall.builtins.object  # GIL health check
  end
end
```

### at_exit hook

The shutdown sequence is critical:

1. **Kill all non-main threads** — Including the ScoutPython background thread.
2. **GC.start** — Finalize Python objects while the GIL is still available.
3. **Touch PyCall.builtins.object** — Verify GIL is still healthy.

If GC happens after the GIL is gone, PyCall object finalizers will segfault.

**Known issue:** The at_exit hook kills ALL non-main threads, not just the
ScoutPython thread. This could interfere with other threading code in the
process. See [Improvements](../Improvements.md).

## Path management

`ScoutPython.paths` is an array of directories to add to Python's `sys.path`.

- `add_path(path)` — Append a path.
- `process_paths` — For each registered path, call `sys.path.append(path)`.

At load time, all Python directories registered via the Scout Path subsystem
are added: `ScoutPython.add_paths(Scout.python.find_all)`.

**Known issue:** `process_paths` is called multiple times (in `init_scout`,
`run_simple`, and `init_thread`) and does not deduplicate. Paths may
accumulate duplicates in `sys.path`.

## Binding scopes

```ruby
class Binding
  include PyCall::Import
end
```

Each `Binding` instance gets its own import namespace via
`PyCall::Import`. This allows isolated imports:

```ruby
ScoutPython.binding_run do
  pyimport :torch  # only available in this block
end
```

**Known issue:** `binding_run` always creates a new binding, ignoring its
`binding` parameter:

```ruby
def self.binding_run(binding = nil, *args, &block)
  binding = new_binding  # parameter overwritten!
  binding.instance_exec(*args, &block)
end
```

## Import helpers

| Method | What it does |
|--------|-------------|
| `import_method(mod, method, as=nil)` | `pyimport mod; pyfrom mod, import: method` → Ruby Method |
| `call_method(mod, method, *args)` | Import + call in one step |
| `get_module(mod)` | `pyimport mod` (aliased with underscores for dotted names) |
| `get_class(mod, cls)` | Import module, return `module.cls` |
| `class_new_obj(mod, cls, args={})` | Import class + instantiate with kwargs |
| `exec(script)` | `PyCall.exec(script)` |

The `get_module` helper aliases dotted module names with underscores:
`torch.nn` becomes accessible as `ScoutPython.torch_nn`. This avoids method
name conflicts.

## Iteration

Three methods traverse Python iterables:

1. **`iterate(obj)`** — Tries `__iter__`/`__next__` protocol first. If the
   object is not iterable, falls back to `iterate_index`. Detects
   `StopIteration` by matching the exception type string.
2. **`iterate_index(obj)`** — Uses `PyCall.len(obj)` and `obj[i]`.
3. **`collect(obj)`** — Gathers all elements into a Ruby array.

**StopIteration detection:** Uses `$!.type.to_s == "<class 'StopIteration'>"`.
This string comparison is fragile but necessary because PyCall wraps Python
exceptions in `PyCall::PyError`.

## Threading model summary

```
Main thread                 Background thread
─────────────              ──────────────────
run_threaded { ... }
  │
  ├─ init_thread()──────────►Thread.new {
  │                           init_scout()
  │                           process_paths()
  ├─ QUEUE_IN.push(block)     loop {
  │                             item = QUEUE_IN.pop
  │   blocks ←                 break if item == :stop
  │                             run_simple { block }
  │                           }
  ├─ QUEUE_OUT.pop ─────────►result
  │                         }
  ▼
result
```

- All access is serialized through MUTEX.
- The thread can be restarted if it dies (`init_thread` checks
  `!self.thread.alive?`).
- `stop_thread` sends `:stop`, joins (2s timeout), or kills, then GCs.

## Key design decisions

1. **Layered execution modes** — Each mode adds exactly one concern. This
   makes the code easy to reason about and test.

2. **MUTEX for all in-process access** — Ensures thread safety for PyCall
   operations that require the GIL.

3. **Dedicated thread for isolated execution** — `run_threaded` provides a
   clean Python environment that doesn't pollute the main module namespace.

4. **at_exit for safe shutdown** — Critical for avoiding segfaults. GC must
   happen before GIL loss.

5. **Subprocess for complex work** — `script()` and `python_task` spawn
   new processes, avoiding GIL contention and state leakage entirely.

## See also

- [Architecture](Architecture.md) — Overall module map.
- [Data Conversion Internals](DataConversionInternals.md) — How script() and converters work.
- [Running Python from Ruby](../user/RunningPythonFromRuby.md) — User-facing guide.
