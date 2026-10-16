# frozen_string_literal: true

require 'blueprinter/extractors/auto_extractor'
require 'blueprinter/formatters/date_time_formatter'

# @api private
module Blueprinter
  class Field
    DATETIME_FORMATTER = DateTimeFormatter.new

    attr_reader :method, :name, :extractor, :options, :blueprint

    def initialize(method, name, extractor, blueprint, options = {})
      @method = method
      @name = name
      @extractor = extractor
      @blueprint = blueprint
      @options = options
      @plain_extraction = plain_extraction?
    end

    def extract(object, local_options)
      return extract_plain(object) if @plain_extraction

      extractor.extract(method, object, local_options, options)
    end

    def skip?(field_name, object, local_options)
      return true if if_callable && !if_callable.call(field_name, object, local_options)

      unless_callable && unless_callable.call(field_name, object, local_options)
    end

    private

    # Whether this field can skip AutoExtractor: fields with a block
    def plain_extraction?
      extractor.instance_of?(AutoExtractor) &&
        !options[:block] &&
        !options[:datetime_format] &&
        !options[:default_if] &&
        !options.key?(:default)
    end

    # Equivalent to AutoExtractor#extract for plain fields.
    def extract_plain(object)
      value = object.is_a?(Hash) ? object[method] : object.public_send(method)
      value = DATETIME_FORMATTER.format(value, options) if !value.nil? && Blueprinter.configuration.datetime_format
      value.nil? ? Blueprinter.configuration.field_default : value
    end

    def if_callable
      @_if_callable ||= callable_from(:if)
    end

    def unless_callable
      @_unless_callable ||= callable_from(:unless)
    end

    def callable_from(condition)
      config = Blueprinter.configuration

      # Use field-level callable, or when not defined, try global callable
      tmp = if options.key?(condition)
              options.fetch(condition)
            elsif config.valid_callable?(condition)
              config.public_send(condition)
            end

      return false unless tmp

      case tmp
      when Proc then tmp
      when Symbol then blueprint.method(tmp)
      else
        raise ArgumentError, "#{tmp.class} is passed to :#{condition}"
      end
    end
  end
end
