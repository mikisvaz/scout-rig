# Cookbook

Practical recipes for common scout-rig use cases. Each recipe is
self-contained and can be adapted to your needs.

## Audience

This page is intended for:

- ✓ Workflow authors looking for ready-to-use patterns
- ✓ Agent developers needing concrete examples
- ✗ Framework contributors

## Ruby → Python recipes

### Run a numpy computation and get the result back

```ruby
result = ScoutPython.run :numpy, as: :np do
  a = np.array([1, 2, 3, 4, 5])
  a.mean()
end
puts result  # => 3.0
```

### Run pandas on a TSV and return a modified TSV

```ruby
tsv = TSV.setup([], "Gene~LogFC,PValue#:type=:list")
tsv["BRCA1"] = [2.5, 0.001]
tsv["TP53"]  = [-1.8, 0.003]
tsv["EGFR"]  = [0.5, 0.45]

df = ScoutPython.tsv2df(tsv)

filtered_df = ScoutPython.run "pandas", as: :pd do
  df = pd.DataFrame.new(tsv.values)
  df["LogFC"].abs() > 1
end

filtered_tsv = ScoutPython.df2tsv(filtered_df)
```

### Pass a TSV to a Python script and get a computed result

```ruby
tsv = TSV.setup([], "Gene~LogFC,PValue#:type=:list")
tsv["BRCA1"] = [2.5, 0.001]

result = ScoutPython.script <<~PY, df: tsv
  result = len(df)
PY
puts result  # => 1
```

### Import a specific class from a module

```ruby
ScoutPython.run do
  Linear = ScoutPython.get_class "torch.nn", "Linear"
  layer = Linear.new(10, 5)
end
```

### Iterate a numpy array with a progress bar

```ruby
ScoutPython.run :numpy, as: :np do
  arr = np.arange(1000)
  ScoutPython.iterate(arr, bar: "Processing") do |val|
    # Process val
  end
end
```

## Python task recipes

### Basic Python task

```python
# python/task/greet.py
import scout

def hello(name: str, excited: bool = False) -> str:
    """
    Greet a person.

    Args:
        name: The name of the person to greet.
        excited: Whether to add an exclamation mark.
    """
    return f"Hello, {name}{'!' if excited else ''}"

scout.task(hello)
```

```ruby
# Workflow
module GreetWF
  extend Workflow
  extend PythonWorkflow
  self.name = 'Greet'

  python_task :hello
end

job = GreetWF.job(:hello, name: "World")
puts job.run
```

### Task accepting a file input

```python
# python/task/count_lines.py
import scout
from pathlib import Path

def count_lines(file: Path) -> int:
    """Count the number of lines in a file.

    Args:
        file: Path to the file to count.
    """
    with open(file) as f:
        return sum(1 for _ in f)

scout.task(count_lines)
```

```ruby
module FileWF
  extend Workflow
  extend PythonWorkflow
  self.name = 'FileTools'

  python_task :count_lines
end

job = FileWF.job(:count_lines, file: "data.txt")
puts job.run
```

### Task accepting a list input

```python
# python/task/join_strings.py
import scout

def join_strings(items: list[str], separator: str = ", ") -> str:
    """
    Join a list of strings.

    Args:
        items: The strings to join.
        separator: The separator to use.
    """
    return separator.join(items)

scout.task(join_strings)
```

```ruby
module JoinWF
  extend Workflow
  extend PythonWorkflow
  self.name = 'Joiner'

  python_task :join_strings
end

job = JoinWF.job(:join_strings, items: ["a", "b", "c"])
puts job.run  # => "a, b, c"
```

### Multi-function Python file

```python
# python/task/math_ops.py
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

  python_task :math_ops  # Creates both :add and :multiply
end

puts MathWF.job(:add, a: 3, b: 4).run       # => 7
puts MathWF.job(:multiply, a: 3.0, b: 4.0).run  # => 12.0
```

### Loading Python tasks from a directory

```ruby
module ToolsWF
  extend Workflow
  extend PythonWorkflow
  self.name = 'Tools'

  # Load all .py files from a directory
  PythonWorkflow.load_directory(self, Path.setup("python/task"))
end
```

## Python → Ruby recipes

### Running a Scout workflow from Python

```python
import scout
import scout.workflow as sw

wf = sw.Workflow('Baking')
print(wf.tasks())

# Synchronous
result = wf.run('bake_muffin_tray', add_blueberries=True)

# Asynchronous
step = wf.fork('bake_muffin_tray', add_blueberries=True)
step.join()
print(step.load())
```

### Reading a Scout TSV from Python

```python
import scout

df = scout.tsv('gene_expression.tsv')
print(df.shape)
print(df.head())
```

### Running a remote Scout workflow from Python

```python
from scout.workflow.remote import RemoteWorkflow

wf = RemoteWorkflow('http://localhost:1900/Baking')
print(wf.tasks())

step = wf.job('bake_muffin_tray', add_blueberries=True)
step.wait()
print(step.json())
```

### Passing a DataFrame as workflow input

```python
import scout
import scout.workflow as sw
import pandas as pd

df = pd.DataFrame({'Gene': ['BRCA1'], 'Score': [1.2]})
df = df.set_index('Gene')

wf = sw.Workflow('Analysis')
result = wf.run('process_genes', data=df)
print(result)
```

## Debugging recipes

### Inspecting Python task metadata

```bash
python python/task/greet.py --scout-metadata
```

Output (formatted):
```json
[{
  "name": "hello",
  "description": "Greet a person.",
  "returns": "string",
  "params": [
    {"name": "name", "type": "string", "required": true, "default": null, "help": "The name of the person to greet."},
    {"name": "exited", "type": "boolean", "scout": false, "default": false, "help": "Whether to add an exclamation mark."}
  ]
}]
```

### Running a Python task from the CLI

```bash
# Single function
python python/task/greet.py --name World --excited

# Multi-function file
python python/task/math_ops.py add --a 3 --b 4
python python/task/math_ops.py multiply --a 3.0 --b 4.0
```

### Verifying Python package import

```bash
PYTHONPATH=python python -c "import scout; print(scout.__file__)"
```

## See also

- [Running Python from Ruby](RunningPythonFromRuby.md) — Execution modes.
- [Passing Data to Python](PassingDataToPython.md) — Data conversion.
- [Scripting Python](ScriptingPython.md) — Script facility.
- [Defining Python Tasks](DefiningPythonTasks.md) — Python task definition.
- [Driving Workflows from Python](DrivingWorkflowsFromPython.md) — Python-side usage.
