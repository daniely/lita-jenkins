require "simplecov"
require "coveralls"
SimpleCov.formatter = SimpleCov::Formatter::MultiFormatter.new([
  SimpleCov::Formatter::HTMLFormatter,
  Coveralls::SimpleCov::Formatter
])
SimpleCov.start { add_filter "/spec/" }

require "lita-jenkins"
require "lita/rspec"

Lita.version_3_compatibility_mode = false
