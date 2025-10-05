# frozen_string_literal: true

require 'test_helper'

class BatchPlannerTest < Minitest::Test
  def test_encode_jsonl_counts_and_bytes
    docs = [{ id: 1, name: 'a' }, { id: 2, x: true }]
    buffer = +''
    count, bytes = SearchEngine::Indexer::BatchPlanner.encode_jsonl!(docs, buffer)
    assert_equal 2, count
    assert buffer.end_with?("\n"), 'buffer should end with newline-separated lines'
    assert_operator bytes, :>, 0
    lines = buffer.lines
    # Expect exactly 2 JSON lines + one trailing newline collapse means lines size == 2 still
    assert_equal 2, lines.size
  end

  def test_to_array_helpers
    assert_equal [1], SearchEngine::Indexer::BatchPlanner.to_array(1)
    assert_equal [1, 2], SearchEngine::Indexer::BatchPlanner.to_array([1, 2])
  end

  def test_missing_id_raises
    docs = [{ name: 'a' }]
    buffer = +''
    assert_raises(SearchEngine::Errors::InvalidParams) do
      SearchEngine::Indexer::BatchPlanner.encode_jsonl!(docs, buffer)
    end
  end
end
