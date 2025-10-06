# frozen_string_literal: true

require 'test_helper'
require 'search_engine/logging/format_helpers'

class FormatHelpersTest < Minitest::Test
  H = SearchEngine::Logging::FormatHelpers

  def test_value_or_dash
    assert_equal H::DASH, H.value_or_dash(nil)
    assert_equal H::DASH, H.value_or_dash('')
    assert_equal 0, H.value_or_dash(0)
    assert_equal false, H.value_or_dash(false)
    assert_equal 'x', H.value_or_dash('x')
  end

  def test_display_or_dash
    p = { a: 1, b: nil }
    assert_equal 1, H.display_or_dash(p, :a)
    assert_equal H::DASH, H.display_or_dash(p, :b)
    assert_equal H::DASH, H.display_or_dash(p, :c)
  end

  def test_fixed_width_truncate_and_pad
    assert_equal 'hel…', H.fixed_width('hello', 4)
    assert_equal 'hello     ', H.fixed_width('hello', 10)
    assert_equal '     hello', H.fixed_width('hello', 10, align: :right)
    assert_equal '  hello   ', H.fixed_width('hello', 10, align: :center)
  end

  def test_build_table
    rows = [
      %w[id name],
      %w[1 Alice]
    ]
    out = H.build_table(rows, [2, 5])
    lines = out.split("\n")
    assert_equal 'id name ', lines[0]
    assert_equal '1  Alice', lines[1]
  end

  def test_kv_compact
    h = { 'a' => 1, 'b' => nil, 'c' => 'x' }
    assert_equal 'a=1 c=x', H.kv_compact(h)
    assert_equal '', H.kv_compact(nil)
  end
end
