require 'test/unit'
$LOAD_PATH.unshift(File.expand_path(File.join(File.dirname(__FILE__), '..', 'lib')))
$LOAD_PATH.unshift(File.expand_path(File.dirname(__FILE__)))

require 'scout'
require 'scout/testing'
require 'scout/testing/scout_state'

# Test-only availability probes (scout-rig testing support). Loaded here so
# every test file can gate optional prerequisites with omit; NOT required by
# any production entry point.
require 'scout-rig/testing/availability'

class Test::Unit::TestCase
  include Scout::Testing::Assertions

  def self.tmpdir
    @@tmpdir ||= Path.setup('tmp/test_tmpdir_scout_rig').find
  end

  def tmpdir
    @tmpdir ||= Test::Unit::TestCase.tmpdir
  end

  def capture_instance_variable(owner, name)
    [owner.instance_variable_defined?(name), owner.instance_variable_get(name)]
  end

  def restore_instance_variable(owner, name, state)
    was_defined, value = state
    if was_defined
      owner.instance_variable_set(name, value)
    elsif owner.instance_variable_defined?(name)
      owner.remove_instance_variable(name)
    end
  end

  def capture_rig_test_state
    {
      progress_severity: capture_instance_variable(Log::ProgressBar, :@default_severity),
      entity_property_cache: defined?(Entity) && capture_instance_variable(Entity, :@entity_property_cache),
      workflow_directory: capture_instance_variable(Workflow, :@directory),
      workflows: Workflow.workflows.map do |workflow|
        tasks = workflow.instance_variable_get(:@tasks) || {}
        [workflow, capture_instance_variable(workflow, :@directory),
         tasks.values.map { |task| [task, capture_instance_variable(task, :@directory)] }]
      end,
      job_cache: capture_instance_variable(Workflow, :@job_cache)
    }
  end

  def restore_rig_test_state
    state = @scout_rig_test_state
    return unless state

    restore_instance_variable(Log::ProgressBar, :@default_severity, state[:progress_severity])
    restore_instance_variable(Entity, :@entity_property_cache, state[:entity_property_cache]) if state[:entity_property_cache]
    restore_instance_variable(Workflow, :@directory, state[:workflow_directory])
    state[:workflows].each do |workflow, directory, tasks|
      restore_instance_variable(workflow, :@directory, directory)
      tasks.each { |task, task_directory| restore_instance_variable(task, :@directory, task_directory) }
    end
    restore_instance_variable(Workflow, :@job_cache, state[:job_cache])
  ensure
    @scout_rig_test_state = nil
  end

  setup do
    Open.rm_rf tmpdir
    @scout_rig_test_state = capture_rig_test_state
    @scout_testing_state = Scout::Testing::State.new(tmpdir, bindings: [
      # Keep Rig's intentional shared cache layout while letting State restore
      # the simple accessor-backed paths.
      [Persist, :cache_dir, 'var/cache'],
      [Open, :remote_cache_dir, 'var/cache'],
      [SchedulerJob, :batch_base_dir, 'batch']
    ])
    begin
      @scout_testing_state.activate
      Log::ProgressBar.default_severity = 0

      # These settings have Path-valued or derived semantics; keep their
      # setup/definedness restoration local rather than binding string paths.
      Workflow.directory = tmpdir.var.jobs
      Workflow.workflows.each { |wf| wf.directory = Workflow.directory[wf.name] }
      Entity.entity_property_cache = tmpdir.entity_properties if defined?(Entity)

      # Isolate task memoization without destructively clearing the prior map.
      Workflow.job_cache = {}
    rescue Exception
      begin
        restore_rig_test_state
      ensure
        begin
          @scout_testing_state.restore if @scout_testing_state
        ensure
          @scout_testing_state = nil
          Open.rm_rf tmpdir
        end
      end
      raise
    end
  end

  teardown do
    begin
      restore_rig_test_state
    ensure
      begin
        @scout_testing_state.restore if @scout_testing_state
      ensure
        Open.rm_rf tmpdir
      end
    end
  end

  def self.datadir_test
    Path.setup(File.join(File.dirname(__FILE__), 'data'))
  end

  def self.datafile_test(file)
    datadir_test[file.to_s]
  end

  def datadir_test
    Test::Unit::TestCase.datadir_test
  end

  def datafile_test(file)
    Test::Unit::TestCase.datafile_test(file)
  end
end
