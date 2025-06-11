require 'chewy/search/parameters/storage'

module Chewy
  module Search
    class Parameters
      class FunctionScore < Storage
        include HashStorage

        # Adds new data to the existing data array.
        #
        # @see Chewy::Search::Parameters::Storage#update!
        # @param other_value [Hash, Array<Hash>] any acceptable storage value
        # @return [Array<Hash>] updated value
        def update!(other_value)
          new_value = normalize(other_value)
          new_value[:functions] = value.fetch(:functions, []) | new_value[:functions] if new_value.key?(:functions)
          super(new_value)
        end

        def render
          {query: {function_score: value}} if value.present?
        end

      private

        def normalize(value)
          (value || {}).deep_symbolize_keys
        end
      end
    end
  end
end
