require 'scout'
require 'pycall/import'
require_relative 'python/paths'
require_relative 'python/run'
require_relative 'python/script'
require_relative 'python/util'

module ScoutPython
  extend PyCall::Import

  class ScoutPythonException < StandardError; end

  def self.init_scout
    if ! defined?(@@__init_scout_python) || ! @@__init_scout_python
      PyCall.init

      ScoutPython.process_paths
      res = ScoutPython.run_direct do
        Log.debug "Loading python 'scout' module into pycall ScoutPython module"
        pyimport("scout")
      end
      @@__init_scout_python = true

      at_exit do
        (Thread.list - [Thread.current]).each { |t| t.kill }
        (Thread.list - [Thread.current]).each { |t| t.join rescue nil }

        # GC while Python is still initialized so PyCall can safely acquire the GIL
        GC.start

        # (Optional) tiny no-op to ensure GIL path is healthy
        begin
          PyCall.builtins.object
        rescue => _
        end
      end
    end
  end

  def self.import_method(module_name, method_name, as = nil)
    init_scout
    ScoutPython.pyfrom module_name, import: method_name
    ScoutPython.method(method_name)
  end

  def self.call_method(module_name, method_name, *args)
    ScoutPython.import_method(module_name, method_name).call(*args)
  end
  
  def self.get_module(module_name)
    init_scout
    save_module_name = module_name.to_s.gsub(".", "_")
    ScoutPython.pyimport(module_name, as: save_module_name)
    ScoutPython.send(save_module_name)
  end

  def self.get_class(module_name, class_name)
    mod = get_module(module_name)
    mod.send(class_name)
  end

  def self.class_new_obj(module_name, class_name, args={})
    ScoutPython.get_class(module_name, class_name).new(**args)
  end

  def self.exec(script)
    PyCall.exec(script)
  end

  def self.iterate_index(elem, options = {})
    bar = options[:bar]

    len = PyCall.len(elem)
    case bar
    when TrueClass
      bar = Log::ProgressBar.new nil, :desc => "ScoutPython iterate"
    when String
      bar = Log::ProgressBar.new nil, :desc => bar
    end

    len.times do |i|
      begin
        yield elem[i]
        bar.tick if bar
      rescue PyCall::PyError
        if $!.type.to_s == "<class 'StopIteration'>"
          break
        else
          raise $!
        end
      rescue
        bar.error if bar
        raise $!
      end
    end

    Log::ProgressBar.remove_bar bar if bar
    nil
  end

  def self.iterate(iterator, options = {}, &block)
    if ! iterator.respond_to?(:__next__)
      if iterator.respond_to?(:__iter__)
        iterator = iterator.__iter__
      else
        return iterate_index(iterator, options, &block)
      end
    end

    bar = options[:bar]

    case bar
    when TrueClass
      bar = Log::ProgressBar.new nil, :desc => "ScoutPython iterate"
    when String
      bar = Log::ProgressBar.new nil, :desc => bar
    end

    while true
      begin
        elem = iterator.__next__
        yield elem
        bar.tick if bar
      rescue PyCall::PyError
        if $!.type.to_s == "<class 'StopIteration'>"
          break
        else
          raise $!
        end
      rescue
        bar.error if bar
        raise $!
      end
    end

    Log::ProgressBar.remove_bar bar if bar
    nil
  end

  def self.collect(iterator, options = {}, &block)
    acc = []
    self.iterate(iterator, options) do |elem|
      res = block.call elem
      acc << res
    end
    acc
  end

  def self.new_binding
    Binding.new
  end

  def self.binding_run(binding = nil, *args, &block)
    binding = new_binding
    binding.instance_exec *args, &block
  end
end

