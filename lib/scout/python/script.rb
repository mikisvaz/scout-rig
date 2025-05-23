module ScoutPython
  def self.ruby2python(object)
    case object
    when Float::INFINITY
      "inf"
    when nil
      "None"
    when ":NA"
      "None"
    when Symbol
      "#{ object }"
    when String
      object = object.dup if Path === object
      object[0] == ":" ? object[1..-1] : "'#{ object }'"
    when Numeric
      object
    when TrueClass
      "True"
    when FalseClass
      "False"
    when Array
      "[#{object.collect{|e| ruby2python(e) } * ", "}]"
    when Hash
      "{" << object.collect{|k,v| [ruby2python(k.to_s), ruby2python(v)] * ":"} * ", " << "}"
    else
      raise "Type of object not known: #{ object.inspect }"
    end
  end

  def self.load_script_variables(variables = {})
    code = "# Variables\nimport scout\n"
    tmp_files = []
    variables.each do |name,value|
      case value
      when TSV
        tmp_file = TmpFile.tmp_file
        tmp_files << tmp_file
        Open.write(tmp_file, value.to_s)
        code << "#{name} = scout.tsv('#{tmp_file}')" << "\n"
      else
        code << "#{name} = #{ScoutPython.ruby2python(value)}" << "\n"
      end
    end

    [code, tmp_files]
  end

  def self.save_script_result_pickle(file)
    <<-EOF

# Save
try: result
except NameError: result = None
if result is not None:
  import pickle
  file = open('#{file}', 'wb')
  # dump information to that file
  pickle.dump(result, file)
    EOF
  end

  def self.load_pickle(file)
    require 'python/pickle'
    Log.debug ("Loading pickle #{file}")
    Python::Pickle.load_file(file)
  end

  def self.save_script_result_json(file)
    <<-EOF

# Save
try: result
except NameError: result = None
if result is not None:
  import json
  file = open('#{file}', 'w', encoding='utf-8')
  # dump information to that file
  file.write(json.dumps(result))
  file.flush
  file.close
    EOF
  end

  def self.load_json(file)
    JSON.load_file(file)
  end

  class << self
    alias save_script_result save_script_result_pickle
    alias load_result load_pickle
  end

  def self.script(text, variables = {})
    if variables.any?
      variable_definitions, tmp_files = load_script_variables(variables)
      text = variable_definitions + "\n# Script\n" + text
    end

    TmpFile.with_file do |tmp_file|
      text += save_script_result(tmp_file)
      Log.debug "Running python script:\n#{text.dup}"
      path_env = ScoutPython.paths * ":"
      CMD.cmd_log("env PYTHONPATH=#{path_env} python", {in: text})
      tmp_files.each{|file| Open.rm_rf file } if tmp_files
      if Open.exists?(tmp_file)
        load_result(tmp_file)
      end
    end
  end
end
