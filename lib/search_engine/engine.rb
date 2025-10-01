module SearchEngine
  # Rails engine for the SearchEngine gem.
  # Configures autoloading and eager-loading paths.
  class Engine < ::Rails::Engine
    engine_name 'search_engine'
    # isolate_namespace SearchEngine # enable later if controllers/routes appear

    # Ensure Zeitwerk loads from lib/
    config.autoload_paths << root.join('lib').to_s

    # Ensure app/search_engine is eager-loadable in production
    config.paths.add 'app/search_engine', eager_load: true

    initializer 'search_engine.configuration' do
      cfg = SearchEngine.config
      # Hydrate only blank/unset fields from ENV to avoid clobbering
      # host app overrides. ENV resolution is centralized in Config.
      cfg.hydrate_from_env!(ENV, override_existing: false)
      cfg.warn_if_incomplete!
    end
  end
end
