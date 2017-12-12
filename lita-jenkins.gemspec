Gem::Specification.new do |spec|
  spec.name          = "lita-jenkins"
  spec.version       = "0.1.6"
  spec.authors       = ["Antony Ryabov"]
  spec.email         = ["anton.ryabov@onetwotrip.com"]
  spec.description   = %q{Interact with Jenkins CI server.}
  spec.summary       = %q{Interact with Jenkins CI server.}
  spec.homepage      = "https://github.com/onetwotrip/lita-jenkins.git"
  spec.license       = "MIT"
  spec.metadata      = { "lita_plugin_type" => "handler" }

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 2.1"

  spec.add_runtime_dependency "lita", ">= 3.0"
  spec.add_runtime_dependency "jenkins_api_client"
  spec.add_runtime_dependency "http"

  spec.add_development_dependency "bundler", "~> 1.3"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "rspec", ">= 3.0.0.beta2"
  spec.add_development_dependency "simplecov"
  spec.add_development_dependency "coveralls"
end
