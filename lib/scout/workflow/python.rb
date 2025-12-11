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
end
