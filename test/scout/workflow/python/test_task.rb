require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')
require 'scout/workflow/python'
require 'shellwords'
require 'tmpdir'

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
        ScoutPython.define_singleton_method(:run_file) do |_file, args|
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
      ScoutPython.define_singleton_method(:run_file) do |_file, _args|
        raise ProcessFailed.new(nil, 'synthetic executable could not be started')
      end
      error = assert_raise(ProcessFailed) { step.run }
      assert_match(/Failed to run synthetic executable could not be started/, error.message)
      assert_true step.recoverable_error?
    ensure
      ScoutPython.define_singleton_method(:run_file, original) if original
    end
  end

  private

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
    ScoutPython.define_singleton_method(:run_file) do |file, args|
      calls << [file, args]
      original.call(file, args)
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
