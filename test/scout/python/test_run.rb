require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestClass < Test::Unit::TestCase
  def test_run_threaded


	ScoutPython.run_direct :sys do 
	  paths = sys.path()
	  puts paths
	end
  end
end

