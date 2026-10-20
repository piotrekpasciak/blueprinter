# frozen_string_literal: true

require 'json'
require 'blueprinter/extensions'
require 'blueprinter/extractors/auto_extractor'
require 'blueprinter/compiler'

module Blueprinter
  class Configuration
    attr_accessor(
      :custom_array_like_classes,
      :default_transformers,
      :deprecations,
      :generator,
      :method,
      :sort_fields_by
    )
    attr_reader :extensions, :extractor_default, :compile_views

    # Settings that compiled views read when they are compiled. Changing one discards compiled views, so they are
    # compiled again with the new value on their next render.
    COMPILED_SETTINGS = %i[association_default datetime_format field_default if unless].freeze

    COMPILED_SETTINGS.each do |setting|
      attr_reader setting

      define_method(:"#{setting}=") do |value|
        instance_variable_set(:"@#{setting}", value)
        Compiler.reset_all!
      end
    end

    VALID_CALLABLES = %i[if unless].freeze

    def initialize
      @deprecations = :stderror
      @association_default = nil
      @datetime_format = nil
      @field_default = nil
      @generator = JSON
      @if = nil
      @method = :generate
      @sort_fields_by = :name_asc
      @unless = nil
      @extractor_default = AutoExtractor
      @default_transformers = []
      @custom_array_like_classes = []
      @extensions = Extensions.new
      @compile_views = false
    end

    # Opt-in: render with each view compiled into plain Ruby methods. Output is the same as standard rendering; fields
    # that can't be compiled (e.g. custom extractors) keep using the standard code path.
    def compile_views=(enabled)
      @compile_views = enabled ? true : false
      Compiler.reset_all!
    end

    def extensions=(list)
      @extensions = Extensions.new(list)
    end

    def array_like_classes
      @_array_like_classes ||= [
        Array,
        defined?(ActiveRecord::Relation) && ActiveRecord::Relation,
        *custom_array_like_classes
      ].compact
    end

    def jsonify(blob)
      generator.public_send(method, blob)
    end

    def valid_callable?(callable_name)
      VALID_CALLABLES.include?(callable_name)
    end

    # @param extractor [Class<Blueprinter::AutoExtractor>]
    def extractor_default=(extractor)
      reset_default_extractor!

      @extractor_default = extractor
    end

    # @return [Blueprinter::AutoExtractor]
    def default_extractor
      @_default_extractor ||= extractor_default.new
    end

    private

    def reset_default_extractor!
      @_default_extractor = nil
    end
  end
end
