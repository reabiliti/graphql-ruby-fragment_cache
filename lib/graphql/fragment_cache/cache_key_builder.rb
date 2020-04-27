# frozen_string_literal: true

require "json"
require "digest"

using RubyNext

module GraphQL
  module FragmentCache
    using Ext

    using(Module.new {
      refine Array do
        def to_selections_key
          map { |val|
            children = val.selections.empty? ? "" : "[#{val.selections.to_selections_key}]"
            "#{val.field.name}#{children}"
          }.join(".")
        end
      end

      refine ::GraphQL::Language::Nodes::AbstractNode do
        def alias?(_)
          false
        end
      end

      refine ::GraphQL::Language::Nodes::Field do
        def alias?(val)
          self.alias == val
        end
      end
    })

    # Builds cache key for fragment
    class CacheKeyBuilder
      using RubyNext

      class << self
        def call(**options)
          new(**options).build
        end
      end

      attr_reader :query, :path, :object, :schema

      def initialize(object: nil, query:, path:, **options)
        @object = object
        @query = query
        @schema = query.schema
        @path = path
        @options = options
      end

      def build
        Digest::SHA1.hexdigest("#{schema_cache_key}/#{query_cache_key}").then do |base_key|
          next base_key unless object
          "#{base_key}/#{object_key(object)}"
        end
      end

      private

      def schema_cache_key
        @options.fetch(:schema_cache_key, schema.schema_cache_key)
      end

      def query_cache_key
        @options.fetch(:query_cache_key, "#{path_cache_key}[#{selections_cache_key}]")
      end

      def selections_cache_key
        current_root =
          path.reduce(query.lookahead) { |lkhd, name| lkhd.selection(without_alias(name, lkhd)) }

        current_root.selections.to_selections_key
      end

      def path_cache_key
        lookahead = query.lookahead

        path.map { |field_name|
          lookahead = lookahead.selection(without_alias(field_name, lookahead))
          next field_name if lookahead.arguments.empty?

          args = lookahead.arguments.map { "#{_1}:#{traverse_argument(_2)}" }.sort.join(",")
          "#{field_name}(#{args})"
        }.join("/")
      end

      def without_alias(field_name, lookahead)
        return field_name if lookahead.selects?(field_name)

        lookup_alias(lookahead.ast_nodes, field_name)&.name
      end

      def lookup_alias(nodes, name)
        return if nodes.empty?
        nodes.find do |node|
          return node if node.alias?(name)
          child = lookup_alias(node.children, name)
          return child if child
        end
      end

      def traverse_argument(argument)
        return argument unless argument.is_a?(GraphQL::Schema::InputObject)

        "{#{argument.map { "#{_1}:#{traverse_argument(_2)}" }.sort.join(",")}}"
      end

      def object_key(obj)
        obj._graphql_cache_key
      end
    end
  end
end
