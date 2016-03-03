module ActiveModelSerializers
  module Adapter
    ##
    # JSON serializer adapter which supports side loaded associations currently expeded
    # by ART19's ember data version.
    class Art19EmberData < Base
      ##
      # Generate a hash of attributes for the current serializer
      #
      # @param options [Hash]
      #     Options to pass along to the Attributes collection's serializable_hash method
      #
      # @return [Hash] the hash of attributes
      def serializable_hash(options = {})
        # Serialize as per usual
        serialized = Attributes.new(serializer, instance_options).serializable_hash(options)

        # Do not pass go, do not collect $200 if this is an error.
        # This keeps us from specifying root: false in every controller.
        return serialized if serializer.is_a? ErrorSerializer

        # Add pagination if collection is paginated
        add_pagination_meta if collection?

        if serializer.root != false
          # Make included associations siblings of root to keep ED happy.
          serialized   = { root => serialized }
          root_node    = serialized[root]

          return serialized unless root_node.present?

          extract_keys = included_association_keys
          [root_node].flatten.each { |obj| extract_included_assocations(serialized, obj, extract_keys) }
        end

        serialized
      end

      protected

      ##
      # Add pagination meta data to the instance options hash, if the current option carries
      # such meta data.
      def add_pagination_meta
        object = serializer.object

        if object.respond_to?(:total_count) && object.respond_to?(:entry_name)
          instance_options[:meta] ||= {}
          instance_options[:meta].merge!(
                                current_page: object.try(:current_page),
                                next_page: object.try(:next_page),
                                prev_page: object.try(:prev_page),
                                total_pages: object.try(:total_pages),
                                total_count: object.try(:total_count))
        end

        instance_options
      end

      def extract_included_assocations(json, obj, keys = [])
        obj.each do |key, value|
          if keys.include?(key)
            json[key] = [] unless json.keys.include?(key)
            value.each { |item| json[key] << item }
            obj.delete key
          end
        end
      end

      ##
      # @return [Enumerator] List of associations linked to the current serializer (or it's item serializer if it's a collection)
      def associations
        unless collection?
          serializer.associations
        else
          serializer.first.associations
        end
      end

      ##
      # @return [Boolean] true, if the serializer is a collection serializer
      def collection?
        serializer.respond_to? :each
      end

      def derived_class
        if collection?
          klass = serializer.object.try(:klass).try(:base_class)
          klass ||= serializer.object.try(:first).try(:base_class)
        else
          serializer.object.class.try(:base_class) || serializer.object.class
        end
      end

      ##
      # @return [Array<String>] Names of all associations marked to be :included (side-loaded)
      def included_association_keys
        associations.select { |a| a.options.fetch(:include, false) }.collect(&:name)
      end

      ##
      # Determine the name of the root node. For collection serializers we use the element-serializer class.
      # The root node is taken from the serializer class name if available, and if not from the serializer's object
      # base class.
      #
      # @return [String] the name of the root node
      def root
        element_serializer = collection? ? serializer.first : serializer

        root_name = element_serializer.class.name.demodulize.underscore.sub(/_serializer\z/, '') if element_serializer.present?
        root_name ||= derived_class.try(:model_name).try(:element)
        root_name ||= super.to_s

        return root_name.pluralize if collection?
        root_name
      end
    end
  end
end
