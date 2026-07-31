# ScoutPython Bridge Analysis

> **Non-normative.** Investigation artifact. See `00_scope_and_themes.md` for disclaimer.

## Overview

ScoutPython (`lib/scout/python.rb` + sub-files) is the Ruby-facing API for
interacting with Python via the `pycall` gem. It provides a layered set of
execution modes, import helpers, binding scopes, iteration utilities, and
data conversion.

## Architecture

### Module structure

```
ScoutPython (lib/scout/python.rb)
  extend PyCall::Import          # Gives module-level pyimport/pyfrom/etc.
  ├── class ScoutPythonException
  ├── class Binding
  │     include PyCall::Import   # Per-instance import scope
  ├── init_scout                 # One-time PyCall init + at_exit hook
  ├── import helpers             # import_method, get_module, get_class, etc.
  ├── iteration                  # iterate, iterate_index, collect
  └── binding helpers            # new_binding, binding_run
```

Files:
- `paths.rb` — sys.path management
- `run.rb` — execution modes and threading
- `script.rb` — ruby2python serialization, script(), pickle/JSON loading
- `util.rb` — py2ruby_a, tsv2df, df2tsv, list2ruby, numpy2ruby, obj2hash

### Initialization

`ScoutPython.init_scout` is called by `run()` and `run_threaded()` (via
`init_thread` → `init_scout`). It:

1. Calls `PyCall.init` (once, guarded by `@@__init_scout_python` class variable).
2. Calls `ScoutPython.process_paths` to append registered paths to `sys.path`.
3. Imports the Python `scout` module via `pyimport("scout")`.
4. Sets `@@__init_scout_python = true`.
5. Registers an `at_exit` hook that:
   - Kills all non-main threads.
   - Joins killed threads.
   - Calls `GC.start` while Python is still initialized (so PyCall can
     acquire the GIL and finalize Python objects safely).
   - Touches `PyCall.builtins.object` as a GIL health check.

**Key insight:** The `at_exit` ordering is critical. GC must happen *before*
PyCall loses the GIL. If Python's GIL is not available during GC, PyCall
objects cannot be finalized, leading to segfaults.

## Execution modes

| Method         | Synchronized? | Thread? | Init? | GC after? | Use case                          |
|----------------|---------------|---------|-------|-----------|-----------------------------------|
| `run`          | Yes (via run_simple) | No | Yes | Yes | General-purpose, safe default     |
| `run_simple`   | Yes (MUTEX)   | No      | No    | No        | Already initialized, want sync    |
| `run_direct`   | No            | No      | No    | No        | Fastest, no sync, single eval     |
| `run_threaded` | Yes (via run_in_thread) | Yes | Yes (in thread) | No | Background work, isolation       |
| `run_log`      | Yes (via run) | No | Yes | Yes | Same as run + capture stdout/stderr |
| `run_log_stderr` | Yes (via run) | No | Yes | Yes | Same as run + capture stderr only |

### Threading model

A dedicated background thread (`@thread`) processes a queue of blocks:

```ruby
QUEUE_IN  = Queue.new   # blocks to execute
QUEUE_OUT = Queue.new   # results
```

- `init_thread` lazily creates the thread. Inside the thread, it calls
  `ScoutPython.init_scout` and `process_paths`, then enters a loop popping
  blocks from `QUEUE_IN`.
- `run_in_thread` pushes a block to `QUEUE_IN` and waits on `QUEUE_OUT`,
  all under `MUTEX.synchronize`.
- `stop_thread` pushes `:stop`, joins (timeout 2s) or kills, runs GC, and
  calls `PyCall.finalize` if available.

**Observation:** The thread model serializes all Python access through a
single queue. This is inherently safe for GIL but means concurrent
`run_threaded` calls block each other.

**Warning:** If the thread dies, `init_thread` detects it (`!self.thread.alive?`),
warns "Reloading ScoutPython thread", joins the dead thread, and creates a
new one. However, any pending results in `QUEUE_OUT` from the failed thread
are not drained.

### Binding scopes

`ScoutPython::Binding` includes `PyCall::Import`, giving it its own import
namespace. This is useful for isolating imports:

```ruby
ScoutPython.binding_run do
  pyimport :torch      # torch available here
end
# torch is NOT available outside
```

`binding_run` always creates a *new* binding (the parameter is ignored in
the current implementation — see Improvements).

## Import helpers

| Method | Description |
|--------|-------------|
| `import_method(module_name, method_name, as=nil)` | Import a single method; returns Ruby `Method` |
| `call_method(module_name, method_name, *args)` | Import and call in one step |
| `get_module(module_name)` | Import module, alias with underscores (e.g., `torch.nn` → `torch_nn`) |
| `get_class(module_name, class_name)` | Get a class from a module |
| `class_new_obj(module_name, class_name, args={})` | Instantiate with keyword args |
| `exec(script)` | `PyCall.exec(script)` one-liner |

**Note:** `get_module` uses `pyimport(module_name, as: save_module_name)` and
then `ScoutPython.send(save_module_name)`. This means the module is accessible
as `ScoutPython.torch_nn` after importing `torch.nn`. This could pollute the
ScoutPython namespace with many dynamically-created methods.

## Path management (paths.rb)

- `ScoutPython.paths` — lazy-initialized array.
- `ScoutPython.add_path(path)` — append a path.
- `ScoutPython.add_paths(paths)` — append multiple.
- `ScoutPython.process_paths` — appends all registered paths to `sys.path`
  inside a `run_direct 'sys'` block.
- At load time: `add_paths(Scout.python.find_all)` adds all Python
  directories registered via the Scout Path subsystem.

**Observation:** `process_paths` is called multiple times: once in
`init_scout`, once in `run_simple`, and once in `init_thread`. Since it
appends without deduplication, paths may accumulate duplicates in `sys.path`.

## Iteration utilities

Three methods for traversing Python iterables from Ruby:

1. `iterate(iterator, options={})` — Handles both `__iter__`/`__next__`
   iterators and indexable sequences (falls back to `iterate_index`).
   Detects `StopIteration` via `PyCall::PyError` type string matching.

2. `iterate_index(elem, options={})` — Index-based loop using `PyCall.len`
   and `elem[i]`.

3. `collect(iterator, options={})` — Maps Python iterables to Ruby arrays.

All three support optional progress bars (`bar: true` for default, `bar:
"Description"` for custom). They call `Log::ProgressBar` from scout-essentials.

**StopIteration detection:** Uses string comparison `$!.type.to_s ==
"<class 'StopIteration'>"`. This is fragile but necessary because PyCall
wraps Python exceptions.

## Key findings

1. **The execution mode hierarchy is well-designed** but could use better
   documentation of when to use which mode.

2. **The threading model is sound** but serializes all access. The at_exit
   hook is critical for avoiding segfaults during shutdown.

3. **Binding isolation works** but `binding_run` ignores its `binding`
   parameter — it always creates a new one.

4. **Path deduplication is missing** — `process_paths` can append
   duplicates to `sys.path`.

5. **StopIteration detection via string matching** is fragile but may be
   the only reliable way with PyCall.

6. **The at_exit hook kills ALL non-main threads**, not just the Python
   thread. This could interfere with other threading code in the process.
