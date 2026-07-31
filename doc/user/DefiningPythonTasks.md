# Defining Python Tasks

This document explains how to write Scout workflow tasks whose logic is
implemented in Python, using the `python_task` declaration and the
`scout.task` Python decorator.

## Audience

This page is intended for:

- ✓ Workflow authors who want to write task logic in Python
- ✓ Agent developers building Python-backed workflows
- ✗ Framework contributors (see [PythonWorkflow Internals](../developer/PythonWorkflowInternals.md))

## When to use this

Use Python tasks when:

- You have existing Python code that should become part of a Scout workflow.
- Your task logic depends on Python libraries (pandas, scikit-learn, etc.).
- You want to leverage Python's ecosystem while keeping Scout's dependency
  management, persistence, and provenance.
- You're building a workflow that serves both Ruby and Python users.

## Core concepts

A Python task is defined by two parts:

1. **A Python file** that defines one or more functions and registers them
   with `scout.task`.
2. **A Ruby workflow** that calls `python_task` to import the function
   definitions as Scout tasks.

The Python function's type hints and docstring fully determine the Scout
task's inputs and return type. You don't need to declare inputs manually
on the Ruby side.

### The contract

```
Python function signature (types, defaults)  →  Scout task inputs
Python return annotation                     →  Scout task return type
Python docstring                             →  Task description + input help
```

## Typical usage

### Step 1: Write the Python task file

Create a Python file (e.g., `python/task/greet.py`):

```python
import scout

def hello(name: str, excited: bool = False) -> str:
    """
    Greet a person.

    Args:
        name: The name of the person to greet.
        excited: Whether to add an exclamation mark.

    Returns:
        A greeting message.
    """
    return f"Hello, {name}{'!' if excited else ''}"

scout.task(hello)
```

### Step 2: Define the Ruby workflow

```ruby
require 'scout'

module GreetingWorkflow
  extend Workflow
  extend PythonWorkflow

  self.name = 'Greeting'

  python_task :hello
end
```

That's it. The workflow now has a `hello` task with inputs `name` (string,
required) and `excited` (boolean, default false), returning a string.

### Step 3: Run it

```ruby
job = GreetingWorkflow.job(:hello, name: "World")
puts job.run  # => "Hello, World"

job = GreetingWorkflow.job(:hello, name: "World", excited: true)
puts job.run  # => "Hello, World!"
```

Or from the command line:

```bash
scout workflow task Greeting hello --name World
```

## Type mapping

The Python function's type annotations are mapped to Scout types
automatically:

### Input types

| Python type hint   | Scout input type |
|--------------------|------------------|
| `str`              | `:string`        |
| `int`              | `:integer`       |
| `float`            | `:float`         |
| `bool`             | `:boolean`       |
| `bytes`            | `:binary`        |
| `pathlib.Path`     | `:file`          |
| `list[str]`        | `:array`         |
| `list[int]`        | `:array`         |
| `list[float]`      | `:array`         |
| `list[pathlib.Path]` | `:file_array`  |
| `Optional[str]`    | `:string` (not required) |

### Return types

| Python return annotation | Scout return type |
|--------------------------|-------------------|
| `str`                    | `:string`         |
| `int`                    | `:integer`        |
| `float`                  | `:float`          |
| `bool`                   | `:boolean`        |
| `bytes`                  | `:binary`         |
| `list`, `list[str]`      | `:array`          |

## Multi-function files

A single Python file can define multiple functions. All registered functions
become Scout tasks:

```python
import scout

def add(a: int, b: int) -> int:
    """Add two numbers."""
    return a + b

def multiply(a: float, b: float) -> float:
    """Multiply two numbers."""
    return a * b

scout.task(add)
scout.task(multiply)
```

```ruby
module MathWF
  extend Workflow
  extend PythonWorkflow
  self.name = 'Math'

  python_task :math  # Creates both :add and :multiply tasks
end
```

The `python_task :math` call discovers all functions in `math.py` and creates
one Scout task per function.

## Docstring format

Use Google-style docstrings for the best metadata extraction and CLI help:

```python
def search(query: str, max_results: int = 10) -> list[str]:
    """
    Search for items.

    Args:
        query: Natural language search query.
        max_results: Maximum number of results to return.

    Returns:
        A list of matching items.
    """
    ...
```

The metadata extractor reads:
- **Description:** Everything before `Args:`/`Returns:`.
- **Parameter help:** The text after each parameter name in the `Args:` section.
- **Return description:** The text after `Returns:`.

## Running Python tasks standalone

Python task files are also valid CLI tools. You can run them directly:

```bash
# Get metadata
python greet.py --scout-metadata

# Run a function
python greet.py --name World --excited

# For multi-function files, specify the function name
python math.py add --a 3 --b 4
```

## Task file discovery

By default, `python_task` looks for `.py` files via the Scout Path subsystem
at `Scout.python.task.find(:lib)`. You can override this:

```ruby
module MyWF
  extend Workflow
  extend PythonWorkflow

  # Use a custom directory
  self.python_task_dir = Path.setup("python/task")

  python_task :hello
end
```

Or load all Python files from a directory at once:

```ruby
PythonWorkflow.load_directory(MyWF, Path.setup("python/task"))
```

## Common mistakes

### Missing type hints

Type hints are required for proper type mapping. Without them, parameters
default to `:string`:

```python
# Bad — no type hints, everything becomes :string
def add(a, b):
    return a + b

# Good
def add(a: int, b: int) -> int:
    return a + b
```

### Missing `scout.task` registration

The Python file must end with `scout.task(function)` calls. Without
registration, `--scout-metadata` won't produce output:

```python
# Bad — function won't be discovered
def hello(name: str) -> str:
    return f"Hello, {name}"

# Good
def hello(name: str) -> str:
    return f"Hello, {name}"

scout.task(hello)
```

### Forgetting `result` is returned via stdout

The Python function's return value is printed to stdout and decoded by Ruby.
Avoid printing debug output to stdout, as it will interfere with result
decoding:

```python
# Bad — debug print corrupts the return value
def compute(x: int) -> int:
    print("Processing...")  # This goes to stdout!
    return x * 2

# Good — use stderr for debug output
def compute(x: int) -> int:
    import sys
    print("Processing...", file=sys.stderr)
    return x * 2
```

## See also

- [PythonWorkflow Internals](../developer/PythonWorkflowInternals.md) — How
  metadata discovery and type mapping work internally.
- [Driving Workflows from Python](DrivingWorkflowsFromPython.md) — Using the
  Python `scout` package.
- [Cookbook](Cookbook.md) — Recipes combining Python tasks with other features.
