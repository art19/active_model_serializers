require 'new_relic/agent/method_tracer'

module ActiveModel
  class Serializer
    class CollectionSerializer
      include ::NewRelic::Agent::MethodTracer
      NoSerializerError = Class.new(StandardError)
      include Enumerable
      delegate :each, to: :@serializers

      attr_reader :object, :root

      def initialize(resources, options = {})
        @root        = options[:root]
        @object      = resources
        @serializers = []

        serializer_context_class = options.fetch(:serializer_context_class, ActiveModel::Serializer)
        each_options             = { serializer_namespace: options.fetch(:serializer_namespace, nil) }.compact

        resources.each do |resource|
          serializer_class = options.fetch(:serializer) { serializer_context_class.serializer_for(resource, each_options) }
          raise NoSerializerError, "No serializer found for resource: #{resource.inspect}" if serializer_class.nil?

          @serializers << serializer_class.new(resource, options.except(:serializer))
        end
      end
      add_method_tracer :initialize

      def json_key
        root || derived_root
      end

      def paginated?
        object.respond_to?(:current_page) &&
          object.respond_to?(:total_pages) &&
          object.respond_to?(:size)
      end

      protected

      attr_reader :serializers

      private

      def derived_root
        key = serializers.first.try(:json_key) || object.try(:name).try(:underscore)
        key.try(:pluralize)
      end
    end
  end
end
