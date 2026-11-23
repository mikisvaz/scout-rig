require 'scout/workflow'
require 'json'
require 'open3'

require_relative 'python/inputs'
require_relative 'python/task'

module PythonWorkflow
  attr_accessor :python_task_dir

  def python_task_dir
    @python_task_dir ||= libdir.python.tasks.find
  end

  def python_task_dir=(path)
    @python_task_dir = path
    load_python_tasks(batch: true)
  end

  # When true, `str`-annotated Python parameters register their Scout input
  # with the :noload option, so a String naming an existing file is passed to
  # Python literally instead of being loaded into its contents by Scout's
  # input layer (Task#process_inputs / Task.format_input). Default false
  # preserves the historical load behaviour. Takes effect at task
  # registration time: set it before load_directory (load_directory accepts
  # a literal_strings: keyword), or call refresh_python_tasks! after
  # flipping — a config-only change with identical Python metadata
  # re-registers the affected tasks.
  def python_literal_strings
    return @python_literal_strings if defined?(@python_literal_strings)
    @python_literal_strings = false
  end

  def python_literal_strings=(value)
    @python_literal_strings = value ? true : false
  end

  # Input contract for one Python task, or all of them as a hash, without
  # executing any function. There is ONE view per task, built from the STORED
  # registration metadata (the last registration this workflow applied), not
  # from a fresh extraction of the Python source: it reports what the
  # workflow is registered to do today. Call refresh_python_tasks! (or
  # re-register) to pick up source changes.
  #
  #   { 'task' => ..., 'file' => ..., 'returns' => ...,
  #     'inputs' => [ { 'name', 'python_annotation', 'python_type', 'scout_type',
  #                     'required', 'default', 'help', 'behavior',
  #                     'flags' => { 'python_flag', 'nargs', 'elem_type', 'noload' } } ] }
  #
  # literal_strings semantics come from the registration-time value recorded
  # in the tracking map, so a flag flip without a refresh does not silently
  # change what is reported.
  def python_input_contracts(task_name = nil)
    contracts = {}
    @python_task_registrations.to_a.each do |file, registration|
      registration['metas'].each do |meta|
        next if task_name && meta['name'] != task_name.to_s
        contracts[meta['name']] = {
          'file' => file,
          'task' => meta['name'],
          'returns' => PythonWorkflow.map_returns(meta['returns']),
          'inputs' => meta['params'].to_a.map { |p| PythonWorkflow.input_contract(p, literal_strings: registration['literal_strings']) }
        }
      end
    end
    task_name ? contracts[task_name.to_s] : contracts
  end

  def python_input_contract(task_name, input_name)
    contract = python_input_contracts(task_name)
    contract && contract['inputs'].find { |i| i['name'] == input_name.to_s }
  end

  # Re-read the Python task files and reconcile the registered tasks:
  #
  #   new Python function          -> register it
  #   changed signature/metadata   -> re-register it
  #   deleted Python function      -> remove its registration
  #   unchanged definition         -> left alone (the task object and cached
  #                                   job results survive; a body-only edit
  #                                   keeps the registration and executes the
  #                                   current source on a fresh run)
  #   name collision, incl. with a native (Ruby-defined) task
  #                                -> raise, nothing changed
  #
  # Ordering: collect -> validate the COMPLETE desired state -> apply. One
  # batch metadata subprocess reads every *.py file; every added/changed
  # metadata set is validated (shape, duplicates, cross-file names, native
  # collisions) BEFORE the first mutation, so a failed refresh raises with
  # the registry and tracking map exactly as they were. Returns a summary
  # hash: { :added => [...], :changed => [...], :removed => [...],
  # :unchanged => [...] }. Safe to call repeatedly: with no source changes
  # the result is all-unchanged.
  def refresh_python_tasks!
    names = python_task_dir.glob_names('*.py')
    files = names.map { |name| Open.realpath(python_task_dir[name].find_with_extension('py')) }
    metadata_by_file = files.empty? ? {} : PythonWorkflow.read_python_metadata_files(files)

    previous = @python_task_registrations || {}
    current_config = python_literal_strings

    # Name -> [file, meta, literal_strings] of every registered task.
    previous_by_name = {}
    previous.each do |other_file, registration|
      registration['metas'].each do |meta|
        previous_by_name[meta['name']] = [other_file, meta, registration['literal_strings']]
      end
    end

    # Name -> file across the whole directory: a task that moved between
    # files is one change against the same name, not an add/remove pair, and
    # one name exported by two files is a validation error.
    new_names = {}
    metadata_by_file.each do |file, metas|
      metas.each { |meta| new_names[meta['name']] = file }
    end

    decisions = []
    metadata_by_file.each do |file, metas|
      metas.each do |meta|
        prior = previous_by_name[meta['name']]
        kind =
          if prior.nil?
            :added
          elsif prior[0] != file || prior[1] != meta || prior[2] != current_config
            :changed
          else
            :unchanged
          end
        decisions << [kind, meta['name'], file, meta]
      end
    end

    # Every previously registered task the directory no longer exports
    # anywhere is a removal.
    removed_keys = []
    previous.each do |file, registration|
      registration['metas'].each do |meta|
        next if new_names.key?(meta['name'])
        removed_keys << [file, meta['name']]
      end
    end

    # Validate the COMPLETE desired state before the first mutation.
    pending = {}
    decisions.each do |kind, _name, file, meta|
      next unless %i[added changed].include?(kind)
      (pending[file] ||= []) << meta
    end
    validate_refresh_metadata!(metadata_by_file, pending)

    registrations = {}

    summary = { added: [], changed: [], removed: [], unchanged: [] }

    # Apply. Removals first, so a freed name can be re-homed. Then the
    # tracking map becomes the complete desired state — a plain file ->
    # {metas, literal_strings} map — so per-file validation during apply
    # sees the desired ownership (a task that moved files is owned by its
    # new file). Then ONLY added/changed tasks re-register: unchanged tasks
    # keep their task object and their cached job results.
    removed_keys.each do |_file, name|
      Log.debug "Removing python task #{name}"
      tasks.delete(name.to_sym)
      summary[:removed] << name
    end

    decisions.each { |kind, name, _file, _meta| summary[kind] << name }

    # The tracking map becomes the complete desired state — a plain file ->
    # {metas, literal_strings} map. The task objects of unchanged tasks are
    # not replaced (their cached job results keep replaying), so a changed
    # task is re-registered only AFTER its file's record exists, and a task
    # that moved between files is owned by its new file.
    decisions.group_by { |_kind, _name, file, _meta| file }.each do |file, entries|
      metas = entries.map(&:last)
      registrations[File.expand_path(file)] = { 'literal_strings' => current_config, 'metas' => metas }

      pending = entries.select { |kind, _n, _f, _m| %i[added changed].include?(kind) }.map(&:last)
      self.python_task(file: file, metadata: pending) unless pending.empty?
    end

    @python_task_registrations = registrations
    summary
  end

  # Validate the complete desired registration before any mutation: every
  # file's metadata passes strict registration validation, no name is
  # exported twice across the directory, and no added/changed name collides
  # with a native task. Raises with nothing changed on any failure.
  def validate_refresh_metadata!(metadata_by_file, pending)
    desired = {}
    metadata_by_file.each do |file, metas|
      expanded = File.expand_path(file)
      metas.each do |meta|
        name = meta['name'].to_s
        owner = desired[name]
        raise "Task #{name} exported by both #{owner} and #{expanded}" if owner && owner != expanded
        desired[name] = expanded
      end
    end

    # Shape, within-file duplicates and native collisions; cross-file
    # ownership is decided against the desired map above, so the per-file
    # cross-file check is skipped here.
    pending.each do |file, metas|
      validate_python_task_metadata(file, metas, skip_cross_file: true)
    end
    desired
  end

  def load_python_tasks(batch: true)
    names = python_task_dir.glob_names('*.py')
    metadata = if batch && names.any?
                 files = names.map { |name| Open.realpath(python_task_dir[name].find_with_extension('py')) }
                 PythonWorkflow.read_python_metadata_files(files)
               else
                 {}
               end
    names.each do |name|
      task_name = name.sub '.py', ''
      Log.debug "Loading python task #{task_name}"
      file = Open.realpath(python_task_dir[task_name].find_with_extension('py'))
      if batch
        self.python_task task_name, file: file, metadata: metadata.fetch(file)
      else
        self.python_task task_name
      end
    end
  end

  def self.extended(workflow)
    workflow.load_python_tasks(batch: true) if workflow.respond_to?(:load_python_tasks)
    workflow
  end

  # literal_strings: initializes the flag before any task is loaded, so
  # string inputs register with :noload from the start (the reviewer-preferred
  # initialization option; the plain setter deliberately does not re-register
  # anything). No new configuration surface beyond the existing flag.
  def self.load_directory(path = nil, workflow_name = nil, batch: true, literal_strings: nil)
    workflow = begin
                   m = Module.new
                   m.extend Workflow
                   m.extend PythonWorkflow
                   m.name = workflow_name || "PythonWorkflow"
                   m.tasks = {}
                   m
                 end

    Kernel.const_set(workflow_name || "PythonWorkflow", workflow)

    path = workflow.libdir.python.tasks.find if path.nil?

    workflow.python_literal_strings = literal_strings unless literal_strings.nil?

    # Set directly so load_directory's batch option remains authoritative and
    # directory tasks are registered exactly once.
    workflow.instance_variable_set(:@python_task_dir, path)
    workflow.load_python_tasks(batch: batch)

    workflow
  end
end
