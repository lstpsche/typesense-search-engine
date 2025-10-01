require_relative 'lib/search_engine/version'

Gem::Specification.new do |spec|
  spec.name        = 'search_engine'
  spec.version     = SearchEngine::VERSION
  spec.authors     = ['SearchEngine Maintainers']
  spec.email       = ['lstpsche@gmail.com']

  spec.summary     = 'Typesense wrapper with AR-like querying'
  spec.description = 'Rails::Engine providing a thin wrapper around Typesense with idiomatic Rails integration.'
  spec.homepage    = 'https://github.com/lstpsche/typesense-search-engine'
  spec.license     = 'MIT'

  spec.required_ruby_version = '>= 3.1'

  spec.metadata['homepage_uri'] = spec.homepage
  # spec.metadata['source_code_uri'] = 'https://example.com/search_engine'
  # spec.metadata['changelog_uri']   = 'https://example.com/search_engine/CHANGELOG'

  spec.files = Dir['{lib,app}/**/*', 'README.md', 'LICENSE.txt', 'docs/**/*']
  spec.require_paths = ['lib']

  spec.add_dependency 'rails', '>= 6.1'
  spec.add_dependency 'typesense', '>= 4.1.0'
end
