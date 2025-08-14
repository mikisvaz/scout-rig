require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/python'
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestClass < Test::Unit::TestCase
  def test_run_threaded

	ScoutPython.run_threaded :sys do 
	  paths = sys.path()
	  puts paths
	end
    ScoutPython.stop_thread
  end
end

