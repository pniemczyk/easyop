require "simplecov"
SimpleCov.start do
  add_filter "/spec/"
  minimum_coverage 80
end

require "easyop"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.before(:each) do
    Easyop.reset_config!
  end
end
