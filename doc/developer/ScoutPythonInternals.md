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
In practice a plain `require 'scout/python'` already triggers
`PyCall.init` implicitly (the `require` runs `add_paths` →
`process_paths` → `pyimport :sys`, which resolves PyCall constants and
calls `PyCall.init`), so this is a contract statement about the mode rather
than a crash you can reproduce from a fresh require — but the mode itself
performs no initialization checking.

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

Why the `GC.start`? `run` returns `PyCall` object references to Ruby, and
PyCall finalizers must run while the GIL is still held by this thread. The
`ensure`-style GC forces Python-owned objects that became unreachable
during the call to be finalized promptly rather than at an arbitrary later
point (for example during VM shutdown, after the GIL situation has
changed). It is the same rationale as the `GC.start` inside the `at_exit`
hook. Note that the `GC.start` runs **outside** `MUTEX.synchronize` —
`run_simple` releases the mutex before returning.

Also note `run` calls `init_scout`, which is what calls `PyCall.init` — so
with `run` the *calling* thread is the thread that owns PyCall for the
lifetime of the process (see `run_threaded` for why that matters).

### run_threaded

Uses a dedicated background thread with a queue. The actual code in
`lib/scout/python/run.rb` is:

```ruby
def self.run_in_thread(&block)
  self.synchronize do
    init_thread
    QUEUE_IN.push block
    QUEUE_OUT.pop
  end
end

# init_thread's worker loop (lib/scout/python/run.rb:31-54)
Thread.new do
  require 'pycall'
  ScoutPython.init_scout
  ScoutPython.process_paths
  while block = QUEUE_IN.pop
    break if block == :stop
    res = module_eval(&block)   # rescued, logged and re-raised
    QUEUE_OUT.push res
  end
end
```

Sketch of the mechanism:

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

Verified behaviour (probes `probe_concurrency.rb` / `probe9.log`):

- `run_in_thread` holds `MUTEX` for the whole push/wait cycle, so two Ruby
  threads calling `run_threaded` at the same time execute strictly one
  after the other; each receives its own result. The Ruby-side blocks run
  inside the single worker thread via `module_eval`, never in parallel.
- An exception raised by the block is logged (`Log.exception`) and re-raised
  in the worker, which kills the worker thread; the waiting caller then
  blocks forever on `QUEUE_OUT.pop` — there is no `Timeout` or `Thread#value`
  rescue. (Probe `probe_thread_death.rb` / `probe8.log`: the process had to
  be killed.) The "thread can be restarted if it dies" claim below only
  helps a *future* call; the in-flight one hangs.
- **`run_threaded` is mutually exclusive with the main-thread modes** in
  practice. PyCall/libpython in this setup only tolerates PyCall calls from
  the thread that ran `PyCall.init`. Mixing the two thread populations
  segfaults the process (exit 139, `pycall.rb:82 in import_module`), in
  either direction:
  - `run`/`run_simple` (which call `PyCall.init` in the calling thread)
    followed by `run_threaded` (worker thread touches PyCall) → segfault
    (probe `probe_mixed_modes.rb` / `probeX_out.txt`).
  - `run_threaded` first (worker thread runs `PyCall.init`) then `run` from
    the main thread → segfault (probe `probe_thread_owner.rb` /
    `probeO_out.txt`).
  - Even a second Ruby thread calling plain `run`/`run` blocks segfaults
    (probe `probe_thread_owner3.rb` / `probeQ_out.txt`), while pure
    `run_threaded` calls from several Ruby threads work fine
    (probe `probe_thread_owner4.rb`).

  The practical rule: pick one population per process — either stay with
  the main-thread modes (`run`, `run_simple`, `run_direct`, `run_log`) and
  leave `run_threaded` unused, or use `run_threaded` exclusively and never
  call `PyCall` from any other thread.

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

The guard is real, but the semantics of a *warm* second call are worth
knowing (probes `probe_direct_first.rb` / `probeT_out.txt`,
`probe_init_guard.rb`):

- `init_scout` is idempotent at the Scout layer: once the class variable is
  set, nothing re-runs — no second `PyCall.init`, no second `at_exit`
  registration, no re-import of the `scout` Python module.
- `PyCall.init` is guarded at its own layer too
  (`return false if LibPython.instance_variable_defined?(:@handle)`), so a
  second call from the same thread is a no-op, not an error.
- `ScoutPython.run_direct` is *not* behind the guard, but the documented
  "`run_direct` before PyCall is initialized will crash" warning is not
  reproducible from a plain `require 'scout/python'`: the `require` itself
  runs `add_paths` → `process_paths` → `pyimport :sys` at load time, which
  triggers `PyCall.init` via `const_missing` as a side effect. A
  `run_direct`-first process therefore initializes Python implicitly and
  works. Treat the warning as a statement about the mode's contract (no
  initialization checking), not an observable failure at HEAD.
- `init_scout` only puts the `scout` Python module on the `ScoutPython`
  module namespace; imports made inside blocks (`json`, `numpy`, ...) do
  not leak into it.

### at_exit hook

The shutdown sequence is critical:

1. **Kill all non-main threads** — Including the ScoutPython background thread.
2. **GC.start** — Finalize Python objects while the GIL is still available.
3. **Touch PyCall.builtins.object** — Verify GIL is still healthy.

If GC happens after the GIL is gone, PyCall object finalizers will segfault.

**Known issue:** The at_exit hook kills ALL non-main threads, not just the
ScoutPython thread. This could interfere with other threading code in the
process. See [Improvements](../Improvements.md).

Empirically (probes `probe_exit_matrix.rb`, `probe_stop_thread.rb`,
`probe_stop2.rb`, `probe_atexit_worker.rb`) the hook does **not** currently
deliver a clean exit for the threaded path, and the "always call
`stop_thread`" advice does not rescue it:

- Leaving the worker thread alive and letting the hook run does not exit:
  the process hangs until killed externally (exit 137 after
  `timeout -s KILL`).
- `stop_thread` itself stalls inside `MUTEX.synchronize`; when its steps are
  driven manually (`QUEUE_IN.push :stop`, `join(2)`), the thread does die,
  but the next PyCall call from the main thread segfaults (exit 139 at
  `pycall.rb:82`). That is the mixed-thread case described under
  `run_threaded`: once the worker owned `PyCall.init`, the main thread may
  not touch PyCall again.
- A `GC.start` before exit, with or without `stop_thread`, changes nothing.

Only the main-thread modes (`run`, `run_simple`, `run_direct`) used alone
exit cleanly. Verified B2 detail: the hook iterates
`Thread.list - [Thread.current]`; at exit time `Thread.current` *is* the
main thread, so "non-main" is accurate — every other thread in the process,
including threads that have nothing to do with ScoutPython, is killed. A
user `at_exit` registered *after* `init_scout` runs *before* scout's hook
(Ruby runs at_exit blocks in reverse registration order), so user shutdown
logic can still complete first.

## Path management

`ScoutPython.paths` is an array of directories to add to Python's `sys.path`.

- `add_path(path)` — Append a path.
- `process_paths` — For each registered path, call `sys.path.append(path)`.

At load time, all Python directories registered via the Scout Path subsystem
are added: `ScoutPython.add_paths(Scout.python.find_all)`.

**Verified (probes `probe_pathdup2.rb` / `probeL_out.txt`):** `process_paths`
is called multiple times (in `init_scout`, `run_simple`, and
`init_thread`) and does not deduplicate. Every main-thread `run` call
appends the Scout directory again — `sys.path` grew 8 → 9 → 10 over three
`run` calls, all duplicates being the Scout python directory. The threaded
path is stable instead: `init_thread` re-runs `process_paths` only when it
(re)creates the thread, and the worker's loop calls `run_simple`-free code,
so `sys.path` stayed at 8 across three `run_threaded` calls. Duplicates are
harmless for imports but worth knowing when you inspect `sys.path`.

Scope (probe `probe_libpython.rb` / `probeJ_out.txt`): paths.rb manages
`sys.path` **only**. It never touches `LD_LIBRARY_PATH`, `PYTHONHOME`,
`PYTHONPATH` or any other loader/library configuration, and it never loads
native libraries — `libpython` and every native extension are `dlopen`ed by
PyCall and the dynamic loader, not by ScoutPython. `ScoutPython.paths` is
seeded at require time from `Scout.python.find_all` (here: the repository's
own `python/` directory) and can be extended with `ScoutPython.add_path`.

After `init_scout`, `sys.path` contains the Scout directory appended after
the standard Python paths. Note also that PyCall itself appends its own
helper directory (`.../pycall/python`) to `sys.path` during `PyCall.init`.

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

Verified (probe `probe_misc.rb`): `binding_run("not-a-binding") { ... }`
runs happily and returns the block's result, confirming the parameter is
completely ignored — any object is accepted and discarded. This is B3 in
[Improvements](../Improvements.md), still true at HEAD.

The building block still works as intended: `ScoutPython.new_binding`
returns a `Binding` instance whose imports **persist across** separate
`instance_exec` calls on that same instance, so callers who want to reuse a
scope can do it manually:

```ruby
b = ScoutPython.new_binding
b.instance_exec { pyimport :math }
b.instance_exec { math.sqrt(16) }   # => 4.0 — math is still there
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

Verified side effect (probe `probe_init_guard.rb`): because these helpers
use `pyimport`/`pyfrom` on the `ScoutPython` module itself, imported names
persist as constants there. `import_method(:math, :sqrt)` leaves `sqrt`
accessible as `ScoutPython.sqrt` afterwards — the "imports leak into the
module namespace" behaviour described for `run` blocks applies to the
helpers too. Use `Binding` scopes (see above) when that matters.

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

Verified (probe `probe_iterate_err.rb`): a short iterator ends cleanly with
`StopIteration` swallowed inside `iterate` (the block sees only the yielded
elements), while any *other* Python exception propagates to Ruby as a
`PyCall::PyError`. So the string match only special-cases the one
end-of-iteration exception.

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

- All access is serialized through MUTEX. `MUTEX` serializes
  *dispatch*, not execution population: `run`/`run_simple` hold it while
  they run PyCall calls on the calling thread, `run_in_thread` holds it
  while pushing to `QUEUE_IN` and waiting on `QUEUE_OUT`. Because PyCall
  effectively belongs to the thread that ran `PyCall.init` (see
  `run_threaded`), the mutex cannot make the two populations
  interchangeable — it only prevents two Ruby threads from dispatching at
  the same instant.
- The thread can be restarted if it dies (`init_thread` checks
  `!self.thread.alive?` and logs "Reloading ScoutPython thread"). Note that
  restarting happens **outside** `MUTEX.synchronize` in `init_thread`, and
  empirically the reload path did not survive testing: after killing the
  worker and issuing a second `run_threaded`, the process segfaulted
  (probes `probe_thread_reload.rb` / `probe7_out.txt`). Treat "the thread
  can be restarted" as the intent of the code, not as verified behaviour —
  a dead worker thread realistically means a dead process.
- `stop_thread` sends `:stop`, joins (2s timeout), or kills, then GCs.
  Empirically `stop_thread` stalls inside `MUTEX.synchronize` when called
  from the main thread after threaded use (see the at_exit section), so it
  is not currently a reliable shutdown primitive.

## Key design decisions

1. **Layered execution modes** — Each mode adds exactly one concern. This
   makes the code easy to reason about and test.

2. **MUTEX for all in-process access** — Ensures thread safety for PyCall
   operations that require the GIL.

3. **Dedicated thread for isolated execution** — `run_threaded` provides a
   clean Python environment that doesn't pollute the main module namespace.

4. **at_exit for safe shutdown** — Critical for avoiding segfaults. GC must
   happen before GIL loss. (Empirically the hook does not yet achieve a
   clean exit for the threaded path; see the at_exit section above.)

5. **Subprocess for complex work** — `script()`, `run_file` and
   `python_task` spawn new `python` processes (via
   `env PYTHONPATH=<ScoutPython.paths> python ...`), avoiding GIL
   contention, thread-population hazards and native-library sharing with
   the Ruby process entirely.

## Probes referenced here

The behaviour claims above were established with throwaway probes under
`tmp/` in the working tree (not committed):
`probe_direct_first.rb`, `probe_init_guard.rb`, `probe_libpython.rb`,
`probe_env_embed.rb`, `probe_concurrency.rb`, `probe_thread_death.rb`,
`probe_thread_owner.rb`, `probe_thread_owner3.rb`,
`probe_thread_owner4.rb`, `probe_thread_reload.rb`,
`probe_mixed_modes.rb`, `probe_stop_thread.rb`, `probe_stop2.rb`,
`probe_exit_matrix.rb`, `probe_atexit_worker.rb`, `probe_misc.rb`,
`probe_iterate_err.rb`. Findings are recorded durably in the Cortex
artifact `scout-rig/subsys/python-bridge.md`.

## See also

- [Architecture](Architecture.md) — Overall module map.
- [Data Conversion Internals](DataConversionInternals.md) — How script() and converters work.
- [Running Python from Ruby](../user/RunningPythonFromRuby.md) — User-facing guide.
