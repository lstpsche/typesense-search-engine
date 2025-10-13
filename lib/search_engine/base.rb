# frozen_string_literal: true

require_relative 'base/display_coercions'
require_relative 'base/hydration'
require_relative 'base/index_maintenance'
require_relative 'base/indexing_dsl'
require_relative 'base/creation'
require_relative 'base/joins'
require_relative 'base/model_dsl'
require_relative 'base/presets'
require_relative 'base/pretty_printer'
require_relative 'base/updating'
require_relative 'base/deletion'
require_relative 'base/relation_delegation'

module SearchEngine
  # Base class for SearchEngine models.
  #
  # Provides lightweight macros to declare the backing Typesense collection and
  # a schema-like list of attributes for future hydration. Attributes declared in
  # a parent class are inherited by subclasses. Redefining an attribute in a
  # subclass overwrites only at the subclass level.
  class Base
    include SearchEngine::Base::Hydration
    include SearchEngine::Base::PrettyPrinter
    include SearchEngine::Base::ModelDsl
    include SearchEngine::Base::RelationDelegation
    include SearchEngine::Base::IndexingDsl
    include SearchEngine::Base::Joins
    include SearchEngine::Base::Presets
    include SearchEngine::Base::IndexMaintenance
    include SearchEngine::Base::Updating
    include SearchEngine::Base::Deletion
    include SearchEngine::Base::Creation
  end
end
