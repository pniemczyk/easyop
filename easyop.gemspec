require_relative "lib/easyop/version"

Gem::Specification.new do |spec|
  spec.name    = "easyop"
  spec.version = Easyop::VERSION
  spec.authors = ['Pawel Niemczyk']
  spec.email = ['pniemczyk.info@.gmail.com']
  spec.summary = "Joyful, composable business logic operations for Ruby"
  spec.license = 'MIT'
  spec.description = <<~DESC
    EasyOp wraps business logic in typed, composable operations.
    It keeps the Interactor mental model (shared ctx, fail!, hooks)
    while adding rescue_from, pluggable type adapters, and chainable
    result callbacks — all without requiring ActiveSupport.
  DESC

  spec.files         = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md"].reject { |f| f.start_with?("tmp/", "examples/") }
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 3.0.0"

  spec.homepage = 'https://github.com/pniemczyk/easyop'
  spec.metadata['homepage_uri']      = spec.homepage
  spec.metadata['source_code_uri']   = spec.homepage
  spec.metadata['documentation_uri'] = 'https://pniemczyk.github.io/easyop/'
  spec.metadata['changelog_uri']     = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.add_development_dependency "rspec",       "~> 3.13"
  spec.add_development_dependency "simplecov",   "~> 0.22"
end
