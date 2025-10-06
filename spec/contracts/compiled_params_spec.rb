# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'minitest/autorun'
require 'rails'

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'search_engine'
require 'search_engine/client'
require 'search_engine/test'

# Golden‑Master Contract: Compiled Params Snapshot
#
# This suite freezes the compiled Typesense request params (URL, url_opts, body)
# for a curated set of canonical queries. It never performs network I/O.
#
# Usage (regenerate fixtures):
#   REGENERATE=1 bundle exec rspec spec/contracts/compiled_params_spec.rb
#
# Notes:
# - Uses Minitest to match the repository's test framework. The command above is
#   the intentional regeneration flow; it will rewrite fixtures and print a path
#   to review diffs.
# - Determinism: keys are deeply sorted; internal, non-HTTP keys are stripped;
#   JSON is pretty with 2 spaces and trailing newline.
class CompiledParamsContractSpec < Minitest::Test
  FIXTURES_DIR = File.expand_path('../fixtures/compiled_params', __dir__)

  # Internal keys stripped by the HTTP layer before sending requests
  INTERNAL_KEYS = %i[
    _join _selection _preset_mode _preset_pruned_keys _preset_conflicts
    _curation_conflict_type _curation_conflict_count _runtime_flags _hits
  ].freeze

  def setup
    FileUtils.mkdir_p(FIXTURES_DIR)

    # Reset registry and configure deterministic defaults
    begin
      SearchEngine.send(:__reset_registry_for_tests!)
    rescue StandardError
      # ignore
    end

    SearchEngine.configure do |c|
      # Deterministic connection and defaults
      c.host = 'localhost'
      c.port = 8108
      c.protocol = 'http'
      c.default_query_by = 'name,description'
      c.default_infix = 'fallback'
      c.use_cache = true
      c.cache_ttl_s = 60
      c.strict_fields = true
      c.presets.enabled = true
      c.presets.namespace = 'ns'
      c.presets.locked_domains = %i[filter_by sort_by include_fields exclude_fields]
    end
  end

  # --- Models --------------------------------------------------------------
end

# Define test-only models in a dedicated namespace to avoid collisions
module SearchEngine
  module GM
    class Product < SearchEngine::Base
      collection 'products_gm'
      attribute :id, :integer
      attribute :name, :string
      attribute :description, :string
      attribute :price, :float
      attribute :brand_id, :integer
      attribute :brand_name, :string
      attribute :category, :string
      attribute :active, :boolean
      attribute :updated_at, :datetime

      join :brands, collection: 'brands_gm', local_key: :brand_id, foreign_key: :id
    end

    class Brand < SearchEngine::Base
      collection 'brands_gm'
      attribute :id, :integer
      attribute :name, :string
      attribute :updated_at, :datetime
    end

    class Author < SearchEngine::Base
      collection 'authors_gm'
      attribute :id, :integer
      attribute :first_name, :string
      attribute :last_name, :string
    end

    class Book < SearchEngine::Base
      collection 'books_gm'
      attribute :id, :integer
      attribute :title, :string
      attribute :author_id, :integer

      join :authors, collection: 'authors_gm', local_key: :author_id, foreign_key: :id
    end
  end
end

class CompiledParamsContractSpec
  # --- Canonical cases registry -------------------------------------------

  CASES = [
    { idx: 1,  name: 'base_query', builder: ->(t) { t.p_rel.options(q: 'milk') } },
    { idx: 2,  name: 'filters_bool', builder: lambda { |t|
      t.p_rel.where('price:>10 && (category:="milk" || category:="bread")')
    } },
    { idx: 3, name: 'filters_range', builder: lambda { |t|
      t.p_rel.where(['price >= ?', 10], ['price < ?', 20])
    } },
    { idx: 4,  name: 'order_basic', builder: ->(t) { t.p_rel.order(updated_at: :desc) } },
    { idx: 5,  name: 'pagination_basic', builder: ->(t) { t.p_rel.page(2).per(20) } },
    # Selection & Joins
    { idx: 6,  name: 'select_basic', builder: ->(t) { t.p_rel.select(:id, :name) } },
    { idx: 7,  name: 'include_fields_nested', builder: lambda { |t|
      t.p_rel.joins(:brands).select(:id, brands: %i[name])
    } },
    { idx: 8, name: 'joins_authors', builder: lambda { |t|
      t.b_rel.joins(:authors)
       .where('$authors.last_name:="Rowling"')
       .select(:id, authors: %i[first_name last_name])
    } },
    { idx: 9, name: 'joins_nested', builder: lambda { |t|
      t.b_rel.joins(:authors)
       .where('$authors.last_name:=["Rowling","Tolkien"]')
    } },
    # Grouping
    { idx: 10, name: 'group_by_brand', builder: ->(t) { t.p_rel.group_by(:brand_id) } },
    { idx: 11, name: 'group_by_brand_limit', builder: lambda { |t|
      t.p_rel.group_by(:brand_id, limit: 2)
    } },
    # Presets & Curation
    { idx: 12, name: 'preset_merge', builder: ->(t) { t.p_rel.preset(:popular) } },
    { idx: 13, name: 'preset_lock', builder: lambda { |t|
      t.p_rel.preset(:brand_curated, mode: :lock).order(price: :asc)
    } },
    { idx: 14, name: 'curation_pin_hide', builder: lambda { |t|
      t.p_rel.pin('p_12', 'p_34').hide('p_34')
    } },
    # Faceting
    { idx: 15, name: 'facet_by_brand', builder: lambda { |t|
      t.p_rel.facet_by(:brand_id, max_values: 5)
    } },
    { idx: 16, name: 'facet_query_price', builder: lambda { |t|
      t.p_rel.facet_query(:price, '[0..9]', label: 'under_10')
    } },
    # Highlighting
    { idx: 17, name: 'highlight_basic', builder: lambda { |t|
      t.p_rel.options(
        highlight: {
          fields: %i[name description],
          full_fields: %i[description],
          start_tag: '<em>',
          end_tag: '</em>',
          affix_tokens: 8,
          snippet_threshold: 30
        }
      )
    } },
    # Ranking & Typo
    { idx: 18, name: 'ranking_weights', builder: lambda { |t|
      t.p_rel.options(query_by: 'name,description,brand_name')
       .ranking(query_by_weights: { name: 3, description: 1 })
    } },
    { idx: 19, name: 'prefix_fallback', builder: ->(t) { t.p_rel.prefix(:fallback) } },
    # Synonyms/Stopwords
    { idx: 20, name: 'synonyms_on', builder: ->(t) { t.p_rel.options(use_synonyms: true) } },
    { idx: 21, name: 'stopwords_off', builder: ->(t) { t.p_rel.options(use_stopwords: false) } },
    # Compiler/selection extras (replace unsupported hit-limit chainers)
    { idx: 22, name: 'exclude_fields_basic', builder: lambda { |t|
      t.p_rel.select(:id, :name, :brand_name).exclude(:description)
    } },
    { idx: 23, name: 'pagination_from_limit_offset', builder: lambda { |t|
      t.p_rel.limit(10).offset(20)
    } },
    # DX helpers consistency
    { idx: 24, name: 'to_params_json_pretty', builder: lambda { |t|
      t.p_rel.where(active: true)
       .select(:id, :name)
       .order(updated_at: :desc)
       .page(1)
       .per(5)
    } },
    { idx: 25, name: 'to_curl_masked', builder: lambda { |t|
      t.p_rel.where(active: true).order(updated_at: :desc).per(3)
    } },
    # Multi‑search
    { idx: 26, name: 'multisearch_basic', builder: ->(_t) { [:multi_basic, nil] } },
    { idx: 27, name: 'multisearch_overrides', builder: ->(_t) { [:multi_overrides, nil] } },
    # Edge semantics
    { idx: 28, name: 'empty_filter_nil', builder: ->(t) { t.p_rel.where(category: nil) } },
    { idx: 29, name: 'boolean_filter', builder: ->(t) { t.p_rel.where(active: false) } },
    { idx: 30, name: 'unicode_terms', builder: ->(t) { t.p_rel.options(q: 'café') } }
  ].freeze

  def cases
    @cases ||= CASES.map do |entry|
      Case.new(idx: entry[:idx], name: entry[:name], builder: -> { entry[:builder].call(self) })
    end
  end

  # --- Tests ---------------------------------------------------------------

  def test_compiled_params_snapshots
    updated = []
    cases.each do |entry|
      label = format('%<idx>02d_%<name>s', idx: entry.idx, name: entry.name)
      path = File.join(FIXTURES_DIR, "#{label}.json")

      actual_json = build_snapshot_json(entry)

      if ENV['REGENERATE'] == '1'
        File.write(path, actual_json)
        updated << path
        next
      end

      assert File.exist?(path), "Missing fixture: #{path}. Run with REGENERATE=1 to create."
      expected_json = File.read(path)
      assert_equal expected_json, actual_json, "Snapshot drift for #{label} — run with REGENERATE=1 to update: #{path}"
    end

    return unless ENV['REGENERATE'] == '1'

    puts "\nRegenerated #{updated.size} snapshots under: #{FIXTURES_DIR}"
    puts "Review changes: git diff -- #{FIXTURES_DIR}"
  end

  # --- Builders ------------------------------------------------------------

  def p_rel
    SearchEngine::GM::Product.all
  end

  def b_rel
    SearchEngine::GM::Book.all
  end

  def build_snapshot_json(entry)
    # Multi‑search pseudo-cases
    built = entry.builder.is_a?(Proc) ? entry.builder.call(self) : entry.builder

    if built.is_a?(Array) && built.first == :multi_basic
      url, url_opts, body = compile_multi_basic
    elsif built.is_a?(Array) && built.first == :multi_overrides
      url, url_opts, body = compile_multi_overrides
    else
      rel = built.is_a?(Array) ? p_rel : built
      url, url_opts, body = compile_relation_snapshot(rel)

      # DX helpers consistency cases: normalize body via same sanitizer
      if entry.name == 'to_params_json_pretty'
        # No-op: standard normalization path already pretty-prints
      elsif entry.name == 'to_curl_masked'
        # Compare body portion only, parsed from to_curl; keep same sanitizer & strip internals
        body = parse_tocurl_body(rel)
      end
    end

    normalized = {
      url: url,
      url_opts: deep_sort_object(url_opts),
      body: deep_sort_object(body)
    }

    pretty_json(normalized)
  end

  # Build relation URL, url_opts, and sanitized body (what the client would send)
  def compile_relation_snapshot(rel)
    preview = rel.dry_run!
    body = sanitize_body(SearchEngine::CompiledParams.from(rel.to_typesense_params).to_h)
    [preview[:url], preview[:url_opts] || {}, body]
  end

  # Parse the JSON body fragment from to_curl, sanitize internals in case any leaked, and return Hash
  def parse_tocurl_body(rel)
    curl = rel.to_curl
    # Extract the substring after "-d '" and before the closing "'"
    json = curl.split("-d '", 2).last.to_s
    json = json[0, json.rindex("'")] if json.include?("'")
    parsed = JSON.parse(json || '{}')
    # Keys from to_curl are strings; convert to Symbols to reuse sanitizer
    symbolized = parsed.transform_keys(&:to_sym)
    sanitize_body(symbolized)
  end

  # Build a multi-search payload snapshot (URL, url_opts, body as Array<Hash>)
  def compile_multi_basic
    builder = SearchEngine::Multi.new
    builder.add(:products, p_rel.where(active: true).per(2))
    builder.add(:brands, SearchEngine::GM::Brand.all.per(1))

    payloads = builder.to_payloads(common: { q: '*', query_by: SearchEngine.config.default_query_by })
    url_opts = SearchEngine::ClientOptions.url_options_from_config(SearchEngine.config)
    url = multi_url

    [url, url_opts, payloads]
  end

  def compile_multi_overrides
    builder = SearchEngine::Multi.new
    builder.add(:products, p_rel.where(active: true).per(10))
    builder.add(:brands, SearchEngine::GM::Brand.all) # inherits per from common

    payloads = builder.to_payloads(common: { q: 'milk', per_page: 50, query_by: SearchEngine.config.default_query_by })
    url_opts = SearchEngine::ClientOptions.url_options_from_config(SearchEngine.config)
    url = multi_url

    [url, url_opts, payloads]
  end

  def multi_url
    cfg = SearchEngine.config
    "#{cfg.protocol}://#{cfg.host}:#{cfg.port}/multi_search"
  end

  # --- Normalization utilities --------------------------------------------

  def sanitize_body(params)
    # Use the same logic as Client#sanitize_body_params without performing HTTP
    c = SearchEngine::Client.new
    c.send(:sanitize_body_params, SearchEngine::CompiledParams.from(params).to_h.dup)
  end

  def deep_sort_object(obj)
    case obj
    when Hash
      obj.keys.sort_by(&:to_s).each_with_object({}) do |k, acc|
        acc[k] = deep_sort_object(obj[k])
      end
    when Array
      # Preserve array order by default; only sort arrays of Hashes by their JSON
      # representation when order is under our control (rare in our payloads).
      obj.map { |v| deep_sort_object(v) }
    else
      obj
    end
  end

  def pretty_json(hash)
    "#{JSON.pretty_generate(hash)}\n"
  end
end
