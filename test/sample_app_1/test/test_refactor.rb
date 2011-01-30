require 'rubygems'
require 'test/unit'
require 'rack/test'
require File.expand_path(File.join(File.dirname(__FILE__),'..','loader'))
require 'pp'

class SampleApp::TestRefactor < Test::Unit::TestCase

  def setup
    @ws = SampleApp::WebService.new
  end

  def test_show
    env = Rack::MockRequest.env_for('/foo_bar/144', {
      :method => 'GET'
    })
    output = ''
    assert_nothing_raised do
      output = @ws.call(env)
    end
    test_val = { :foo => 'bar', :baz => 123 }.to_json
    assert_equal test_val, output[2]
  end

end