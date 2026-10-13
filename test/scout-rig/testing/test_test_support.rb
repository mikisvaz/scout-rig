require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')

class TestScoutRigTestSupport < Test::Unit::TestCase
  def test_shared_assertion_and_state_bootstrap_are_active
    assert_equal_path File.expand_path('.'), File.expand_path('tmp/..')
    assert_respond_to Scout::Testing, :with_tmpdir
    assert_respond_to Scout::Testing, :with_isolated_state

    root = tmpdir.to_s
    assert_equal_path File.join(root, 'tmpfiles'), TmpFile.tmpdir.to_s
    assert_equal_path File.join(root, 'var', 'cache'), Persist.cache_dir.find.to_s
    assert_equal_path File.join(root, 'persistence-locks'), Persist.lock_dir.to_s
    assert_equal_path File.join(root, 'var', 'cache'), Open.remote_cache_dir.to_s
    assert_equal_path File.join(root, 'sensible-write'), Open.sensible_write_dir.to_s
    assert_equal_path File.join(root, 'sensible-write-locks'), Open.sensible_write_lock_dir.to_s
    assert_equal_path File.join(root, 'var', 'jobs'), Workflow.directory.find.to_s
    assert_equal_path File.join(root, 'entity_properties'), Entity.entity_property_cache.to_s
    assert_equal_path File.join(root, 'batch'), SchedulerJob.batch_base_dir
    assert_equal_path Persist.cache_dir.find.to_s, Open.remote_cache_dir.to_s
    assert_equal 0, Log::ProgressBar.default_severity
  end

  def test_binding_paths_restore_previous_class_accessors
    owners = [[Persist, :cache_dir, 'var/cache'],
              [Open, :remote_cache_dir, 'var/cache'],
              [Entity, :entity_property_cache, 'entity_properties'],
              [SchedulerJob, :batch_base_dir, 'batch']]
    prior = owners.map do |owner, accessor, _path|
      ivar = "@#{accessor}".to_sym
      [owner, accessor, owner.instance_variable_defined?(ivar), owner.instance_variable_get(ivar)]
    end

    state = Scout::Testing::State.new(File.join(tmpdir.to_s, 'extra-bound-state'),
      bindings: owners.map { |owner, accessor, path| [owner, accessor, path] })
    state.activate
    begin
      assert_equal_path File.join(tmpdir.to_s, 'extra-bound-state', 'entity_properties'), Entity.entity_property_cache.to_s
      assert_equal_path File.join(tmpdir.to_s, 'extra-bound-state', 'batch'), SchedulerJob.batch_base_dir
      assert_equal_path File.join(tmpdir.to_s, 'extra-bound-state', 'var', 'cache'), Persist.cache_dir.find.to_s
      assert_equal_path File.join(tmpdir.to_s, 'extra-bound-state', 'var', 'cache'), Open.remote_cache_dir.to_s
      assert File.directory?(Entity.entity_property_cache.to_s)
      assert File.directory?(SchedulerJob.batch_base_dir)
    ensure
      state.restore
    end

    prior.each do |owner, accessor, was_defined, value|
      ivar = "@#{accessor}".to_sym
      assert_equal was_defined, owner.instance_variable_defined?(ivar)
      assert_equal value, owner.instance_variable_get(ivar) if was_defined
    end
  end
end

class TestScoutRigScopedStateRestore < Test::Unit::TestCase
  def test_shared_state_restores_globals_and_memory_cache_even_after_error
    globals_before = state_globals
    Persist::MEMORY_CACHE[:scout_rig_test_support_sentinel] = :preserve
    prior = Persist::MEMORY_CACHE.dup
    root = File.join(tmpdir.to_s, 'nested-isolation')

    assert_raise(RuntimeError) do
      Scout::Testing.with_isolated_state(root) do
        assert_empty Persist::MEMORY_CACHE
        Persist::MEMORY_CACHE[:temporary] = :discard
        assert_equal_path File.join(root, 'tmpfiles'), TmpFile.tmpdir
        raise 'expected test exception'
      end
    end

    assert_equal prior, Persist::MEMORY_CACHE
    assert_equal globals_before, state_globals
  ensure
    Persist::MEMORY_CACHE.delete(:scout_rig_test_support_sentinel)
  end

  private

  def state_globals
    [[TmpFile, :@tmpdir], [Persist, :@cache_dir], [Persist, :@lock_dir],
     [Open, :@remote_cache_dir], [Open, :@sensible_write_dir],
     [Open, :@sensible_write_lock_dir]].to_h do |owner, ivar|
      [[owner.name, ivar], [owner.instance_variable_defined?(ivar), owner.instance_variable_get(ivar)]]
    end
  end
end

class TestScoutRigLocalStateRestore < Test::Unit::TestCase
  def test_scalar_derived_and_cache_state_are_restored_without_clearing_old_cache
    workflow = Module.new
    workflow.extend Workflow
    workflow.define_singleton_method(:name) { 'scout-rig-state-test' }
    task = Class.new { attr_accessor :directory }.new
    task.directory = 'original-task-directory'
    workflow.instance_variable_set(:@tasks, { probe: task })

    workflow_state = [workflow.instance_variable_defined?(:@directory), workflow.instance_variable_get(:@directory)]
    task_state = [task.instance_variable_defined?(:@directory), task.instance_variable_get(:@directory)]
    cache_state = [Workflow.instance_variable_defined?(:@job_cache), Workflow.instance_variable_get(:@job_cache)]
    severity_state = [Log::ProgressBar.instance_variable_defined?(:@default_severity), Log::ProgressBar.instance_variable_get(:@default_severity)]
    entity_cache_state = [Entity.instance_variable_defined?(:@entity_property_cache), Entity.instance_variable_get(:@entity_property_cache)]
    old_cache = { preserved: :entry }

    begin
      Workflow.workflows << workflow
      Workflow.directory = Path.setup(File.join(tmpdir.to_s, 'rig-jobs'))
      Workflow.job_cache = old_cache
      Log::ProgressBar.default_severity = 17
      Entity.entity_property_cache = Path.setup(File.join(tmpdir.to_s, 'rig-entity-cache'))
      @scout_rig_test_state = capture_rig_test_state

      Workflow.directory = tmpdir.var.jobs
      workflow.directory = Workflow.directory[workflow.name]
      Workflow.job_cache = {}
      Log::ProgressBar.default_severity = 0
      Entity.entity_property_cache = tmpdir.entity_properties

      assert_not_same old_cache, Workflow.job_cache
      assert_empty Workflow.job_cache
      assert_equal 0, Log::ProgressBar.default_severity
      assert_equal_path File.join(tmpdir.to_s, 'entity_properties'), Entity.entity_property_cache.to_s
      assert_equal_path File.join(tmpdir.to_s, 'var', 'jobs', workflow.name), workflow.directory.find.to_s
      assert_equal_path File.join(tmpdir.to_s, 'var', 'jobs', workflow.name, 'probe'), task.directory.to_s

      restore_rig_test_state
      assert_same old_cache, Workflow.job_cache
      assert_equal({ preserved: :entry }, Workflow.job_cache)
      assert_equal 17, Log::ProgressBar.default_severity
      assert_equal_path File.join(tmpdir.to_s, 'rig-entity-cache'), Entity.entity_property_cache.to_s
      refute workflow.instance_variable_defined?(:@directory)
      assert_equal 'original-task-directory', task.directory
    ensure
      Workflow.workflows.delete(workflow)
      restore_rig_test_state
      workflow.instance_variable_set(:@directory, workflow_state[1]) if workflow_state[0]
      task.instance_variable_set(:@directory, task_state[1]) if task_state[0]
      restore_test_ivar(Workflow, :@job_cache, cache_state)
      restore_test_ivar(Log::ProgressBar, :@default_severity, severity_state)
      restore_test_ivar(Entity, :@entity_property_cache, entity_cache_state)
    end
  end

  private

  def restore_test_ivar(owner, name, state)
    was_defined, value = state
    if was_defined
      owner.instance_variable_set(name, value)
    elsif owner.instance_variable_defined?(name)
      owner.remove_instance_variable(name)
    end
  end
end

class TestScoutRigTemporaryDirectoryHelpers < Test::Unit::TestCase
  def test_with_tmpdir_yields_string_path_and_removes_it
    path = nil
    Scout::Testing.with_tmpdir(parent: tmpdir.to_s, prefix: 'scout-rig-helper-') do |directory|
      path = directory
      assert_kind_of String, directory
      assert File.directory?(directory)
      assert_match(/\Ascout-rig-helper-/, File.basename(directory))
    end
    refute File.exist?(path)
  end
end
