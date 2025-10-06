#!/usr/bin/env ruby
# frozen_string_literal: true

# Micro-benchmark harness for hot paths
# Scenarios (no network):
# - relation_compile: compile Relation -> CompiledParams
# - client_request_build: CompiledParams -> HTTP request object
# - hydration_pluck: pluck over stubbed Result
# - hydration_ids: ids over stubbed Result
#
# Artifacts: JSON written to tmp/bench/*.json with a stable schema.

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'optparse'
require 'json'
require 'fileutils'
require 'benchmark'
require 'time'

begin
  require 'objspace'
rescue LoadError
  # memsize unavailable; continue
end

require 'rails'
require 'search_engine'
require 'search_engine/client/request_builder'
require 'search_engine/test'

module Bench
  module_function

  def run!(out_path:, compare_path: nil, runs: 200, warmup: 50)
    seed_rng!
    warmup_vm!(warmup)

    scenarios = [
      scenario_relation_compile,
      scenario_client_request_build,
      scenario_hydration_pluck,
      scenario_hydration_ids
    ]

    results = {
      timestamp_iso8601: Time.now.utc.iso8601,
      ruby: RUBY_DESCRIPTION,
      scenarios: []
    }

    scenarios.each do |sc|
      results[:scenarios] << measure(sc, runs: runs)
    end

    write_json(out_path, results)

    if compare_path && File.file?(compare_path)
      print_comparison(compare_path, out_path)
    else
      puts "Wrote #{out_path}"
    end
  end

  def seed_rng!
    srand(12345)
  end

  def warmup_vm!(iterations)
    iterations = iterations.to_i
    return if iterations <= 0

    rel = build_relation_for_compile
    compiled = SearchEngine::CompiledParams.from(rel.to_typesense_params)
    iterations.times do
      # minor work across code paths
      SearchEngine::Client::RequestBuilder.send(:sanitize_body_params, compiled.to_h)
    end
  end

  # --- Scenario builders -----------------------------------------------------

  module ::SearchEngine
    class BenchBrand < Base
      collection 'bench_brands'
      attribute :id, :integer
      attribute :name, :string
    end

    class BenchProduct < Base
      collection 'bench_products'
      attribute :id, :integer
      attribute :name, :string
      attribute :price, :float
      attribute :brand_id, :integer

      join :brand, collection: 'bench_brands', local_key: :brand_id, foreign_key: :id
    end
  end

  def configure_defaults!
    SearchEngine.configure do |c|
      c.default_query_by ||= 'name,description'
      c.default_infix ||= 'fallback'
      c.strict_fields = false
    end
  end

  def build_relation_for_compile
    configure_defaults!
    p = SearchEngine::BenchProduct
    p.all
     .joins(:brand)
     .where(active: true, brand_id: [1, 2, 3])
     .where(['price >= ?', 9.99])
     .order('updated_at:desc')
     .include_fields(:id, :name, :price, brand: %i[id name])
     .group_by(:brand_id, limit: 3, missing_values: true)
     .page(2).per(15)
  end

  def build_compiled_params
    rel = build_relation_for_compile
    SearchEngine::CompiledParams.from(rel.to_typesense_params)
  end

  def build_stubbed_result(hits_count: 200)
    docs = Array.new(hits_count) do |i|
      { 'id' => i + 1, 'name' => "P#{i + 1}", 'price' => (1000 + i).fdiv(100), 'brand_id' => (i % 5) + 1 }
    end
    raw = {
      'found' => hits_count,
      'out_of' => hits_count,
      'hits' => docs.map { |doc| { 'document' => doc } }
    }
    SearchEngine::Result.new(raw, klass: SearchEngine::BenchProduct)
  end

  # --- Scenarios -------------------------------------------------------------

  def scenario_relation_compile
    name = 'relation_compile'
    rel = build_relation_for_compile
    runner = proc { SearchEngine::CompiledParams.from(rel.to_typesense_params) }
    [name, runner]
  end

  def scenario_client_request_build
    name = 'client_request_build'
    compiled = build_compiled_params
    runner = proc do
      SearchEngine::Client::RequestBuilder.build_search(
        collection: 'bench_products',
        compiled_params: compiled,
        url_opts: { use_cache: true, cache_ttl: 30 }
      )
    end
    [name, runner]
  end

  def scenario_hydration_pluck
    name = 'hydration_pluck'
    result = build_stubbed_result(hits_count: 200)
    runner = proc do
      rel = SearchEngine::BenchProduct.all.reselect(:id, :name, :price)
      rel.instance_variable_set(:@__result_memo, result)
      rel.instance_variable_set(:@__loaded, true)
      SearchEngine::Hydration::Materializers.pluck(rel, :name)
    end
    [name, runner]
  end

  def scenario_hydration_ids
    name = 'hydration_ids'
    result = build_stubbed_result(hits_count: 200)
    runner = proc do
      rel = SearchEngine::BenchProduct.all
      rel.instance_variable_set(:@__result_memo, result)
      rel.instance_variable_set(:@__loaded, true)
      SearchEngine::Hydration::Materializers.ids(rel)
    end
    [name, runner]
  end

  # --- Measurement -----------------------------------------------------------

  def measure(pair, runs:)
    name, runner = pair

    # GC + ObjectSpace snapshots
    before_gc = safe_gc_stat
    before_objs = safe_count_objects
    before_mem = safe_memsize

    times = []
    runs.times do
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
      runner.call
      t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
      times << (t1 - t0)
    end

    after_gc = safe_gc_stat
    after_objs = safe_count_objects
    after_mem = safe_memsize

    total_ms = times.inject(0.0, &:+)
    avg = total_ms / runs
    min = times.min || 0.0
    max = times.max || 0.0
    ips = (runs * 1000.0) / total_ms if total_ms.positive?

    alloc_objects = if before_gc && after_gc && before_gc.key?(:total_allocated_objects)
                      after_gc[:total_allocated_objects].to_i - before_gc[:total_allocated_objects].to_i
                    end

    objects_by_type = compute_objects_by_type(before_objs, after_objs)

    out = {
      name: name,
      runs: runs,
      wall_ms_avg: round3(avg),
      wall_ms_min: round3(min),
      wall_ms_max: round3(max),
      ips: ips ? ips.round(1) : nil,
      alloc_objects: alloc_objects,
      objects_by_type: objects_by_type
    }
    out[:mem_bytes_total] = (after_mem - before_mem) if before_mem && after_mem
    out
  end

  def round3(v)
    ((v || 0.0) * 1000).round / 1000.0
  end

  def safe_gc_stat
    GC.start
    GC.stat
  rescue StandardError
    nil
  end

  def safe_count_objects
    ObjectSpace.count_objects
  rescue StandardError
    nil
  end

  def safe_memsize
    if defined?(ObjectSpace.memsize_of_all)
      ObjectSpace.memsize_of_all
    end
  rescue StandardError
    nil
  end

  def compute_objects_by_type(before, after)
    return {} unless before && after

    keys = %i[T_HASH T_ARRAY T_STRING]
    out = {}
    keys.each do |k|
      out[k] = after[k].to_i - before[k].to_i if after.key?(k) && before.key?(k)
    end
    out
  end

  # --- IO --------------------------------------------------------------------

  def write_json(path, payload)
    dir = File.dirname(path)
    FileUtils.mkdir_p(dir)
    json = JSON.pretty_generate(payload)
    File.write(path, json)
  end

  def print_comparison(baseline_path, after_path)
    base = JSON.parse(File.read(baseline_path), symbolize_names: true)
    after = JSON.parse(File.read(after_path), symbolize_names: true)

    base_map = base[:scenarios].each_with_object({}) { |h, acc| acc[h[:name]] = h }
    after_map = after[:scenarios].each_with_object({}) { |h, acc| acc[h[:name]] = h }

    puts 'Deltas (%):'
    base_map.keys.sort.each do |name|
      b = base_map[name]
      a = after_map[name]
      next unless a

      wall = pct_delta(b[:wall_ms_avg], a[:wall_ms_avg])
      ips  = pct_delta(b[:ips], a[:ips])
      alloc = pct_delta(b[:alloc_objects], a[:alloc_objects])
      mem = pct_delta(b[:mem_bytes_total], a[:mem_bytes_total])

      parts = []
      parts << "wall #{fmt_pct(wall)}" if wall
      parts << "ips #{fmt_pct(ips)}" if ips
      parts << "alloc #{fmt_pct(alloc)}" if alloc
      parts << "mem #{fmt_pct(mem)}" if mem
      puts "- #{name}: #{parts.join(', ')}"
    end
    puts "Compared #{baseline_path} -> #{after_path}"
  end

  def pct_delta(before, after)
    return nil unless before && after && before.to_f != 0.0

    ((after.to_f - before.to_f) / before.to_f) * 100.0
  end

  def fmt_pct(v)
    return 'n/a' unless v

    (v >= 0 ? '+' : '') + format('%.1f%%', v)
  end

  # --- CLI -------------------------------------------------------------------

  def parse_args(argv)
    out = nil
    compare = nil
    runs = 200
    warmup = 50

    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby script/bench.rb --out tmp/bench/after.json [--compare tmp/bench/baseline.json] [--runs N] [--warmup M]'
      opts.on('--out PATH', 'Output JSON path (required)') { |v| out = v }
      opts.on('--compare PATH', 'Baseline JSON to compare against') { |v| compare = v }
      opts.on('--runs N', Integer, 'Number of runs per scenario (default: 200)') { |v| runs = v }
      opts.on('--warmup N', Integer, 'Warmup iterations (default: 50)') { |v| warmup = v }
    end
    parser.parse!(argv)

    if out.nil?
      ts = Time.now.utc.strftime('%Y%m%d_%H%M%S')
      out = File.expand_path("../tmp/bench/#{ts}.json", __dir__)
    else
      out = File.expand_path(out, Dir.pwd)
    end

    compare = File.expand_path(compare, Dir.pwd) if compare

    { out: out, compare: compare, runs: runs, warmup: warmup }
  end
end

if __FILE__ == $PROGRAM_NAME
  args = Bench.parse_args(ARGV)
  Bench.run!(out_path: args[:out], compare_path: args[:compare], runs: args[:runs], warmup: args[:warmup])
end
