require 'thread_safe'
require 'active_model/serializer/collection_serializer'
require 'active_model/serializer/array_serializer'
require 'active_model/serializer/include_tree'
require 'active_model/serializer/associations'
require 'active_model/serializer/attributes'
require 'active_model/serializer/caching'
require 'active_model/serializer/configuration'
require 'active_model/serializer/fieldset'
require 'active_model/serializer/lint'
require 'active_model/serializer/links'
require 'active_model/serializer/meta'
require 'active_model/serializer/type'

# ActiveModel::Serializer is an abstract class that is
# reified when subclassed to decorate a resource.
module ActiveModel
  class Serializer
    include Configuration
    include Associations
    include Attributes
    include Caching
    include Links
    include Meta
    include Type

    # @param resource [ActiveRecord::Base, ActiveModelSerializers::Model]
    # @return [ActiveModel::Serializer]
    #   Preferentially returns
    #   1. resource.serializer
    #   2. ArraySerializer when resource is a collection
    #   3. options[:serializer]
    #   4. lookup serializer when resource is a Class
    def self.serializer_for(resource, options = {})
      if resource.respond_to?(:serializer_class)
        resource.serializer_class
      elsif resource.respond_to?(:to_ary)
        config.collection_serializer
      else
        options.fetch(:serializer) { get_serializer_for(resource.class, options) }
      end
    end

    # @see ActiveModelSerializers::Adapter.lookup
    # Deprecated
    def self.adapter
      warn 'Calling adapter method in Serializer, please use the ActiveModelSerializers::configured_adapter'
      ActiveModelSerializers::Adapter.lookup(config.adapter)
    end

    # @api private
    def self.serializer_lookup_chain_for(klass, serializer_namespace = nil)
      chain = []

      resource_class_name = klass.name.demodulize
      resource_namespace = klass.name.deconstantize
      serializer_class_name = "#{resource_class_name}Serializer"

      chain.push("#{name}::#{serializer_class_name}") if self != ActiveModel::Serializer

      if serializer_namespace.present?
        chain.push([[serializer_namespace, resource_namespace].reject(&:blank?), serializer_class_name].join('::'))
        chain.push([serializer_namespace, serializer_class_name].join('::'))
      end

      chain.push("#{resource_namespace}::#{serializer_class_name}")

      chain.uniq
    end

    # Used to cache serializer name => serializer class
    # when looked up by Serializer.get_serializer_for.
    def self.serializers_cache
      @serializers_cache ||= ThreadSafe::Cache.new
    end

    # @api private
    # Find a serializer from a class and caches the lookup.
    # Preferentially returns:
    #   1. class name appended with "Serializer"
    #   2. try again with superclass, if present
    #   3. nil
    def self.get_serializer_for(klass, options = {})
      return nil unless config.serializer_lookup_enabled
      serializer_namespace = options.fetch(:serializer_namespace, nil)

      serializers_cache.fetch_or_store([klass, serializer_namespace].compact) do
        # NOTE(beauby): When we drop 1.9.3 support we can lazify the map for perfs.
        serializer_class = serializer_lookup_chain_for(klass, serializer_namespace).map(&:safe_constantize).find { |x| x && x < ActiveModel::Serializer }

        if serializer_class
          serializer_class
        elsif klass.superclass
          get_serializer_for(klass.superclass, options)
        end
      end
    end

    def self._serializer_instance_method_defined?(name)
      _serializer_instance_methods.include?(name)
    end

    def self._serializer_instance_methods
      @_serializer_instance_methods ||= (public_instance_methods - Object.public_instance_methods).to_set
    end
    private_class_method :_serializer_instance_methods

    attr_accessor :object, :root, :scope

    # `scope_name` is set as :current_user by default in the controller.
    # If the instance does not have a method named `scope_name`, it
    # defines the method so that it calls the +scope+.
    def initialize(object, options = {})
      self.object = object
      self.instance_options = options
      self.root = instance_options[:root]
      self.scope = instance_options[:scope]

      scope_name = instance_options[:scope_name]
      if scope_name && !respond_to?(scope_name)
        self.class.class_eval do
          define_method scope_name, lambda { scope }
        end
      end
    end

    # Used by adapter as resource root.
    def json_key
      root || object.class.model_name.to_s.underscore
    end

    def read_attribute_for_serialization(attr)
      if self.class._serializer_instance_method_defined?(attr)
        send(attr)
      elsif self.class._fragmented
        self.class._fragmented.read_attribute_for_serialization(attr)
      else
        object.read_attribute_for_serialization(attr)
      end
    end

    ##
    # @return [ApplicationPolicy] A policy class for the serializer's object using the current scope
    def policy
      return nil unless defined?(Pundit) && instance_options[:skip_policy] != true
      @pundit_policy ||= Pundit.policy(scope, object)
    end

    ##
    # Figure out if the serializer is allowed to serialize an attribute/association
    #
    # @param name [String, Symbol]
    #     Name of the attribute/association
    #
    # @return [Boolean]
    #     true, if the serializer has access to a policy and the policy considers the attribute unpermitted.
    def unpermitted_attribute?(name)
      !permitted_attributes_filtered.include?(name)
    end

    ##
    # Figure out what attributes are currently permitted for serialization.
    #
    # @param requested_attrs [Array<Symbol>]
    #     If present, this is the super set of attributes
    #
    # @param reload [Boolean]
    #     If true, do not return a cached result, but get a fresh one
    #
    # @return [Array<Symbol>]
    #     The list of permitted attributes for serialization
    def permitted_attributes_filtered(requested_attrs = nil, reload = false)
      @permitted_attributes_filtered = nil if reload
      @permitted_attributes_filtered ||= begin
        allowed = permitted_attributes_for_reading(reload)
        if allowed == :all
          requested_attrs || self.class._attributes_data.keys
        else
          return allowed if requested_attrs.nil?
          Set.new(allowed) & Set.new(requested_attrs)
        end
      end

      @permitted_attributes_filtered
    end

    ##
    # Get the list of permitted attributes for reading from the given serializer
    #
    # @param reload [Boolean]
    #     If true, ignore any cached value and build a fresh result
    #
    # @return [:all, Array<Symbol>]
    #     :all, if nothing is restricted by a policy or there is no policy at all. The list of
    #     attributes otherwise
    def permitted_attributes_for_reading(reload = false)
      @permitted_attributes_for_reading = nil if reload
      @permitted_attributes_for_reading ||= begin
        pol = policy
        if pol.present? && pol.respond_to?(:permitted_attributes_for_reading)
          pol.permitted_attributes_for_reading(instance_options[:serializer_namespace])
        else
          :all
        end
      end
    end

    protected

    attr_accessor :instance_options
  end
end
