# frozen_string_literal: true

require 'test_helper'

class PresetsCompilerTest < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_presets'
    attribute :id, :integer
    attribute :active, :bool
    attribute :updated_at, :integer
  end

  def setup
    @orig_ns = SearchEngine.config.presets.namespace
    @orig_enabled = SearchEngine.config.presets.enabled
    @orig_locked = SearchEngine.config.presets.locked_domains
    SearchEngine.config.presets.enabled = true
    SearchEngine.config.presets.namespace = 'prod'
    SearchEngine.config.presets.locked_domains = %i[filter_by sort_by include_fields exclude_fields]
  end

  def teardown
    SearchEngine.config.presets.namespace = @orig_ns
    SearchEngine.config.presets.enabled = @orig_enabled
    SearchEngine.config.presets.locked_domains = @orig_locked
  end

  def test_merge_mode_injects_preset_and_keeps_all
    rel = Product.all
                 .preset(:popular_products, mode: :merge)
                 .where(active: true)
                 .order(updated_at: :desc)
                 .select(:id)
                 .page(2).per(5)

    params = rel.to_typesense_params

    assert_equal 'prod_popular_products', params[:preset]
    assert_equal '*', params[:q]
    assert_equal 2, params[:page]
    assert_equal 5, params[:per_page]
    assert_includes params.keys, :filter_by
    assert_includes params.keys, :sort_by
    assert_includes params.keys, :include_fields
    refute_includes params.keys, :_preset_conflicts
  end

  def test_only_mode_keeps_essentials
    rel = Product.all
                 .preset(:popular_products, mode: :only)
                 .where(active: true)
                 .order(updated_at: :desc)
                 .select(:id)
                 .page(1).per(10)

    params = rel.to_typesense_params

    assert_equal 'prod_popular_products', params[:preset]
    assert_equal '*', params[:q]
    assert_equal 1, params[:page]
    assert_equal 10, params[:per_page]

    refute_includes params.keys, :filter_by
    refute_includes params.keys, :sort_by
    refute_includes params.keys, :include_fields
    refute_includes params.keys, :exclude_fields
    refute_includes params.keys, :query_by
    refute_includes params.keys, :infix
  end

  def test_lock_mode_prunes_locked_domains_and_records_conflicts
    rel = Product.all
                 .preset(:popular_products, mode: :lock)
                 .where(active: true)
                 .order(updated_at: :desc)
                 .select(:id)

    params = rel.to_typesense_params

    assert_equal 'prod_popular_products', params[:preset]
    refute_includes params.keys, :filter_by
    refute_includes params.keys, :sort_by
    refute_includes params.keys, :include_fields

    conflicts = params[:_preset_conflicts]
    assert_kind_of Array, conflicts
    assert_includes conflicts, :filter_by
    assert_includes conflicts, :sort_by
    assert_includes conflicts, :include_fields

    # Explain should include preset summary and dropped keys
    exp = rel.explain
    assert_includes exp, 'preset: prod_popular_products (mode=lock dropped: filter_by,include_fields,sort_by)'
    # And selection token exists
    assert_includes exp, 'selection:'
  end

  def test_lock_mode_respects_custom_locked_domains
    # Also prune :infix by configuration override
    SearchEngine.config.presets.locked_domains = %i[filter_by sort_by infix]

    rel = Product.all
                 .preset(:popular_products, mode: :lock)
                 .where(active: true)
                 .order(updated_at: :desc)

    params = rel.to_typesense_params

    refute_includes params.keys, :filter_by
    refute_includes params.keys, :sort_by
    refute_includes params.keys, :infix

    conflicts = params[:_preset_conflicts]
    assert_includes conflicts, :infix
  end

  def test_instrumentation_emits_single_conflict_event
    skip 'ActiveSupport::Notifications not available' unless defined?(ActiveSupport::Notifications)

    received = []
    sub = ActiveSupport::Notifications.subscribe('search_engine.preset.conflict') do |*args|
      ev = ActiveSupport::Notifications::Event.new(*args)
      received << ev
    end

    begin
      rel = Product.all
                   .preset(:popular_products, mode: :lock)
                   .where(active: true)
                   .order(updated_at: :desc)
      rel.to_typesense_params
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    assert_equal 1, received.size
    payload = received.first.payload
    assert_equal %i[filter_by sort_by], Array(payload[:keys]).sort
    assert_equal :lock, payload[:mode]
    assert_equal 'prod_popular_products', payload[:preset_name]
    assert_equal 2, payload[:count]
  end
end
