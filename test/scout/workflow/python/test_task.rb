require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')
require 'scout/workflow/python'
require 'shellwords'
require 'tmpdir'
require 'fileutils'

class TestPythonWorkflowTask < Test::Unit::TestCase
  def test_load_metadata
    code  =<<-EOF
import scout
from typing import List, Optional

def hello(name: str, excited: bool = False) -> str:
    """
    Greet a user.

    Parameters
    ----------
    name : str
        The name of the person to greet.
    excited : bool, optional
        Whether to add an exclamation mark, by default False.

    Returns
    -------
    str
        A greeting message.
    """
    return f"Hello, {name}{'!' if excited else ''}"

scout.task(hello)
    EOF

    TmpFile.with_file code do |task_file|
      res = PythonWorkflow.read_python_metadata task_file
      assert_equal 'hello', res.first['name']
    end
  end

  def test_load_directory_batch_matches_default_metadata_and_runs_one_process
    with_python_task_directory do |directory, files|
      calls = capture_python_runs do
        @batch_workflow = PythonWorkflow.load_directory(directory, 'BatchMetadataTest', batch: true)
      end
      batch_metadata = workflow_task_metadata(@batch_workflow)
      alpha_value_description = batch_metadata.find { |metadata| metadata['name'] == 'alpha' }
                                           .fetch('inputs').find { |input| input['name'] == 'value' }
                                           .fetch('description')
      assert_equal 'The text to return unchanged.', alpha_value_description

      assert_equal 1, calls.length, 'batch loader should start Python once for all files'
      assert_equal '--scout-metadata-files', Shellwords.split(calls.first.last).first

      calls = capture_python_runs do
        default_workflow = PythonWorkflow.load_directory(directory, 'DefaultMetadataTest')
        assert_equal batch_metadata, workflow_task_metadata(default_workflow)
      end
      assert_equal 1, calls.length, 'default loader should use the available batch metadata collection'
    end
  end

  def test_annotation_mapping_contract
    cases = {
      'str' => 'string',
      'bytes' => 'binary',
      'int' => 'integer',
      'float' => 'float',
      'bool' => 'boolean',
      'pathlib.Path' => 'path',
      'typing.Any' => 'string',
      'typing.Optional[int]' => 'integer',
      'int | None' => 'integer',
      'pathlib.Path | None' => 'path',
      'typing.Optional[pathlib.Path]' => 'path',
      'typing.Annotated[pathlib.Path, "f"]' => 'path',
      'list[str]' => 'list[string]',
      'typing.List[pathlib.Path]' => 'list[path]',
      'typing.Annotated[list[str], "a"]' => 'list[string]',
      'typing.Optional[list[int]]' => 'list[integer]'
    }
    cases.each do |annotation, expected|
      source = "import scout, typing, pathlib\ndef probe(param: #{annotation} = None) -> str:\n    return 'ok'\nscout.task(probe)\n"
      TmpFile.with_file source do |task_file|
        param = PythonWorkflow.read_python_metadata(task_file).first['params'].first
        assert_equal expected, param['type'], "annotation #{annotation}"
      end
    end

    # Optional/union Path annotations must land on :file on the Scout side,
    # with required-ness driven by the Python default.
    ['pathlib.Path | None', 'typing.Optional[pathlib.Path]'].each do |annotation|
      source = "import scout, typing, pathlib\ndef probe(f: #{annotation}) -> str:\n    return 'ok'\nscout.task(probe)\n"
      TmpFile.with_file source do |task_file|
        param = PythonWorkflow.read_python_metadata(task_file).first['params'].first
        assert_equal :file, PythonWorkflow.map_param(param)[:type], "annotation #{annotation}"
        assert_true PythonWorkflow.map_param(param)[:options][:required], "annotation #{annotation} required without default"
      end

      source_with_default = "import scout, typing, pathlib\ndef probe(f: #{annotation} = None) -> str:\n    return 'ok'\nscout.task(probe)\n"
      TmpFile.with_file source_with_default do |task_file|
        param = PythonWorkflow.read_python_metadata(task_file).first['params'].first
        mapped = PythonWorkflow.map_param(param)
        assert_false mapped[:options].key?(:required) && mapped[:options][:required], "annotation #{annotation} not required with None default"
      end
    end
  end

  def test_unsupported_annotations_fail_loudly
    ['dict', 'list', 'typing.List', 'int | str'].each do |annotation|
      source = "import scout, typing\ndef probe(param: #{annotation} = None) -> str:\n    return 'ok'\nscout.task(probe)\n"
      TmpFile.with_file source do |task_file|
        error = assert_raise(ProcessFailed) { PythonWorkflow.read_python_metadata(task_file) }
        assert_match(/Unsupported parameter annotation for 'param'/, error.message)
      end
    end
  end

  def test_input_contract_reports_python_and_scout_sides
    source = "import scout, pathlib\ndef probe(word: str, items: list[pathlib.Path] = None, n: int = 3) -> str:\n    return 'ok'\nscout.task(probe)\n"
    with_runtime_task(source) do |_directory, workflow, file|
      contract = workflow.python_input_contracts['probe']
      assert_equal 'probe', contract['task']
      inputs = contract['inputs']
      word = inputs.find { |i| i['name'] == 'word' }
      assert_equal 'string', word['python_type']
      assert_equal :string, word['scout_type']
      assert_true word['required']
      items = inputs.find { |i| i['name'] == 'items' }
      assert_equal 'list[path]', items['python_type']
      assert_equal :file_array, items['scout_type']
      assert_equal '+', items['flags']['nargs']
      assert_equal 'path', items['flags']['elem_type']
      assert_false items['required']
      assert_equal 3, inputs.find { |i| i['name'] == 'n' }['default']

      assert_equal 'list[path]', workflow.python_input_contract('probe', 'items')['python_type']
      assert_nil workflow.python_input_contract('probe', 'missing')
      assert_nil workflow.python_input_contract('missing', 'items')

      # Behavior column reflects the registered semantics per scout type.
      assert_equal 'text or loaded file contents', word['behavior']
      assert_equal 'list of filenames', items['behavior']
      assert_false word['flags'].key?('noload')

      workflow.python_literal_strings = true
      workflow.python_task :probe, file: file
      literal = workflow.python_input_contracts['probe']['inputs'].find { |i| i['name'] == 'word' }
      assert_equal 'literal text', literal['behavior']
      assert_true literal['flags']['noload']
    end
  end

  def test_build_python_argv_list_and_empty_string_semantics
    params = [
      { 'name' => 'items', 'type' => 'list[string]' },
      { 'name' => 'word', 'type' => 'string' },
      { 'name' => 'other', 'type' => 'string', 'default' => 'dflt' }
    ]
    assert_equal %w[--items a b], PythonWorkflow.build_python_argv(params, { 'items' => %w[a b] })
    assert_equal %w[--items a b], PythonWorkflow.build_python_argv(params, { 'items' => 'a, b' })
    TmpFile.with_file "line1\nline2\n" do |list_file|
      # Contract: a String list value stays path text; filenames are never
      # reinterpreted as contents (the Array form is exercised below).
      assert_equal ['--items', list_file], PythonWorkflow.build_python_argv(params, { 'items' => list_file })
    end
    assert_equal %w[--word --x], PythonWorkflow.build_python_argv(params, { 'word' => '--x' })
    assert_equal ['--word', ''], PythonWorkflow.build_python_argv(params, { 'word' => '' })
    assert_equal ['--other', ''], PythonWorkflow.build_python_argv(params, { 'other' => '' })
    assert_equal [], PythonWorkflow.build_python_argv(params, { 'word' => nil })
    assert_equal %w[--other dflt], PythonWorkflow.build_python_argv(params, { 'other' => 'dflt' })
  end


  def test_literal_strings_flag_keeps_string_inputs_literal
    source = "import scout\ndef probe(word: str = None) -> str:\n    return word\nscout.task(probe)\n"
    with_runtime_task(source) do |directory, workflow, file|
      x_file = File.join(directory, 'x.txt')
      File.write(x_file, 'file-contents')

      # Default (false): Scout's input layer loads a String naming an
      # existing file into its contents before Python runs.
      assert_equal 'file-contents', workflow.job(:probe, 'word' => x_file).run

      # Opt-in: the input is registered with :noload, the literal path
      # string reaches Python. Re-registering replaces the task, so drop the
      # memoized job (Persist.memory key includes the task object's id).
      workflow.python_literal_strings = true
      workflow.python_task :probe, file: file
      Workflow.job_cache.clear
      assert_equal x_file, workflow.job(:probe, 'word' => x_file).run
    end
  end

  def test_path_params_reach_python_as_pathlib_objects
    source = "import pathlib\ndef probe_type(f: pathlib.Path = None) -> str:\n    return type(f).__name__\n"
    with_runtime_task("import scout, pathlib\n#{source}scout.task(probe_type)\n") do |_directory, workflow, _file|
      # pathlib.Path is PosixPath on this platform; the caster must yield the
      # real object, not a string.
      assert_equal 'PosixPath', workflow.job(:probe_type, 'f' => __FILE__).run
    end

    source = "def probe_read(f: pathlib.Path = None) -> str:\n    return f.read_text().strip()\n"
    with_runtime_task("import scout, pathlib\n#{source}scout.task(probe_read)\n") do |directory, workflow, _file|
      path_file = File.join(directory, 'readable.txt')
      File.write(path_file, 'inside-file')
      assert_equal 'inside-file', workflow.job(:probe_read, 'f' => path_file).run
    end
  end

  def test_consumer_reads_producer_output_path
    Dir.mktmpdir('python-chain') do |directory|
      producer = File.join(directory, 'producer.py')
      File.write(producer, <<~PYTHON)
        import pathlib

        def producer() -> pathlib.Path:
            out = pathlib.Path('#{directory}') / 'produced.txt'
            out.write_text('chain-contents')
            return out

        import scout
        scout.task(producer)
      PYTHON
      consumer = File.join(directory, 'consumer.py')
      File.write(consumer, <<~PYTHON)
        import pathlib

        def consumer(p: pathlib.Path) -> str:
            return p.read_text().strip()

        import scout
        scout.task(consumer)
      PYTHON
      workflow = PythonWorkflow.load_directory(Path.setup(directory), "PythonChain#{object_id}_#{rand(1_000_000)}")
      begin
        produced = workflow.job(:producer).run
        assert_equal "#{directory}/produced.txt", File.expand_path(produced)
        assert_equal 'chain-contents', File.read(produced)

        assert_equal 'chain-contents', workflow.job(:consumer, 'p' => produced).run
      ensure
        Object.send(:remove_const, workflow.name.to_sym) if workflow.name && Object.const_defined?(workflow.name.to_sym, false)
      end
    end
  end

  def test_list_params_keep_file_meaning_across_modes
    list_source = "import scout\ndef probe(items: list[str] = None) -> str:\n    return ','.join(items or [])\nscout.task(probe)\n"
    with_runtime_task(list_source) do |directory, workflow, file|
      a = File.join(directory, 'a.txt'); File.write(a, 'A')
      b = File.join(directory, 'b.txt'); File.write(b, 'B')

      # list[str] maps to :array, Scout's :array layer passes each element
      # through unchanged (path text): the bridge serializes an Array
      # literally and never reinterprets a filename as file contents.
      assert_equal "#{a},#{b}", workflow.job(:probe, 'items' => [a, b]).run
      assert_equal 'A,B', workflow.job(:probe, 'items' => ['A', 'B']).run
    end

    path_source = "import scout, pathlib\ndef probe(items: list[pathlib.Path] = None) -> str:\n    return ','.join(type(e).__name__ for e in (items or []))\nscout.task(probe)\n"
    with_runtime_task(path_source) do |directory, workflow, file|
      a = File.join(directory, 'a.txt'); File.write(a, 'A')
      b = File.join(directory, 'b.txt'); File.write(b, 'B')

      # list[Path]: elements are cast to Path objects; passing an Array
      # keeps each element's meaning (a bare filename String would be
      # expanded by Scout's :file_array layer instead).
      assert_equal 'PosixPath,PosixPath', workflow.job(:probe, 'items' => [a, b]).run
    end
  end

  def test_refresh_python_tasks_reconciles_directory_changes
    with_runtime_task("import scout\ndef alpha_task() -> str:\n    return 'alpha'\nscout.task(alpha_task)\n") do |directory, workflow, file|
      assert_equal({ added: [], changed: [], removed: [], unchanged: %w[alpha_task] }, workflow.refresh_python_tasks!)

      File.write(file, "import scout\ndef alpha_task(extra: int = 1) -> str:\n    return 'alpha'\nscout.task(alpha_task)\n")
      assert_equal({ added: [], changed: %w[alpha_task], removed: [], unchanged: [] }, workflow.refresh_python_tasks!)
      assert workflow.python_input_contracts['alpha_task']['inputs'].any? { |i| i['name'] == 'extra' }

      beta = File.join(directory, 'beta_task.py')
      File.write(beta, "import scout\ndef beta_task() -> str:\n    return 'beta'\nscout.task(beta_task)\n")
      assert_equal({ added: %w[beta_task], changed: [], removed: [], unchanged: %w[alpha_task] }, workflow.refresh_python_tasks!)
      assert workflow.tasks.key?(:beta_task)

      File.delete(file)
      assert_equal({ added: [], changed: [], removed: %w[alpha_task], unchanged: %w[beta_task] }, workflow.refresh_python_tasks!)
      assert_false workflow.tasks.key?(:alpha_task)
      assert workflow.tasks.key?(:beta_task)
    end
  end

  def test_refresh_python_tasks_flips_registered_input_type_without_duplicates
    with_runtime_task("import scout\ndef alpha_task(value: str = None) -> str:\n    return str(value)\nscout.task(alpha_task)\n") do |_directory, workflow, file|
      assert_equal :string, workflow.tasks[:alpha_task].inputs.assoc(:value)[1]

      # Param type flip: str -> Path must flip :string -> :file on refresh.
      File.write(file, "import scout, pathlib\ndef alpha_task(value: pathlib.Path = None) -> str:\n    return str(value)\nscout.task(alpha_task)\n")
      summary = workflow.refresh_python_tasks!
      assert_equal %w[alpha_task], summary[:changed]
      assert_equal :file, workflow.tasks[:alpha_task].inputs.assoc(:value)[1]

      before = workflow_task_metadata(workflow)

      # Re-registration must not accumulate inputs or duplicate task names.
      input_names = workflow.tasks[:alpha_task].inputs.map(&:first)
      assert_equal input_names.uniq, input_names
      assert_equal 1, input_names.length
      assert workflow_task_metadata(workflow).map { |m| m['name'] }.tally.values.all? { |n| n == 1 }

      # Idempotency: a second refresh with unchanged sources reports all
      # unchanged and keeps the task object identity stable.
      unchanged_task = workflow.tasks[:alpha_task]
      snapshot = workflow_task_metadata(workflow)
      summary2 = workflow.refresh_python_tasks!
      assert_equal({ added: [], changed: [], removed: [], unchanged: %w[alpha_task] }, summary2)
      assert workflow.tasks[:alpha_task].equal?(unchanged_task)
      assert_equal before, workflow_task_metadata(workflow)
    end
  end

  def test_batch_runs_conditional_main_registration
    with_python_task_directory(conditional_main: true) do |directory, _files|
      batch_calls = capture_python_runs do
        @conditional_batch = PythonWorkflow.load_directory(directory, 'ConditionalBatchTest', batch: true)
      end
      default_calls = capture_python_runs do
        @conditional_default = PythonWorkflow.load_directory(directory, 'ConditionalDefaultTest')
      end
      batch = @conditional_batch
      default = @conditional_default

      assert_equal workflow_task_metadata(default), workflow_task_metadata(batch)
      assert_equal %w[alpha beta], workflow_task_metadata(batch).map { |metadata| metadata['name'] }.sort
      assert_equal 1, batch_calls.length
      assert_equal '--scout-metadata-files', Shellwords.split(batch_calls.first.last).first
      assert_equal 1, default_calls.length
    end
  end

  def test_workflow_extension_then_directory_assignment_loads_tasks_in_batch
    with_python_task_directory do |directory, _files|
      workflow_name = "PythonWorkflowLifecycleTest#{object_id}"
      workflow = Module.new
      Object.const_set(workflow_name, workflow)
      workflow.extend Workflow

      calls = capture_python_runs do
        workflow.extend PythonWorkflow
      end
      assert_equal [], calls, 'extending PythonWorkflow must not preload the default task directory'
      assert_empty workflow.tasks, 'extension should not register default-directory tasks'

      calls = capture_python_runs { workflow.python_task_dir = directory }

      assert_equal 1, calls.length, 'directory assignment should use one batch metadata invocation'
      assert_equal '--scout-metadata-files', Shellwords.split(calls.first.last).first
      metadata = workflow_task_metadata(workflow)
      assert_equal %w[alpha beta], metadata.map { |task| task['name'] }.sort
      alpha = metadata.find { |task| task['name'] == 'alpha' }
      assert_equal 'The text to return unchanged.', alpha.fetch('inputs').find { |input| input['name'] == 'value' }.fetch('description')
    ensure
      Object.send(:remove_const, workflow_name) if workflow_name && Object.const_defined?(workflow_name, false)
    end
  end

  def test_batch_does_not_reexecute_shared_imported_module_between_files
    with_python_task_directory(shared_import: true) do |_directory, files|
      metadata = PythonWorkflow.read_python_metadata_files(files)
      first = metadata.fetch(File.expand_path(files[0])).map { |meta| meta['name'] }
      second = metadata.fetch(File.expand_path(files[1])).map { |meta| meta['name'] }

      assert_equal %w[alpha shared_task], first.sort
      assert_equal ['beta'], second
    end
  end

  def test_register_python_task_metadata_rejects_empty_and_malformed_metadata
    with_runtime_task("import scout\ndef probe() -> str:\n    return 'ok'\nscout.task(probe)\n") do |_directory, workflow, file|
      registered = workflow.tasks[:probe]
      error = assert_raise(RuntimeError) do
        workflow.send(:register_python_task_metadata, file, [])
      end
      assert_match(/No tasks exported by/, error.message)

      error = assert_raise(RuntimeError) do
        workflow.send(:register_python_task_metadata, file, ['not-a-hash'])
      end
      assert_match(/expected a Hash/, error.message)

      error = assert_raise(RuntimeError) do
        workflow.send(:register_python_task_metadata, file, [{ 'params' => [] }])
      end
      assert_match(/missing 'name'/, error.message)

      error = assert_raise(RuntimeError) do
        workflow.send(:register_python_task_metadata, file, [{ 'name' => 'probe' }])
      end
      assert_match(/missing 'params'/, error.message)

      error = assert_raise(RuntimeError) do
        workflow.send(:register_python_task_metadata, file, [{ 'name' => 'probe', 'params' => 'nope' }])
      end
      assert_match(/'params' must be a list/, error.message)

      # No DSL side effects happened for any rejected metadata.
      assert workflow.tasks[:probe].equal?(registered)
    end
  end

  def test_register_python_task_metadata_rejects_duplicate_exported_names
    with_runtime_task("import scout\ndef probe() -> str:\n    return 'ok'\nscout.task(probe)\n") do |_directory, workflow, file|
      duplicated = [
        { 'name' => 'probe', 'params' => [], 'returns' => 'str' },
        { 'name' => 'probe', 'params' => [], 'returns' => 'str' }
      ]
      error = assert_raise(RuntimeError) do
        workflow.send(:register_python_task_metadata, file, duplicated)
      end
      assert_match(/Duplicate exported task name probe/, error.message)

      other_file = File.expand_path('other_exported.py')
      conflict = [{ 'name' => 'probe', 'params' => [], 'returns' => 'str' }]
      workflow.send(:register_python_task_metadata, file, conflict)
      assert workflow.tasks[:probe]

      error = assert_raise(RuntimeError) do
        workflow.send(:register_python_task_metadata, other_file, conflict)
      end
      assert_match(/already registered by/, error.message)

      # Re-registering the same file replaces its entry without error.
      replaced = [{ 'name' => 'probe', 'params' => [{ 'name' => 'word', 'type' => 'str', 'annotation' => 'str', 'required' => true }], 'returns' => 'str' }]
      workflow.send(:register_python_task_metadata, file, replaced)
      assert workflow.tasks[:probe]
      names = workflow.tasks.keys.map(&:to_s)
      assert_equal 1, names.count('probe')
    end
  end
  def test_docstring_extension_is_extracted_and_applies_only_to_its_function
    source = <<~PYTHON
      import scout

      def tailored(value: str) -> str:
          """An individual description.

          Extension: json

          Args:
              value: The parameter help must survive extraction.
          """
          return value

      def sibling() -> str:
          """A sibling description."""
          return 'text'

      scout.task(tailored)
      scout.task(sibling)
    PYTHON

    with_runtime_task(source) do |_directory, workflow, file|
      metadata = PythonWorkflow.read_python_metadata(file).to_h { |meta| [meta['name'], meta] }
      assert_equal 'json', metadata.fetch('tailored').fetch('extension')
      assert_false metadata.fetch('sibling').key?('extension')
      assert_equal 'An individual description.', metadata.fetch('tailored').fetch('description')
      assert_equal 'The parameter help must survive extraction.', metadata.fetch('tailored').fetch('params').first.fetch('help')

      assert_equal 'json', workflow.tasks[:tailored].extension
      assert_not_equal 'json', workflow.tasks[:sibling].extension
      assert_match(/\.json\z/, workflow.job(:tailored, value: 'sample').path.to_s)
    end
  end

  def test_docstring_extension_overrides_file_level_fallback_only_for_that_function
    source = <<~PYTHON
      import scout

      def custom() -> str:
          """Custom result.

          Extension: json
          """
          return 'custom'

      def fallback() -> str:
          """Fallback result."""
          return 'fallback'

      scout.task(custom)
      scout.task(fallback)
    PYTHON

    with_runtime_task(source) do |_directory, _loaded, file|
      workflow = Module.new
      workflow.extend Workflow
      workflow.extend PythonWorkflow
      workflow.python_task :fixture, file: file, extension: 'csv'

      assert_equal 'json', workflow.tasks[:custom].extension
      assert_equal 'csv', workflow.tasks[:fallback].extension
      assert_match(/\.json\z/, workflow.job(:custom).path.to_s)
      assert_match(/\.csv\z/, workflow.job(:fallback).path.to_s)
    end
  end

  def test_docstring_extension_is_available_in_batch_and_per_file_metadata_discovery
    with_extension_task_directory do |directory|
      custom_file = File.join(directory, 'custom.py')
      fallback_file = File.join(directory, 'fallback.py')

      # Exercise the batch metadata collector directly, and verify registration
      # on the normal batch directory-loading route.
      batch_metadata = PythonWorkflow.read_python_metadata_files([custom_file, fallback_file])
      assert_equal 'json', batch_metadata.fetch(File.expand_path(custom_file)).first.fetch('extension')
      assert_false batch_metadata.fetch(File.expand_path(fallback_file)).first.key?('extension')

      workflow_name = "ExtensionDiscovery#{object_id}"
      begin
        workflow = PythonWorkflow.load_directory(Path.setup(directory), workflow_name, batch: true)
        assert_equal 'json', workflow.tasks[:custom].extension
        assert_not_equal 'json', workflow.tasks[:fallback].extension
      ensure
        Object.send(:remove_const, workflow_name) if Object.const_defined?(workflow_name, false)
      end

      # The installed Open API lacks readpath, which the per-file directory
      # loader uses. Exercise per-file runner metadata extraction directly.
      [custom_file, fallback_file].each do |file|
        metadata = PythonWorkflow.read_python_metadata(file).first
        expected_extension = File.basename(file) == 'custom.py' ? 'json' : nil
        assert_equal expected_extension, metadata['extension']
      end
    end
  end

  def test_runtime_task_receives_its_step_files_directory
    source = <<~PYTHON
      import os
      from pathlib import Path
      import scout

      def sidecar_path() -> str:
          directory = Path(os.environ["SCOUT_JOB_FILES_DIR"])
          directory.mkdir(parents=True, exist_ok=True)
          (directory / "auxiliary.txt").write_text("task output", encoding="utf-8")
          return str(directory)

      scout.task(sidecar_path)
    PYTHON

    with_runtime_task(source) do |_directory, workflow, _file|
      step = workflow.job(:sidecar_path)
      returned_directory = step.run
      assert_equal File.expand_path(step.files_dir), File.expand_path(returned_directory)
      assert_equal 'task output', File.read(File.join(step.files_dir, 'auxiliary.txt'))
    end
  end

  def test_docstring_extension_rejects_empty_multi_token_and_duplicate_fields
    ["Extension:", "Extension: json csv", "Extension: json\nExtension: csv"].each do |fields|
      source = <<~PYTHON
        import scout

        def invalid() -> str:
            """Invalid extension.
        #{fields.gsub("\n", "\n            ")}
            """
            return 'x'

        scout.task(invalid)
      PYTHON
      TmpFile.with_file(source) do |file|
        error = assert_raise(ProcessFailed) { PythonWorkflow.read_python_metadata(file) }
        assert_match(/Extension:/, error.message)
      end
    end
  end

  def test_run_file_does_not_inherit_stale_files_directory
    TmpFile.with_file("import os, json
print(json.dumps(os.environ.get('SCOUT_JOB_FILES_DIR')))
") do |file|
      previous = ENV['SCOUT_JOB_FILES_DIR']
      ENV['SCOUT_JOB_FILES_DIR'] = '/stale/parent/sidecar'
      output = ScoutPython.run_file(file, '')
      assert_nil JSON.parse(output.read)
      assert_equal '/stale/parent/sidecar', ENV['SCOUT_JOB_FILES_DIR'], 'run_file must not mutate Ruby ENV'
    ensure
      previous.nil? ? ENV.delete('SCOUT_JOB_FILES_DIR') : ENV['SCOUT_JOB_FILES_DIR'] = previous
    end
  end

  def test_run_file_explicit_environment_overrides_stale_parent_value
    TmpFile.with_file("import os, json
print(json.dumps(os.environ.get('SCOUT_JOB_FILES_DIR')))
") do |file|
      previous = ENV['SCOUT_JOB_FILES_DIR']
      ENV['SCOUT_JOB_FILES_DIR'] = '/stale/parent/sidecar'
      output = ScoutPython.run_file(file, '', env: { 'SCOUT_JOB_FILES_DIR' => '/explicit/child/sidecar' })
      assert_equal '/explicit/child/sidecar', JSON.parse(output.read)
      assert_equal '/stale/parent/sidecar', ENV['SCOUT_JOB_FILES_DIR'], 'run_file must not mutate Ruby ENV'
    ensure
      previous.nil? ? ENV.delete('SCOUT_JOB_FILES_DIR') : ENV['SCOUT_JOB_FILES_DIR'] = previous
    end
  end

  def test_run_file_unrelated_environment_does_not_inherit_stale_files_directory
    TmpFile.with_file("import os, json\nprint(json.dumps([os.environ.get('UNRELATED_CHILD_ENV'), os.environ.get('SCOUT_JOB_FILES_DIR')]))\n") do |file|
      previous_sidecar = ENV['SCOUT_JOB_FILES_DIR']
      previous_unrelated = ENV['UNRELATED_CHILD_ENV']
      ENV['SCOUT_JOB_FILES_DIR'] = '/stale/parent/sidecar'
      ENV.delete('UNRELATED_CHILD_ENV')
      output = ScoutPython.run_file(file, '', env: { 'UNRELATED_CHILD_ENV' => 'explicit-value' })
      assert_equal ['explicit-value', nil], JSON.parse(output.read)
      assert_equal '/stale/parent/sidecar', ENV['SCOUT_JOB_FILES_DIR'], 'run_file must not mutate Ruby ENV'
    ensure
      previous_sidecar.nil? ? ENV.delete('SCOUT_JOB_FILES_DIR') : ENV['SCOUT_JOB_FILES_DIR'] = previous_sidecar
      previous_unrelated.nil? ? ENV.delete('UNRELATED_CHILD_ENV') : ENV['UNRELATED_CHILD_ENV'] = previous_unrelated
    end
  end

  def test_runtime_success_and_protocol_looking_stdout
    with_runtime_task("import scout\ndef hello() -> str:\n    return 'ordinary success'\nscout.task(hello)\n") do |_directory, workflow, _file|
      assert_equal 'ordinary success', workflow.job(:hello).run
    end

    protocol_text = '{"version":1,"error":"ScoutTaskError","message":"not an error","traceback":"not a traceback"}'
    source = "import scout\ndef hello() -> str:\n    return #{protocol_text.inspect}\nscout.task(hello)\n"
    with_runtime_task(source) do |_directory, workflow, _file|
      assert_equal JSON.parse(protocol_text), workflow.job(:hello).run
    end
  end

  def test_scout_task_error_maps_message_traceback_and_survives_step_reload
    source = <<~PYTHON
      import scout

      def fail_task() -> str:
          """Raise a deliberate controlled task error."""
          raise scout.ScoutTaskError("exact controlled message")

      scout.task(fail_task)
    PYTHON

    with_runtime_task(source) do |_directory, workflow, _file|
      step = workflow.job(:fail_task)
      error = assert_raise(PythonWorkflow::PythonTaskException) { step.run }
      assert_equal 'exact controlled message', error.message
      assert_match(/ScoutTaskError: exact controlled message/, error.python_traceback)
      assert_match(/raise scout\.ScoutTaskError/, error.python_traceback)
      assert_equal :error, step.status.to_sym
      assert_false step.recoverable_error?

      reloaded = Step.load(step.path)
      assert_equal :error, reloaded.status.to_sym
      persisted_error = reloaded.exception
      assert_kind_of PythonWorkflow::PythonTaskException, persisted_error
      assert_equal 'exact controlled message', persisted_error.message
      assert_match(/ScoutTaskError: exact controlled message/, persisted_error.python_traceback)
      assert_false reloaded.recoverable_error?
    end
  end

  def test_arbitrary_task_exception_remains_process_failed_with_python_traceback
    source = <<~PYTHON
      import scout

      def fail_task() -> str:
          raise ValueError("unexpected failure")

      scout.task(fail_task)
    PYTHON

    with_runtime_task(source) do |_directory, workflow, _file|
      step = workflow.job(:fail_task)
      error = assert_raise(ProcessFailed) { step.run }
      assert_match(/ValueError: unexpected failure/, error.message)
      assert_match(/Traceback \(most recent call last\)/, error.message)
      assert_match(/raise ValueError/, error.message)
      assert_equal :error, step.status.to_sym
      assert_true step.recoverable_error?
    end
  end

  def test_runtime_import_failure_remains_process_failed_with_traceback
    source = "import scout\ndef hello() -> str:\n    return 'ok'\nscout.task(hello)\n"
    with_runtime_task(source) do |_directory, workflow, file|
      File.write(file, "import module_that_does_not_exist_for_scout_task\n")
      step = workflow.job(:hello)
      error = assert_raise(ProcessFailed) { step.run }
      assert_match(/ModuleNotFoundError/, error.message)
      assert_match(/module_that_does_not_exist_for_scout_task/, error.message)
      assert_equal :error, step.status.to_sym
      assert_true step.recoverable_error?
    end
  end

  def test_missing_or_malformed_protocol_does_not_become_controlled_error
    source = "import scout\ndef hello() -> str:\n    return 'ok'\nscout.task(hello)\n"
    with_runtime_task(source) do |_directory, workflow, _file|
      [nil, '{not json', '{"version":2,"error":"ScoutTaskError","message":"x","traceback":"y"}',
       '{"version":1,"error":"ArbitraryClass","message":"x","traceback":"y"}',
       '{"version":1,"error":"ScoutTaskError","message":4,"traceback":"y"}'].each do |protocol|
        step = workflow.job(:hello, "case-#{protocol.inspect}")
        original = ScoutPython.method(:run_file)
        ScoutPython.define_singleton_method(:run_file) do |_file, args, **_options|
          path = Shellwords.split(args).each_cons(2).find { |key, _value| key == '--scout-error-file' }&.last
          File.write(path, protocol) if path && protocol
          raise ProcessFailed.new(nil, 'synthetic runner failure')
        end
        error = assert_raise(ProcessFailed) { step.run }
        assert_match(/synthetic runner failure/, error.message)
        assert_equal :error, step.status.to_sym
        assert_true step.recoverable_error?
      ensure
        ScoutPython.define_singleton_method(:run_file, original) if original
      end
    end
  end

  def test_process_start_failure_is_not_mapped_to_controlled_error
    source = "import scout\ndef hello() -> str:\n    return 'ok'\nscout.task(hello)\n"
    with_runtime_task(source) do |_directory, workflow, _file|
      step = workflow.job(:hello)
      original = ScoutPython.method(:run_file)
      ScoutPython.define_singleton_method(:run_file) do |_file, _args, **_options|
        raise ProcessFailed.new(nil, 'synthetic executable could not be started')
      end
      error = assert_raise(ProcessFailed) { step.run }
      assert_match(/Failed to run synthetic executable could not be started/, error.message)
      assert_true step.recoverable_error?
    ensure
      ScoutPython.define_singleton_method(:run_file, original) if original
    end
  end

  def test_refresh_python_tasks_applies_literal_strings_flip_without_source_change
    source = "import scout\ndef probe(word: str = None) -> str:\n    return word\nscout.task(probe)\n"
    with_runtime_task(source) do |directory, workflow, file|
      x_file = File.join(directory, 'x.txt')
      File.write(x_file, 'file-contents')

      # Registered with the default (false): the file is loaded.
      assert_equal 'file-contents', workflow.job(:probe, 'word' => x_file).run
      assert_false workflow.tasks[:probe].inputs.assoc(:word)[4].key?(:noload)

      # Flipping the config re-registers on refresh even though the
      # Python metadata (and the source file) are byte-identical.
      workflow.python_literal_strings = true
      summary = workflow.refresh_python_tasks!
      assert_equal %w[probe], summary[:changed], 'config-only change must be visible in the refresh summary'
      assert_true workflow.tasks[:probe].inputs.assoc(:word)[4][:noload], 'noload must be applied to the live registration'

      # Real behaviour follows the new registration, and the earlier job is
      # not replayed after the re-registration.
      Workflow.job_cache.clear
      assert_equal x_file, workflow.job(:probe, 'word' => x_file).run

      # No input duplication from the re-registration.
      input_names = workflow.tasks[:probe].inputs.map(&:first)
      assert_equal input_names.uniq, input_names

      # Idempotency: a second refresh (same sources, same config) is a no-op
      # with stable task identity.
      task_before = workflow.tasks[:probe]
      summary2 = workflow.refresh_python_tasks!
      assert_equal({ added: [], changed: [], removed: [], unchanged: %w[probe] }, summary2)
      assert workflow.tasks[:probe].equal?(task_before)
    end
  end


  def test_load_directory_accepts_literal_strings_before_loading
    source = "import scout\ndef probe(word: str = None) -> str:\n    return word\nscout.task(probe)\n"
    Dir.mktmpdir('python-literal-init') do |directory|
      File.write(File.join(directory, 'runtime_task.py'), source)
      workflow_name = "PythonLiteralInitTest#{object_id}_#{rand(1_000_000)}"
      workflow = PythonWorkflow.load_directory(Path.setup(directory), workflow_name, literal_strings: true)
      begin
        options = workflow.tasks[:probe].inputs.assoc(:word)[4]
        assert_true options[:noload], 'literal_strings: true must apply before task loading'
        contract = workflow.python_input_contracts['probe']
        assert_false contract.key?('stale')
        assert_equal 'literal text', contract['inputs'].first['behavior']
      ensure
        Object.send(:remove_const, workflow_name) if workflow_name && Object.const_defined?(workflow_name, false)
      end
    end
  end


  def test_refresh_rejects_python_task_name_taken_by_native_task
    Dir.mktmpdir('python-native-conflict') do |directory|
      File.write(File.join(directory, 'alpha.py'), "import scout\ndef alpha() -> str:\n    return 'alpha'\nscout.task(alpha)\n")
      File.write(File.join(directory, 'beta.py'), "import scout\ndef beta() -> str:\n    return 'beta'\nscout.task(beta)\n")
      workflow_name = "PythonNativeConflictTest#{object_id}_#{rand(1_000_000)}"
      workflow = PythonWorkflow.load_directory(Path.setup(directory), workflow_name)
      begin
        # Native task takes the beta name AFTER the Python registration.
        workflow.task beta: :string do 'native beta' end

        # alpha.py still refreshes fine on its own: a Python file whose
        # task is not shadowed is unaffected.
        File.write(File.join(directory, 'alpha.py'), "import scout\ndef alpha(extra: int = 1) -> str:\n    return 'alpha'\nscout.task(alpha)\n")
        summary = workflow.refresh_python_tasks!
        assert_equal %w[alpha], summary[:changed]

        # The native name must be rejected explicitly, before any mutation:
        # refreshing the shadowed file raises and leaves beta native.
        File.write(File.join(directory, 'beta.py'), "import scout\ndef beta(n: int = 1) -> str:\n    return str(n)\nscout.task(beta)\n")
        error = assert_raise(RuntimeError) { workflow.refresh_python_tasks! }
        assert_match(/conflicts with a native \(Ruby-defined\) task/, error.message)
        assert_equal 'native beta', workflow.job(:beta).run, 'native task must survive the failed refresh'
        assert_equal 'alpha', workflow.job(:alpha).run

        # Removing the native task makes the same refresh succeed — the
        # rejected conflict was the only blocker. The native run above left a
        # persisted job under the same name; drop both replay layers so the
        # re-registered task actually executes.
        persisted = workflow.job(:beta)
        FileUtils.rm_rf(persisted.path)
        FileUtils.rm_rf("#{persisted.path}.info")
        workflow.tasks.delete(:beta)
        Workflow.job_cache.clear
        summary = workflow.refresh_python_tasks!
        assert_equal %w[beta], summary[:changed]
        assert_equal 1, workflow.job(:beta, 'n' => 1).run
      ensure
        Object.send(:remove_const, workflow_name) if workflow_name && Object.const_defined?(workflow_name, false)
      end
    end
  end

  def test_refresh_failure_leaves_registry_and_tracking_coherent
    Dir.mktmpdir('python-refresh-failure') do |directory|
      File.write(File.join(directory, 'alpha.py'), "import scout\ndef alpha() -> str:\n    return 'alpha'\nscout.task(alpha)\n")
      File.write(File.join(directory, 'beta.py'), "import scout\ndef beta() -> str:\n    return 'beta'\nscout.task(beta)\n")
      workflow_name = "PythonRefreshFailureTest#{object_id}_#{rand(1_000_000)}"
      workflow = PythonWorkflow.load_directory(Path.setup(directory), workflow_name)
      begin
        assert_equal %w[alpha beta], workflow_task_metadata(workflow).map { |m| m['name'] }.sort

        # Introduce a cross-file name collision: gamma redefines alpha. The
        # refresh must fail before mutating anything.
        File.write(File.join(directory, 'gamma.py'), "import scout\ndef alpha(x: int = 1) -> str:\n    return str(x)\nscout.task(alpha)\n")
        assert_raise(RuntimeError) { workflow.refresh_python_tasks! }

        # Previously working registry remains usable.
        assert_equal 'alpha', workflow.job(:alpha).run
        assert_equal 'beta', workflow.job(:beta).run

        # A subsequent refresh without the invalid file behaves coherently:
        # no stale-tracking duplicates or ghosts.
        File.delete(File.join(directory, 'gamma.py'))
        File.write(File.join(directory, 'alpha.py'), "import scout\ndef alpha(extra: int = 1) -> str:\n    return 'alpha'\nscout.task(alpha)\n")
        summary = workflow.refresh_python_tasks!
        assert_equal %w[alpha], summary[:changed]
        assert_equal %w[beta], summary[:unchanged]
        assert_equal %w[alpha beta], workflow.tasks.keys.map(&:to_s).sort
        names = workflow_task_metadata(workflow).map { |m| m['name'] }
        assert_equal names.uniq, names
      ensure
        Object.send(:remove_const, workflow_name) if workflow_name && Object.const_defined?(workflow_name, false)
      end
    end
  end

  def test_body_only_edit_reports_unchanged_and_keeps_cached_result
    source = "import scout\ndef probe() -> str:\n    return 'one'\nscout.task(probe)\n"
    with_runtime_task(source) do |_directory, workflow, file|
      job = workflow.job(:probe, 'case-a')
      assert_equal 'one', job.run

      # Body-only edit: metadata (params/annotations/docstring shape) is
      # unchanged, only the function body differs.
      File.write(file, "import scout\ndef probe() -> str:\n    return 'two'\nscout.task(probe)\n")

      task_before = workflow.tasks[:probe]
      summary = workflow.refresh_python_tasks!
      assert_equal({ added: [], changed: [], removed: [], unchanged: %w[probe] }, summary)
      assert workflow.tasks[:probe].equal?(task_before), 'body-only edit must not redefine the task'

      # Definition refresh and result invalidation are DISTINCT operations
      # and there are two independent replay layers:
      # (i) the in-process Workflow.job_cache keyed on
      #     workflow/task/id/provided-inputs only, and (ii) the on-disk Step
      #     job directory, which run honors when a job is done?. Neither key
      #     includes the Python source body. Both layers replay the OLD
      #     value after a body-only edit.
      assert_equal 'one', workflow.job(:probe, 'case-a').run

      Workflow.job_cache.clear
      assert_equal 'one', workflow.job(:probe, 'case-a').run, 'on-disk job replays the old value without the cache'

      Workflow.job_cache.clear
      step = workflow.job(:probe, 'case-a')
      FileUtils.rm_rf(step.path)
      FileUtils.rm_rf("#{step.path}.info")
      assert_equal 'two', workflow.job(:probe, 'case-a').run, 'removing both replay layers re-executes the edited body'
    end
  end

# A compact view of the registration
  # tracking record, so assertions can check registry AND tracking coherence.
  def python_tracking_snapshot(workflow)
    workflow.instance_variable_get(:@python_task_registrations).to_a.map do |file, registration|
      [File.basename(file), registration['metas'].map { |m| m['name'] }.sort]
    end.sort
  end


  # One .py file exporting several tasks. register_python_task_metadata
  # stores one record per FILE, but refresh re-registers per TASK with a
  # single-element metadata array, so the file's tracking entry is
  # overwritten to hold only the last applied task. The untracked tasks then
  # look like ghost :added entries, trip the native-conflict check against
  # their own names, and disappear from python_input_contracts.
  def test_refresh_multi_task_file_keeps_registry_and_tracking_in_step
    multi = "import scout\ndef build(out: str = None) -> str:\n    return 'build'\nscout.task(build)\ndef edit(src: str = None) -> str:\n    return 'edit'\nscout.task(edit)\ndef inspect(result: str = None) -> str:\n    return 'inspect'\nscout.task(inspect)\n"
    Dir.mktmpdir('python-multi-task') do |directory|
      file = File.join(directory, 'pipeline.py')
      File.write(file, multi)
      workflow_name = "PythonMultiTaskFileTest#{object_id}_#{rand(1_000_000)}"
      workflow = PythonWorkflow.load_directory(Path.setup(directory), workflow_name)
      begin
        assert_equal %w[build edit inspect], workflow.tasks.keys.map(&:to_s).sort
        assert_equal [['pipeline.py', %w[build edit inspect]]], python_tracking_snapshot(workflow)
        assert_equal %w[build edit inspect], workflow.python_input_contracts.keys.sort

        # Change ONE task's signature: refresh must re-register only build
        # and keep edit/inspect tracked by the same file record.
        File.write(file, multi.sub('def build(out: str = None)', 'def build(out: str = None, extra: int = 1)'))
        summary = workflow.refresh_python_tasks!
        assert_equal %w[build], summary[:changed]
        assert_equal %w[edit inspect], summary[:unchanged].sort
        assert_equal %w[build edit inspect], workflow.tasks.keys.map(&:to_s).sort
        assert_equal [['pipeline.py', %w[build edit inspect]]], python_tracking_snapshot(workflow), 'file record must still track every task it exports'
        assert_equal %w[build edit inspect], workflow.python_input_contracts.keys.sort, 'every exported task must stay reportable'

        # Second refresh with unchanged sources is a pure no-op.
        second = workflow.refresh_python_tasks!
        assert_equal({ added: [], changed: [], removed: [], unchanged: %w[build edit inspect] }, second)
        assert_equal %w[build edit inspect], workflow.python_input_contracts.keys.sort

        # Removing ONE exported task prunes registry and tracking together.
        File.write(file, multi.sub('def build(out: str = None)', 'def build(out: str = None, extra: int = 1)').sub("scout.task(edit)\n", ''))
        third = workflow.refresh_python_tasks!
        assert_equal %w[edit], third[:removed]
        assert_equal %w[build inspect], workflow.tasks.keys.map(&:to_s).sort
        assert_equal [['pipeline.py', %w[build inspect]]], python_tracking_snapshot(workflow)
        assert_equal %w[build inspect], workflow.python_input_contracts.keys.sort

        fourth = workflow.refresh_python_tasks!
        assert_equal({ added: [], changed: [], removed: [], unchanged: %w[build inspect] }, fourth)
      ensure
        Object.send(:remove_const, workflow_name) if workflow_name && Object.const_defined?(workflow_name, false)
      end
    end
  end


  # A removed task is never pruned from @python_task_registrations, so
  # every later refresh re-reports it as removed. The second refresh over
  # unchanged sources must be a pure no-op.
  def test_refresh_removed_task_is_not_rereported
    with_runtime_task("import scout\ndef alpha_task() -> str:\n    return 'alpha'\nscout.task(alpha_task)\n") do |_directory, workflow, file|
      File.delete(file)
      assert_equal({ added: [], changed: [], removed: %w[alpha_task], unchanged: [] }, workflow.refresh_python_tasks!)
      assert_false workflow.tasks.key?(:alpha_task)

      # Idempotency: the same sources refreshed again must change nothing.
      assert_equal({ added: [], changed: [], removed: [], unchanged: [] }, workflow.refresh_python_tasks!)
    end
  end


  # eval_str=True stays the resolution mechanism.
  # With `from __future__ import annotations`, str/Path/list[Path]/Path|None/
  # Annotated[Path, ...] resolve exactly like plain annotations, while a
  # quoted forward reference that cannot be evaluated and an unresolvable
  # name are rejected loudly (never a silent :string mapping).
  def test_postponed_annotations_resolve_to_scout_types
    source = "from __future__ import annotations\nimport scout\nfrom pathlib import Path\nfrom typing import Annotated\ndef probe(a: str, b: Path = None, c: list[Path] = None, d: Path | None = None, e: Annotated[Path, 'extra'] = None) -> str:\n    return 'ok'\nscout.task(probe)\n"
    with_runtime_task(source) do |_directory, workflow, _file|
      contract = workflow.python_input_contracts['probe']
      assert_false contract.key?('stale')
      types = contract['inputs'].to_h { |i| [i['name'], i['scout_type']] }
      assert_equal :string, types['a']
      assert_equal :file, types['b']
      assert_equal :file_array, types['c']
      assert_equal :file, types['d']
      assert_equal :file, types['e'], 'Annotated[Path, ...] must map through to :file'
      assert_equal "typing.Annotated[pathlib._local.Path, 'extra']", contract['inputs'].find { |i| i['name'] == 'e' }['python_annotation'], 'the complete Annotated form is preserved in the annotation field'
    end
  end

  # The postponed-annotation surface runs end to end, not just at
  # registration. One task under `from __future__ import annotations` is
  # executed as a real Scout job and its output contract holds.
  def test_postponed_annotations_run_end_to_end
    source = "from __future__ import annotations\nimport scout\nfrom pathlib import Path\nfrom typing import Annotated\ndef probe(word: str, items: list[Path] = None, alt: Path | None = None, tagged: Annotated[Path, 'extra'] = None) -> str:\n    return word + ':' + ','.join(e.name for e in (items or []))\nscout.task(probe)\n"
    with_runtime_task(source) do |directory, workflow, _file|
      contract = workflow.python_input_contracts['probe']
      assert_false contract.key?('stale')
      types = contract['inputs'].to_h { |i| [i['name'], i['scout_type']] }
      assert_equal :string, types['word']
      assert_equal :file_array, types['items']
      assert_equal :file, types['alt']
      assert_equal :file, types['tagged']
      assert_equal "typing.Annotated[pathlib._local.Path, 'extra']", contract['inputs'].find { |i| i['name'] == 'tagged' }['python_annotation']

      a = File.join(directory, 'one.txt'); File.write(a, 'x')
      b = File.join(directory, 'two.txt'); File.write(b, 'y')
      assert_equal "hi:#{File.basename(a)},#{File.basename(b)}", workflow.job(:probe, 'word' => 'hi', 'items' => [a, b]).run
    end
  end

  # Both unresolvable shapes — a quoted forward reference under
  # postponement and a genuinely undefined name — must fail loudly, and the
  # message must name the parameter and the annotation so the two cases are
  # distinguishable from a genuinely unsupported type.
  def test_postponed_unresolvable_annotations_fail_loudly_with_guidance
    # Quoted forward reference under postponement: eval_str cannot resolve
    # it, the annotation stays a string, and our error names the parameter,
    # the annotation, and the reason it stayed a string.
    quoted = "from __future__ import annotations\nimport scout\ndef probe(d: \"Path | None\" = None) -> str:\n    return 'ok'\nscout.task(probe)\n"
    TmpFile.with_file quoted do |task_file|
      error = assert_raise(ProcessFailed) { PythonWorkflow.read_python_metadata(task_file) }
      assert_match(/Unsupported parameter annotation for 'd'/, error.message)
      assert_match(/'Path \| None'/, error.message)
      assert_match(/stayed the string/, error.message)
    end

    # Genuinely undefined name (with or without postponement): the module
    # cannot be imported at all — still loud, never a silent :string.
    undefined = "import scout\ndef probe(f: SomeUndefinedClass = None) -> str:\n    return 'ok'\nscout.task(probe)\n"
    [undefined, undefined.sub('import scout', "from __future__ import annotations\nimport scout")].each do |source|
      TmpFile.with_file source do |task_file|
        error = assert_raise(ProcessFailed) { PythonWorkflow.read_python_metadata(task_file) }
        assert_match(/NameError: name 'SomeUndefinedClass' is not defined/, error.message)
      end
    end
  end

  private

  def with_extension_task_directory
    Dir.mktmpdir('python-workflow-extension-test') do |directory|
      File.write(File.join(directory, 'custom.py'), <<~PYTHON)
        import scout

        def custom() -> str:
            """Custom extension.

            Extension: json
            """
            return 'custom'

        scout.task(custom)
      PYTHON
      File.write(File.join(directory, 'fallback.py'), <<~PYTHON)
        import scout

        def fallback() -> str:
            """No custom extension."""
            return 'fallback'

        scout.task(fallback)
      PYTHON
      yield directory
    end
  end

  def with_runtime_task(source)
    Dir.mktmpdir('python-task-runtime') do |directory|
      file = File.join(directory, 'runtime_task.py')
      File.write(file, source)
      workflow_name = "PythonTaskRuntimeTest#{object_id}_#{rand(1_000_000)}"
      workflow = PythonWorkflow.load_directory(Path.setup(directory), workflow_name)
      yield directory, workflow, file
    ensure
      Object.send(:remove_const, workflow_name) if workflow_name && Object.const_defined?(workflow_name, false)
    end
  end

  def with_python_task_directory(conditional_main: false, shared_import: false)
    Dir.mktmpdir('python-workflow-test') do |dir|
      if shared_import
        File.write(File.join(dir, 'shared.py'), "import scout\ndef shared_task() -> str:\n    return 'shared'\nscout.task(shared_task)\n")
        alpha_registration = "import shared\nscout.task(alpha)"
        beta_registration = "import shared\nscout.task(beta)"
      elsif conditional_main
        alpha_registration = "if __name__ == '__main__':\n    scout.task(alpha)"
        beta_registration = "if __name__ == '__main__':\n    scout.task(beta)"
      else
        alpha_registration = 'scout.task(alpha)'
        beta_registration = 'scout.task(beta)'
      end
      File.write(File.join(dir, 'alpha.py'), <<~PYTHON)
        import scout
        def alpha(value: str, excited: bool = False) -> str:
            """Greet the user.

            Args:
                value: The text to return unchanged.
            """
            return value
        #{alpha_registration}
      PYTHON
      File.write(File.join(dir, 'beta.py'), <<~PYTHON)
        import scout
        def beta(value: int) -> int:
            """Return the numeric value."""
            return value
        #{beta_registration}
      PYTHON
      yield Path.setup(dir), [File.join(dir, 'alpha.py'), File.join(dir, 'beta.py')]
    end
  end

  def capture_python_runs
    original = ScoutPython.method(:run_file)
    calls = []
    ScoutPython.define_singleton_method(:run_file) do |file, args, **options|
      calls << [file, args]
      original.call(file, args, **options)
    end
    yield
    calls
  ensure
    ScoutPython.define_singleton_method(:run_file, original) if original
  end

  def workflow_task_metadata(workflow)
    workflow.tasks.values.map do |task|
      {
        'name' => task.name.to_s,
        'type' => task.type.to_s,
        'description' => task.description,
        'returns' => task.returns,
        'extension' => task.extension,
        'inputs' => task.inputs.map do |name, type, description, default, options|
          {
            'name' => name.to_s,
            'type' => type.to_s,
            'description' => description,
            'default' => default,
            'options' => (options || {}).transform_keys(&:to_s)
          }
        end
      }
    end.sort_by { |metadata| metadata['name'] }
  end
end
