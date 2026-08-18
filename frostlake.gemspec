# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "frostlake"
  spec.version = File.read(File.expand_path("lib/frostlake.rb", __dir__))[/^\s*VERSION = "([^"]+)"/, 1]
  spec.summary = "Ruby driver for Frostlake over its HTTP protocol"
  spec.description = "Zero-dependency driver for the Frostlake SQL engine, " \
                     "speaking its HTTP protocol against a running DatabaseHttpServer."
  spec.authors = ["MLorek"]
  spec.homepage = "https://frostlake.dev"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.0"
  spec.files = ["lib/frostlake.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.metadata = {
    "homepage_uri" => "https://frostlake.dev",
    "source_code_uri" => "https://github.com/Frostlake-DB/frostlake-ruby",
    "bug_tracker_uri" => "https://github.com/Frostlake-DB/frostlake-ruby/issues",
    "rubygems_mfa_required" => "true"
  }
end
