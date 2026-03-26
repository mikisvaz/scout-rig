require 'scout/workflow'
require 'json'
require 'open3'

require_relative 'python/inputs'
require_relative 'python/task'

module PythonWorkflow
  attr_accessor :python_task_dir

  def python_task_dir
    @python_task_dir ||= Scout.python.task.find(:lib) 
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

    path = Scout.python.task if path.nil?

    workflow.python_task_dir = path
    path.glob_names("*.py").each do |name|
      name = name.sub '.py', ''
      workflow.python_task name
    end

    workflow
  end
end
