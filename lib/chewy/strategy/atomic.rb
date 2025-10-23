module Chewy
  class Strategy
    # This strategy accumulates all the objects prepared for
    # indexing and fires index process when strategy is popped
    # from the strategies stack.
    #
    #   Chewy.strategy(:atomic) do
    #     User.all.map(&:save) # Does nothing here
    #     Post.all.map(&:save) # And here
    #     # It imports all the changed users and posts right here
    #     # before block leaving with bulk ES API, kinda optimization
    #   end
    #
    class Atomic < Base
      def initialize
        @stash = {}
      end

      # @stash structure example:
      # {
      #   UsersIndex => {
      #     {update_fields: [:first_name, :last_name]} => [id1, id2],
      #     {update_fields: [:email]} => [id3, id4]
      #   }
      # }
      def update(type, objects, options = {})
        @stash[type] ||= {}
        @stash[type][options] ||= []
        @stash[type][options] |= type.root.id ? Array.wrap(objects) : type.adapter.identify(objects)
      end

      def leave
        @stash.all? do |type, type_options|
          type_options.all? do |options, ids|
            type.import!(ids, **options)
          end
        end
      end
    end
  end
end
