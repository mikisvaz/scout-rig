module ScoutPython
  class << self
    attr_accessor :paths
    def paths
      @paths ||= []
    end
  end

  def self.add_path(path)
    self.paths << path
  end

  def self.add_paths(paths)
    self.paths.concat paths
  end

  def self.process_paths
    ScoutPython.run_direct 'sys' do
      ScoutPython.paths.each do |path|
        sys.path.append path
      end
      nil
    end
  end

  add_paths(Scout.python.find_all)
end
