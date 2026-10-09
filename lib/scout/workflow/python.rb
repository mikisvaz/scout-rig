require 'scout/workflow'
require 'json'
require 'open3'

require_relative 'python/inputs'
require_relative 'python/task'

module PythonWorkflow
  attr_accessor :python_task_dir

  def python_task_dir
    @python_task_dir ||= Scout.python.tasks.find
  end

  def python_task_dir=(path)
    @python_task_dir = path
    load_python_tasks(batch: true)
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

  def self.load_directory(path = nil, workflow_name = nil, batch: true)
    workflow = begin
                   m = Module.new
                   m.extend Workflow
                   m.extend PythonWorkflow
                   m.name = workflow_name || "PythonWorkflow"
                   m.tasks = {}
                   m
                 end

    Kernel.const_set(workflow_name || "PythonWorkflow", workflow)

    path = Scout.python.tasks if path.nil?

    # Set directly so load_directory's batch option remains authoritative and
    # directory tasks are registered exactly once.
    workflow.instance_variable_set(:@python_task_dir, path)
    workflow.load_python_tasks(batch: batch)

    workflow
  end
end
