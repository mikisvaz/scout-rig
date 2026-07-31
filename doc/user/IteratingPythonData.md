# Iterating Python Data

This document explains how to traverse Python iterables from Ruby using
the iteration helpers provided by ScoutPython.

## Audience

This page is intended for:

- ✓ Workflow authors processing Python data structures from Ruby
- ✓ Agent developers iterating over Python collections
- ✗ Framework contributors

## When to use this

Use the iteration helpers when:

- A Python function returns a list, iterator, or generator that you need
  to process in Ruby.
- You want to collect Python data into Ruby arrays.
- You need to iterate over a large Python dataset with a progress bar.

## Core concepts

PyCall wraps Python objects in Ruby proxies. To traverse them, you need
special helpers because Ruby's native `each` doesn't work directly on
PyCall-wrapped iterables.

ScoutPython provides three helpers:

| Helper | Returns | When to use |
|--------|---------|-------------|
| `iterate` | Yields each element | General purpose: lists, iterators, generators |
| `iterate_index` | Yields each element | Indexable sequences (lists, tuples) |
| `collect` | Ruby Array | When you need all elements in an array |

## Typical usage

### iterate

`iterate` handles both `__iter__`/`__next__` style iterators and indexable
sequences. It first tries the iterator protocol, then falls back to
index-based access.

```ruby
ScoutPython.run :numpy, as: :np do
  arr = np.array([10, 20, 30])

  ScoutPython.iterate(arr) do |elem|
    puts elem  # 10, 20, 30
  end
end
```

### iterate with a progress bar

```ruby
ScoutPython.run :numpy, as: :np do
  arr = np.arange(1000)

  ScoutPython.iterate(arr, bar: "Processing array") do |elem|
    # Process each element
  end
end
```

Use `bar: true` for a default progress bar, or `bar: "Description"` for a
custom label. The progress bar uses Scout's `Log::ProgressBar`.

### iterate_index

For indexable sequences (where `len()` and `[]` work), `iterate_index`
uses index-based access:

```ruby
ScoutPython.run do
  pyimport :json
  data = json.loads('[{"name": "Alice"}, {"name": "Bob"}]')

  ScoutPython.iterate_index(data) do |elem|
    puts elem["name"]
  end
end
```

### collect

`collect` gathers all elements into a Ruby array:

```ruby
ScoutPython.run :numpy, as: :np do
  arr = np.array([10, 20, 30])
  result = ScoutPython.collect(arr)
  puts result.inspect  # [10, 20, 30]
end
```

## Common mistakes

### Using `each` on PyCall objects

Ruby's `each` doesn't work on PyCall-wrapped iterables:

```ruby
# Bad — will fail or produce unexpected results
ScoutPython.run do
  pyimport :json
  data = json.loads('[1, 2, 3]')
  data.each { |x| puts x }  # TypeError or no-op
end
```

### Using `iterate` on dictionaries

`iterate` is for sequences and iterators. For dictionaries, use `obj2hash`
or `dict2hash` to convert to a Ruby hash first:

```ruby
# Bad — iterate on a dict doesn't do what you'd expect
ScoutPython.iterate(my_dict) { |k| ... }

# Good
hash = ScoutPython.obj2hash(my_dict)
hash.each { |k, v| ... }
```

## See also

- [Running Python from Ruby](RunningPythonFromRuby.md) — Execution modes.
- [Passing Data to Python](PassingDataToPython.md) — Data conversion helpers.
- [Logging and Progress](https://github.com/mikisvaz/scout-essentials/blob/main/doc/user/LoggingAndProgress.md)
  in scout-essentials — The `Log::ProgressBar` used for iteration progress bars.
