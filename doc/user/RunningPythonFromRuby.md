# Running Python from Ruby

This document explains how to execute Python code from Ruby using
scout-rig. It covers the different execution modes, importing Python
modules, and choosing the right approach for your use case.

## Audience

This page is intended for:

- ✓ Workflow authors who need to call Python from Ruby
- ✓ Agent developers building cross-language tools
- ✗ Framework contributors (see [ScoutPython Internals](../developer/ScoutPythonInternals.md))

## When to use this

Use ScoutPython when you need to:

- Call Python libraries (numpy, pandas, PyTorch, etc.) from Ruby code.
- Run a quick Python snippet and get a result back.
- Integrate Python-based computation into a Scout workflow.
- Process data with Python tools that have no Ruby equivalent.

## Core concepts

ScoutPython is a thin layer over the [pycall](https://github.com/mrkn/pycall.rb)
gem. It adds import helpers, execution modes with different isolation levels,
and data conversion utilities. You never interact with PyCall directly.

### Execution modes

Different situations call for different levels of isolation and overhead.
ScoutPython provides a progression of execution modes:

| Mode | Overhead | Isolation | When to use |
|------|----------|-----------|-------------|
| `run` | Medium | Synchronized | General-purpose default |
| `run_simple` | Low | Synchronized | Already initialized, need speed |
| `run_direct` | Lowest | None | Quick one-liners, no synchronization |
| `run_threaded` | High | Dedicated thread | Background work, avoiding GIL contention |
| `run_log` | Medium | Synchronized | When you need to capture Python output |

### Imports

All execution modes accept an optional import directive before the block:

```ruby
# Import a module
ScoutPython.run :numpy do
  numpy.array([1, 2, 3])
end

# Import with an alias
ScoutPython.run :numpy, as: :np do
  np.array([1, 2, 3])
end

# Import a specific name from a module
ScoutPython.run "tensorflow.keras.models", import: :Sequential do
  self::Sequential
end

# No import — use pyimport/pyfrom inside the block
ScoutPython.run do
  pyimport :sys
  sys.version
end
```

## Typical usage

### The default: `run`

```ruby
# Compute a numpy array sum
result = ScoutPython.run :numpy, as: :np do
  a = np.array([1, 2, 3, 4, 5])
  a.sum()
end
puts result  # => 15
```

`run` initializes PyCall if needed, synchronizes access (important for
thread safety), runs your block, and triggers garbage collection afterward.

### Quick one-liners: `run_direct`

```ruby
# Fastest mode — no synchronization, no GC
result = ScoutPython.run_direct :numpy do
  numpy.array([1, 2, 3])
end
```

Use `run_direct` when you're sure no other thread is accessing Python and
you want minimal overhead.

### Background work: `run_threaded`

```ruby
# Execute Python in a dedicated background thread
result = ScoutPython.run_threaded :numpy, as: :np do
  np.array([1, 2, 3])
end

# When done with all threaded work, clean up
ScoutPython.stop_thread
```

Threaded execution runs in a dedicated thread with its own queue. All
threaded calls are serialized through this queue. Call `stop_thread` when
you're done to clean up resources.

### Capturing output: `run_log`

```ruby
# Capture Python stdout/stderr and route to Scout Log
ScoutPython.run_log :sys do
  print("Hello from Python")
end
```

Use `run_log` when you want Python's output routed to Scout's logging
system instead of going to the terminal directly.

## Importing modules

### Inside a block

Inside any execution block, you have access to PyCall's import methods:

```ruby
ScoutPython.run do
  pyimport :json                    # import json
  pyfrom :os.path, import: :join    # from os.path import join
  pyimport :numpy, as: :np          # import numpy as np

  np.array([1, 2, 3])
end
```

### Import helpers

ScoutPython provides convenience methods for common import patterns:

```ruby
# Get a bound Ruby method for a Python function
random = ScoutPython.import_method :random, :randint
random.call(1, 10)

# Call a Python function directly
ScoutPython.call_method :random, :seed, 42

# Import a module object
sys = ScoutPython.get_module :sys

# Get a class
Linear = ScoutPython.get_class "torch.nn", "Linear"

# Instantiate a class with keyword arguments
layer = ScoutPython.class_new_obj "torch.nn", "Linear", in_features: 10, out_features: 5

# Execute a Python expression
ScoutPython.exec "x = 42"
```

### Binding scopes

Imports inside `run` blocks leak into the `ScoutPython` module namespace.
To isolate imports, use a binding scope:

```ruby
ScoutPython.binding_run do
  pyimport :torch
  pyfrom :torch, import: ["nn"]
  # torch is available here
end
# torch is NOT available outside this block
```

Each `binding_run` creates a fresh scope. This is useful when importing
large frameworks (like PyTorch) that you don't want polluting the global
namespace.

## Common mistakes

### Using `run_direct` in a multi-threaded context

`run_direct` skips synchronization. If another thread is accessing Python
at the same time, you may get a GIL-related crash. Use `run` or `run_simple`
in multi-threaded code.

### Forgetting to call `stop_thread`

If you use `run_threaded`, the background thread stays alive. Always call
`ScoutPython.stop_thread` when you're done to avoid resource leaks and
ensure clean shutdown.

### Importing heavy modules inside hot loops

Each `pyimport` call has overhead. Import modules once, outside loops:

```ruby
# Bad — reimports every iteration
100.times do
  ScoutPython.run_direct :numpy do
    numpy.array([1, 2, 3]).sum()
  end
end

# Better — import once
ScoutPython.run :numpy do
  100.times { numpy.array([1, 2, 3]).sum() }
end
```

## See also

- [Passing Data to Python](PassingDataToPython.md) — How to convert Ruby
  data structures to Python.
- [Scripting Python](ScriptingPython.md) — Running full Python scripts with
  variable injection.
- [ScoutPython Internals](../developer/ScoutPythonInternals.md) — How the
  execution modes are implemented.
- [Running Commands](https://github.com/mikisvaz/scout-essentials/blob/main/doc/user/RunningCommands.md)
  in scout-essentials — The CMD module that ScoutPython builds on.
