require 'active_support/core_ext/hash/keys'

# Rspec matcher `update_index`
# To use it - add `require 'chewy/rspec'` to the `spec_helper.rb`
# Simple usage - just pass index as argument.
#
#   specify { expect { user.save! }.to update_index(UsersIndex) }
#   specify { expect { user.save! }.to update_index('users') }
#   specify { expect { user.save! }.not_to update_index('users') }
#
# This example will pass as well because user1 was reindexed
# and nothing was said about user2:
#
#   specify { expect { [user1, user2].map(&:save!) }
#     .to update_index(UsersIndex).and_reindex(user1) }
#
# If you need to specify reindexed records strictly - use `only` chain.
# Combined matcher chain methods:
#
#   specify { expect { user1.destroy!; user2.save! } }
#     .to update_index(UsersIndex).and_reindex(user2).and_delete(user1) }
#
RSpec::Matchers.define :update_index do |index_name, options = {}| # rubocop:disable Metrics/BlockLength
  if !respond_to?(:failure_message) && respond_to?(:failure_message_for_should)
    alias_method :failure_message, :failure_message_for_should
    alias_method :failure_message_when_negated, :failure_message_for_should_not
  end

  # Specify indexed records by passing record itself or id.
  #
  #   specify { expect { user.save! }.to update_index(UsersIndex).and_reindex(user)
  #   specify { expect { user.save! }.to update_index(UsersIndex).and_reindex(42)
  #   specify { expect { [user1, user2].map(&:save!) }
  #     .to update_index(UsersIndex).and_reindex(user1, user2) }
  #   specify { expect { [user1, user2].map(&:save!) }
  #     .to update_index(UsersIndex).and_reindex(user1).and_reindex(user2) }
  #
  # Specify indexing count for every particular record. Useful in case
  # urgent index updates.
  #
  #   specify { expect { 2.times { user.save! } }
  #     .to update_index(UsersIndex).and_reindex(user, times: 2) }
  #
  # Specify reindexed attributes. Note that arrays are
  # compared position-independently.
  #
  #   specify { expect { user.update_attributes!(name: 'Duke') }
  #     .to update_index(UsersIndex).and_reindex(user, with: {name: 'Duke'}) }
  #
  # You can combine all the options and chain `and_reindex` method to
  # specify options for every indexed record:
  #
  #   specify { expect { 2.times { [user1, user2].map { |u| u.update_attributes!(name: "Duke#{u.id}") } } }
  #     .to update_index(UsersIndex)
  #     .and_reindex(user1, with: {name: 'Duke42'}) }
  #     .and_reindex(user2, times: 1, with: {name: 'Duke43'}) }
  #
  chain(:and_reindex) do |*args|
    @reindex ||= {}
    @reindex.merge!(extract_documents(*args))
  end

  # Specify partially updated records. Update action uses `doc` attributes.
  #
  #   specify { expect { DummiesIndex.bulk body: [{update: {_id: 42, doc: {a: 1}}}] } }
  #     .to update_index(DummiesIndex).and_update(42, with: {a: 1})
  #
  chain(:and_update) do |*args|
    @update ||= {}
    @update.merge!(extract_documents(*args))
  end

  # Specify deleted records with record itself or id passed.
  #
  #   specify { expect { user.destroy! }.to update_index(UsersIndex).and_delete(user) }
  #   specify { expect { user.destroy! }.to update_index(UsersIndex).and_delete(user.id) }
  #
  chain(:and_delete) do |*args|
    @delete ||= {}
    @delete.merge!(extract_documents(*args))
  end

  # Used for specifying than no other records would be indexed or deleted:
  #
  #   specify { expect { [user1, user2].map(&:save!) }
  #     .to update_index(UsersIndex).and_reindex(user1, user2).only }
  #   specify { expect { [user1, user2].map(&:destroy!) }
  #     .to update_index(UsersIndex).and_delete(user1, user2).only }
  #
  # This example will fail:
  #
  #   specify { expect { [user1, user2].map(&:save!) }
  #     .to update_index(UsersIndex).and_reindex(user1).only }
  #
  chain(:only) do |*_args|
    raise 'Use `only` in conjunction with `and_reindex`, `and_update` or `and_delete`' if @reindex.blank? && (@update.nil? || @update.blank?) && @delete.blank?

    @only = true
  end

  # Expect import to be called with refresh=false parameter
  chain(:no_refresh) do
    @no_refresh = true
  end

  # Expect partial updates to be sent with doc_as_upsert flag
  chain(:doc_as_upsert) do
    @doc_as_upsert = true
  end

  def supports_block_expectations?
    true
  end

  match do |block| # rubocop:disable Metrics/BlockLength
    @reindex ||= {}
    @update ||= {}
    @delete ||= {}
    @missed_reindex = []
    @missed_update = []
    @missed_delete = []

    index = Chewy.derive_name(index_name)
    if defined?(Mocha) && RSpec.configuration.mock_framework.to_s == 'RSpec::Core::MockingAdapters::Mocha'
      params_matcher = @no_refresh ? has_entry(refresh: false) : any_parameters
      Chewy::Index::Import::BulkRequest.stubs(:new).with(index, params_matcher).returns(mock_bulk_request)
    else
      mocked_already = RSpec::Mocks.space.proxy_for(Chewy::Index::Import::BulkRequest).method_double_if_exists_for_message(:new)
      allow(Chewy::Index::Import::BulkRequest).to receive(:new).and_call_original unless mocked_already
      params_matcher = @no_refresh ? hash_including(refresh: false) : any_args
      allow(Chewy::Index::Import::BulkRequest).to receive(:new).with(index, params_matcher).and_return(mock_bulk_request)
    end

    Chewy.strategy(options[:strategy] || :atomic) { block.call }

    mock_bulk_request.updates.each do |updated_document|
      if (body = updated_document[:index])
        register_reindex(body[:_id], body[:data])
      elsif (body = updated_document[:update])
        payload = update_payload(body)
        if doc_as_upsert_payload?(payload)
          register_reindex(body[:_id], payload[:doc])
        elsif (document = @update[body[:_id].to_s])
          document[:real_count] += 1
          document[:real_attributes].merge!(payload[:doc] || {})
        elsif @only
          @missed_update.push(body[:_id].to_s)
        end
      elsif (body = updated_document[:delete])
        if (document = @delete[body[:_id].to_s])
          document[:real_count] += 1
        elsif @only
          @missed_delete.push(body[:_id].to_s)
        end
      end
    end

    @reindex.each_value do |document|
      document[:match_count] = (!document[:expected_count] && document[:real_count].positive?) ||
        (document[:expected_count] && document[:expected_count] == document[:real_count])
      document[:match_attributes] = document[:expected_attributes].blank? ||
        compare_attributes(document[:expected_attributes], document[:real_attributes])
    end
    @update.each_value do |document|
      document[:match_count] = (!document[:expected_count] && document[:real_count].positive?) ||
        (document[:expected_count] && document[:expected_count] == document[:real_count])

      matches_with = document[:expected_attributes].blank? ||
        compare_attributes(document[:expected_attributes], document[:real_attributes])

      if document[:expected_only_attributes].present?
        # with_only means: only these keys may be updated and must match
        updated_keys = document[:real_attributes].keys.map(&:to_sym)
        allowed_keys = document[:expected_only_attributes].keys
        only_keys_ok = (updated_keys - allowed_keys).empty?
        only_values_ok = compare_attributes(document[:expected_only_attributes], document[:real_attributes])
        document[:match_attributes] = matches_with && only_keys_ok && only_values_ok
        document[:only_keys_ok] = only_keys_ok
        document[:only_values_ok] = only_values_ok
      else
        document[:match_attributes] = matches_with
      end
    end
    @delete.each_value do |document|
      document[:match_count] = (!document[:expected_count] && document[:real_count].positive?) ||
        (document[:expected_count] && document[:expected_count] == document[:real_count])
    end

    doc_as_upsert_ok = doc_as_upsert_valid?

    mock_bulk_request.updates.present? && doc_as_upsert_ok &&
      @missed_reindex.none? && @missed_update.none? && @missed_delete.none? &&
      @reindex.all? { |_, document| document[:match_count] && document[:match_attributes] } &&
      @update.all? { |_, document| document[:match_count] && document[:match_attributes] } &&
      @delete.all? { |_, document| document[:match_count] }
  end

  failure_message do # rubocop:disable Metrics/BlockLength
    output = ''

    if mock_bulk_request.updates.none?
      output << "Expected index `#{index_name}` to be updated#{' with no refresh' if @no_refresh}, but it was not\n"
    elsif @doc_as_upsert_error
      output << case @doc_as_upsert_error
      when :missing_updates
        "Expected partial updates with doc_as_upsert, but no partial updates were performed\n"
      when :missing_flag
        "Expected doc_as_upsert flag for updates #{@doc_as_upsert_missing_ids}, but it was missing\n"
      end
    elsif @missed_reindex.present? || @missed_update&.present? || @missed_delete.present?
      message = "Expected index `#{index_name}` "
      expected_updated_ids = (@reindex.keys + (@update || {}).keys).uniq
      message << [
        ("to update documents #{expected_updated_ids}" if expected_updated_ids.present?),
        ("to delete documents #{@delete.keys}" if @delete.present?)
      ].compact.join(' and ')
      message << ' only, but '
      missed_updated_ids = (@missed_reindex + (@missed_update || [])).uniq
      message << [
        ("#{missed_updated_ids} was updated" if missed_updated_ids.present?),
        ("#{@missed_delete} was deleted" if @missed_delete.present?)
      ].compact.join(' and ')
      message << ' also.'

      output << message
    end

    output << @reindex.each.with_object('') do |(id, document), result|
      unless document[:match_count] && document[:match_attributes]
        result << "Expected document with id `#{id}` to be reindexed"
        if document[:real_count].positive?
          if document[:expected_count] && !document[:match_count]
            result << "\n   #{document[:expected_count]} times, but was reindexed #{document[:real_count]} times"
          end
          if document[:expected_attributes].present? && !document[:match_attributes]
            result << "\n   with #{document[:expected_attributes]}, but it was reindexed with #{document[:real_attributes]}"
          end
        else
          result << ', but it was not'
        end
        result << "\n"
      end
    end

    output << @update.each.with_object('') do |(id, document), result|
      unless document[:match_count] && document[:match_attributes]
        result << "Expected document with id `#{id}` to be updated"
        if document[:real_count].positive?
          if document[:expected_count] && !document[:match_count]
            result << "\n   #{document[:expected_count]} times, but was updated #{document[:real_count]} times"
          end
          if document[:expected_attributes].present? && !document[:match_attributes]
            result << "\n   with #{document[:expected_attributes]}, but it was updated with #{document[:real_attributes]}"
          end
          if document[:expected_only_attributes].present?
            unless document[:only_keys_ok]
              result << "\n   only fields #{document[:expected_only_attributes].keys} should be updated, but got #{document[:real_attributes].keys}"
            end
            unless document[:only_values_ok]
              result << "\n   with_only #{document[:expected_only_attributes]}, but it was updated with #{document[:real_attributes]}"
            end
          end
        else
          result << ', but it was not'
        end
        result << "\n"
      end
    end

    output << @delete.each.with_object('') do |(id, document), result|
      unless document[:match_count]
        result << "Expected document with id `#{id}` to be deleted"
        result << if document[:real_count].positive? && document[:expected_count]
          "\n   #{document[:expected_count]} times, but was deleted #{document[:real_count]} times"
        else
          ', but it was not'
        end
        result << "\n"
      end
    end

    actually_reindexed_documents = mock_bulk_request.updates.filter_map { |document| document[:index] }
    actually_updated_documents = mock_bulk_request.updates.filter_map { |document| document[:update] }
    actually_deleted_documents = mock_bulk_request.updates.filter_map { |document| document[:delete] }

    if actually_reindexed_documents.present?
      output << "Actually reindexed documents:\n"
      actually_reindexed_documents.each do |document|
        output << "  document id `#{document[:_id]}` and attributes #{document[:data]}\n"
      end
    end

    if actually_updated_documents.present?
      output << "Actually updated documents:\n"
      actually_updated_documents.each do |document|
        output << "  document id `#{document[:_id]}` and attributes #{document[:data]}\n"
      end
    end

    if actually_deleted_documents.present?
      output << "Actually deleted documents:\n"
      actually_deleted_documents.each do |document|
        output << "  document id `#{document[:_id]}`\n"
      end
    end

    output
  end

  failure_message_when_negated do
    if mock_bulk_request.updates.present?
      "Expected index `#{index_name}` not to be updated, but it was with #{mock_bulk_request.updates.map(&:values).flatten.group_by { |documents| documents[:_id] }.map do |id, documents|
                                                                             "\n  document id `#{id}` (#{documents.count} times)"
                                                                           end.join}\n"
    end
  end

  def mock_bulk_request
    @mock_bulk_request ||= MockBulkRequest.new
  end

  def doc_as_upsert_valid?
    return true unless @doc_as_upsert

    update_entries = mock_bulk_request.updates.filter_map { |document| document[:update] }
    if update_entries.blank?
      @doc_as_upsert_error = :missing_updates
      return false
    end

    missing = update_entries.reject { |entry| doc_as_upsert_payload?(update_payload(entry)) }
    if missing.present?
      @doc_as_upsert_error = :missing_flag
      @doc_as_upsert_missing_ids = missing.map { |entry| entry[:_id].to_s }
      return false
    end

    true
  end

  def doc_as_upsert_payload?(payload)
    payload.is_a?(Hash) && payload[:doc_as_upsert]
  end

  def update_payload(body)
    body[:data].is_a?(Hash) ? body[:data] : body
  end

  def register_reindex(id, data)
    if (document = @reindex[id.to_s])
      document[:real_count] += 1
      document[:real_attributes].merge!(data || {})
    elsif @only
      @missed_reindex.push(id.to_s)
    end
  end

  def extract_documents(*args)
    options = args.extract_options!

    expected_count = options[:times] || options[:count]
    expected_attributes = (options[:with] || options[:attributes] || {}).deep_symbolize_keys
    expected_only_attributes = (options[:with_only] || {}).deep_symbolize_keys

    args.flatten.to_h do |document|
      id = document.respond_to?(:id) ? document.id.to_s : document.to_s
      [id, {
        document: document,
        expected_count: expected_count,
        expected_attributes: expected_attributes,
        expected_only_attributes: expected_only_attributes,
        real_count: 0,
        real_attributes: {}
      }]
    end
  end

  def compare_attributes(expected, real)
    expected.inject(true) do |result, (key, value)|
      equal = if value.is_a?(Array) && real[key].is_a?(Array)
        array_difference(value, real[key]) && array_difference(real[key], value)
      elsif value.is_a?(Hash) && real[key].is_a?(Hash)
        compare_attributes(value, real[key])
      else
        real[key] == value
      end
      result && equal
    end
  end

  def array_difference(first, second)
    difference = first.to_ary.dup
    second.to_ary.each do |element|
      index = difference.index(element)
      difference.delete_at(index) if index
    end
    difference.none?
  end

  # Collects request bodies coming through the perform method for
  # the further analysis.
  class MockBulkRequest
    attr_reader :updates

    def initialize
      @updates = []
    end

    def perform(body)
      @updates.concat(body.map(&:deep_symbolize_keys))
      []
    end
  end
end
