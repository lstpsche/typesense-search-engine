# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'bundler/setup'
require 'search_engine'

AST = SearchEngine::AST

puts '--- Compiler smoke ---'

examples = [
  AST.eq(:id, 1),
  AST.and_(AST.eq(:active, true), AST.in_(:brand_id, [1, 2])),
  AST.or_(AST.eq(:a, 1), AST.and_(AST.eq(:b, 2), AST.eq(:c, 3))),
  AST.group(AST.or_(AST.eq(:a, 1), AST.eq(:b, 2))),
  [AST.eq(:x, 1), AST.eq(:y, 2)],
  AST.raw('price:>100 && active:=true')
]

examples.each_with_index do |ast, idx|
  out = SearchEngine::Compiler.compile(ast, klass: nil)
  puts "#{idx + 1}. #{out}"
rescue StandardError => error
  puts "#{idx + 1}. ERROR: #{error.class}: #{error.message}"
end
