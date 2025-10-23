module Chewy
  class Strategy
    # This strategy works like atomic but import objects with `refresh=false` parameter.
    #
    #   Chewy.strategy(:atomic_no_refresh) do
    #     User.all.map(&:save) # Does nothing here
    #     Post.all.map(&:save) # And here
    #     # It imports all the changed users and posts right here
    #     # before block leaving with bulk ES API, kinda optimization
    #   end
    #
    class AtomicNoRefresh < Atomic
      def leave
        @stash.all? do |type, type_options|
          type_options.all? do |options, ids|
            next if ids.empty?

            options[:refresh] = false

            type.import!(ids, **options)
          end
        end
      end
    end
  end
end
