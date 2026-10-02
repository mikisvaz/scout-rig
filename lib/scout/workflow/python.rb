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
    load_tasks
  end

  def load_python_tasks
    python_task_dir.glob_names('*.py').each do |name|
      name = name.sub '.py', ''
      Log.debug "Loading python task #{name}"
      self.python_task name
    end
  end


  def self.load_directory(path = nil, workflow_name = nil)
    workflow = begin
                   m = Module.new
                   m.extend Workflow
                   m.extend PythonWorkflow
                   m.name = workflow_name || "PythonWorkflow"
                   m.tasks = {}
                   m
                 end

    Kernel.const_set workflow_name, workflow

    path = Scout.python.tasks if path.nil?

    workflow.python_task_dir = path
    path.glob_names("*.py").each do |name|
      name = name.sub '.py', ''
      workflow.python_task name
    end

    workflow
  end
end
