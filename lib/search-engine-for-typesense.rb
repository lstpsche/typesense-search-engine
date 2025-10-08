# frozen_string_literal: true

# Compatibility shim for Bundler's `require: true` auto-require using the
# gem name `search-engine-for-typesense`.
#
# This file must not define any constants. It simply requires the proper
# entrypoint so that `SearchEngine` and its engine/config are loaded.
#
# It is intentionally ignored by the engine's Zeitwerk loader to avoid
# attempts to constantize the hyphenated filename.

require 'search_engine'
