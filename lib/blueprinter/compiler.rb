# frozen_string_literal: true

require 'monitor'
require 'blueprinter/empty_types'
require 'blueprinter/formatters/date_time_formatter'

module Blueprinter
  # @api private
  #
  # Compiles each view of a Blueprint into private singleton methods on the Blueprint class, used when
  # `Blueprinter.configuration.compile_views` is enabled:
  #
  #   def __bp_render_0_item(object, options)        # one object -> Hash
  #     { id: object.id, name: object.name }
  #   end
  #   def __bp_render_0_hash_item(object, options)   # one Hash -> Hash (only when it differs)
  #   def __bp_render_0(value, options)              # one object or a collection
  #
  # The generated code performs the same steps as the standard rendering path (AutoExtractor, DateTimeFormatter,
  # defaults, if/unless, AssociationExtractor, extensions, transformers). Fields it can't reproduce exactly (custom
  # extractors, Proc blueprints, association :options) call Field#skip? and Field#extract, like standard rendering.
  #
  # Compiled methods are built from the view cache and the configuration at compile time. They are reset (back to
  # stubs that compile on first call) when the view cache is invalidated or a compiled setting changes.
  #
  # Objects that can't be written as Ruby literals (blocks, callables, blueprints, defaults, unusual names) live in a
  # per-Blueprint array (@__bp_refs) referenced by index, so user-provided text is never interpolated as code.
  module Compiler
    LOCK = Monitor.new
    # Method names that can be called directly as `object.name`
    CALLABLE_METHOD = /\A[a-z_][a-zA-Z0-9_]*[?!]?\z/
    # Symbols that can be written as `name:` keys or `:name` literals
    LITERAL_SYMBOL = /\A[a-zA-Z_][a-zA-Z0-9_]*\z/

    @generation = 0
    @compiled_blueprints = ObjectSpace::WeakMap.new

    class << self
      # Bumped whenever compiled views must be rebuilt for every Blueprint (see Configuration::COMPILED_SETTINGS)
      attr_reader :generation

      # @return [Symbol] name of the private method that renders `view` of `blueprint`
      def entry_point(blueprint, view)
        entry_points = blueprint.instance_variable_get(:@__bp_entry_points)
        (entry_points && entry_points[view]) || reserve(blueprint, view)
      end

      # Discards the compiled views of one Blueprint. Doesn't take LOCK: it is called from ViewCollection while that
      # holds its own mutex. A compile racing with it is caught by the cache_version check in #compile.
      def reset(blueprint)
        entry_points = blueprint.instance_variable_get(:@__bp_entry_points)
        return unless entry_points

        blueprint.instance_variable_set(:@__bp_compiled, nil)
        entry_points.each { |view, name| define_stub(blueprint, view, name) }
      end

      # Discards the compiled views of every Blueprint (configuration changed)
      def reset_all!
        @generation += 1
        @compiled_blueprints.each_key { |blueprint| reset(blueprint) }
      end

      def compile(blueprint, view)
        LOCK.synchronize do
          view_collection = blueprint.send(:view_collection)
          stamp = [view_collection.cache_version, generation]
          compiled = blueprint.instance_variable_get(:@__bp_compiled) || {}
          return if compiled[view] == stamp
          raise Errors::UnknownView, "View '#{view}' is not defined" unless view_collection.view?(view)

          name = entry_point(blueprint, view)
          refs = blueprint.instance_variable_get(:@__bp_refs) || blueprint.instance_variable_set(:@__bp_refs, [])
          code = Generator.new(blueprint, view, name, refs, view_collection.fields_for(view),
                               view_collection.transformers(view)).code

          silence_redefinition(blueprint, name, :"#{name}_item", :"#{name}_hash_item")
          blueprint.singleton_class.class_eval(code, "(blueprinter compiled #{describe(blueprint)} view=#{view})", 1)

          # The cache or configuration changed while compiling: go back to the stub so the next call recompiles
          if stamp == [view_collection.cache_version, generation]
            blueprint.instance_variable_set(:@__bp_compiled, compiled.merge(view => stamp).freeze)
          else
            define_stub(blueprint, view, name)
          end
        end
      end

      private

      def reserve(blueprint, view)
        LOCK.synchronize do
          entry_points = blueprint.instance_variable_get(:@__bp_entry_points) || {}
          return entry_points[view] if entry_points.key?(view)

          name = :"__bp_render_#{entry_points.size}"
          define_stub(blueprint, view, name)
          blueprint.instance_variable_set(:@__bp_entry_points, entry_points.merge(view => name).freeze)
          @compiled_blueprints[blueprint] = true
          name
        end
      end

      def define_stub(blueprint, view, name)
        silence_redefinition(blueprint, name)
        singleton = blueprint.singleton_class
        singleton.define_method(name) do |value, options|
          Compiler.compile(self, view)
          __send__(name, value, options)
        end
        singleton.send(:private, name)
      end

      # Avoids "method redefined" warnings without ever leaving the method undefined, since another thread may be
      # calling it. Same approach as ActiveSupport's silence_redefinition_of_method.
      def silence_redefinition(blueprint, *names)
        singleton = blueprint.singleton_class
        names.each do |name|
          next unless singleton.method_defined?(name, false) || singleton.private_method_defined?(name, false)

          singleton.alias_method(:__bp_redefining, name)
          singleton.remove_method(:__bp_redefining)
        end
      end

      def describe(blueprint)
        blueprint.name || blueprint.inspect
      end
    end

    # Builds the Ruby source for one view
    class Generator # rubocop:disable Metrics/ClassLength
      DATETIME_FORMATTER = DateTimeFormatter.new

      def initialize(blueprint, view, name, refs, fields, transformers)
        @blueprint = blueprint
        @view = view
        @name = name
        @refs = refs
        @fields = fields
        @transformers = transformers
        @config = Blueprinter.configuration
        @ref_indexes = {}.compare_by_identity
      end

      def code
        object_body = item_body(hash: false)
        hash_body = item_body(hash: true)
        same_bodies = object_body == hash_body
        one = lambda do |var|
          if same_bodies
            "#{@name}_item(#{var}, options)"
          else
            "#{var}.is_a?(Hash) ? #{@name}_hash_item(#{var}, options) : #{@name}_item(#{var}, options)"
          end
        end
        dispatch = <<~RUBY
          if #{array_like('value')}
            value.map { |object| #{one.call('object')} }
          else
            #{one.call('value')}
          end
        RUBY

        methods = [define(:"#{@name}_item", 'object', object_body)]
        methods << define(:"#{@name}_hash_item", 'object', hash_body) unless same_bodies
        methods << define(@name, 'value', dispatch)
        methods.join("\n")
      end

      private

      def define(name, argument, body)
        refs_line = body.include?('refs[') ? 'refs = @__bp_refs' : ''
        "private def #{name}(#{argument}, options)\n#{refs_line}\n#{body}\nend\n"
      end

      def item_body(hash:)
        literal = []
        statements = []
        keys = {}

        @fields.each do |field|
          expression = plain_expression(field, hash)
          # A repeated name keeps its first position and its last value, like assigning a Hash key twice
          duplicate = keys.key?(field.name)
          keys[field.name] = true

          if expression && statements.empty? && !duplicate
            literal << "#{literal_key(field.name)} #{expression}"
          else
            statements << statement(field, hash, expression)
          end
        end

        @transformers.each { |transformer| statements << "#{ref(transformer)}.transform(h, object, options)" }

        return "{ #{literal.join(', ')} }" if statements.empty?

        "h = { #{literal.join(', ')} }\n#{statements.join("\n")}\nh"
      end

      # Fields whose extraction the generated code reproduces exactly. Anything else uses Field#extract.
      def compilable?(field)
        return field.extractor.instance_of?(AutoExtractor) unless field.options[:association]

        extractor = field.extractor
        extractor.instance_of?(AssociationExtractor) &&
          extractor.instance_variable_get(:@extractor).instance_of?(AutoExtractor) &&
          field.options[:blueprint].is_a?(Class) &&
          field.options[:options].nil?
      end

      def conditional?(field)
        field.send(:if_callable) || field.send(:unless_callable)
      end

      # A single expression for the value of an unconditional field that needs no formatting or default handling
      def plain_expression(field, hash)
        return nil if field.options[:association] || field.options[:exclude_if_nil]
        return nil unless compilable?(field) && !conditional?(field)

        lines = field_value_lines(field, hash)
        lines.size == 1 ? lines.first.delete_prefix('v = ') : nil
      end

      def statement(field, hash, expression)
        return "h[#{key_expression(field.name)}] = #{expression}" if expression
        return fallback_statement(field) unless compilable?(field)

        lines = field.options[:association] ? association_value_lines(field, hash) : field_value_lines(field, hash)
        lines << store(field)
        wrap_condition(field, lines.join("\n"))
      end

      def fallback_statement(field)
        exclude = field.options[:exclude_if_nil] ? ' unless v.nil?' : ''
        <<~RUBY.chomp
          f = #{ref(field)}
          unless f.skip?(f.name, object, options)
            v = f.extract(object, options)
            h[#{key_expression(field.name)}] = v#{exclude}
          end
        RUBY
      end

      # Same as AutoExtractor#extract
      def field_value_lines(field, hash)
        options = field.options
        lines = ["v = #{read(field, hash)}", datetime_line(options, options)].compact
        default = options.key?(:default) ? ref(options[:default]) : literal(@config.field_default)
        condition = default_condition(options[:default_if])
        lines << "v = #{default} if #{condition}" if condition && !(default == 'nil' && !options[:default_if])
        lines
      end

      # Same as AssociationExtractor#extract followed by the associated Blueprint's #hashify
      def association_value_lines(field, hash)
        options = field.options
        lines = ["v = #{read(field, hash)}", datetime_line(options, options.except(:default, :default_if))].compact
        # AssociationExtractor reads the value with AutoExtractor, which applies field_default to nil values
        lines << "v = #{ref(@config.field_default)} if v.nil?" unless @config.field_default.nil?

        render = association_render_lines(options)
        condition = default_condition(options[:default_if])
        if condition
          default = options.key?(:default) ? ref(options[:default]) : literal(@config.association_default)
          lines << "if #{condition}\nv = #{default}\nelse\n#{render.join("\n")}\nend"
        else
          lines.concat(render)
        end
        lines
      end

      # Same steps as the associated Blueprint's #hashify: view check, extensions, then its compiled view
      def association_render_lines(options)
        child = ref(options[:blueprint])
        child_view = options[:view] || :default
        view = key_expression(child_view)
        lines = []
        unless options[:blueprint].view?(child_view)
          message = ref("View '#{child_view}' is not defined")
          lines << "raise ::Blueprinter::Errors::UnknownView, #{message} unless #{child}.view?(#{view})"
        end
        lines << 'e = ::Blueprinter.configuration.extensions'
        lines << "v = e.pre_render(v, #{child}, #{view}, options) unless e.empty?"
        child_options = child_view == @view ? 'options' : "options.merge(view: #{view})"
        entry_point = Compiler.entry_point(options[:blueprint], child_view)
        lines << "v = #{child}.__send__(:#{entry_point}, v, #{child_options})"
      end

      # Same as DateTimeFormatter#format in AutoExtractor; skipped when neither the field nor the configuration has a
      # format, because the formatter returns values unchanged then
      def datetime_line(field_options, format_options)
        return unless field_options[:datetime_format] || @config.datetime_format

        "v = #{ref(DATETIME_FORMATTER)}.format(v, #{ref(format_options)})"
      end

      # Same conditions as EmptyTypes#use_default_value?; nil means the default never applies
      def default_condition(empty_type)
        case empty_type
        when nil, false then 'v.nil?'
        when Blueprinter::EMPTY_COLLECTION then "(#{array_like('v')}) && v.empty?"
        when Blueprinter::EMPTY_HASH then 'v.is_a?(Hash) && v.empty?'
        when Blueprinter::EMPTY_STRING then "v.to_s == ''"
        end
      end

      # Same calling conventions as BlockExtractor, HashExtractor and PublicSendExtractor
      def read(field, hash)
        block = field.options[:block]
        if block
          block.parameters == [[:req], [:rest]] ? "#{ref(block)}.call(object)" : "#{ref(block)}.call(object, **options)"
        elsif hash
          "object[#{key_expression(field.method)}]"
        elsif field.method.to_s.match?(CALLABLE_METHOD)
          "object.#{field.method}"
        else
          "object.public_send(#{ref(field.method)})"
        end
      end

      def store(field)
        key = key_expression(field.name)
        field.options[:exclude_if_nil] ? "h[#{key}] = v unless v.nil?" : "h[#{key}] = v"
      end

      # Same as Field#skip?: rendered when `if` is truthy and `unless` is falsy
      def wrap_condition(field, code)
        if_callable = field.send(:if_callable)
        unless_callable = field.send(:unless_callable)
        parts = []
        parts << "#{ref(if_callable)}.call(#{key_expression(field.name)}, object, options)" if if_callable
        parts << "!#{ref(unless_callable)}.call(#{key_expression(field.name)}, object, options)" if unless_callable
        parts.empty? ? code : "if #{parts.join(' && ')}\n#{code}\nend"
      end

      def array_like(var)
        checks = @config.array_like_classes.map do |klass|
          klass == Array ? "#{var}.is_a?(Array)" : "#{var}.is_a?(#{ref(klass)})"
        end
        checks.join(' || ')
      end

      def literal_key(name)
        name.is_a?(Symbol) && name.to_s.match?(LITERAL_SYMBOL) ? "#{name}:" : "#{ref(name)} =>"
      end

      def key_expression(name)
        name.is_a?(Symbol) && name.to_s.match?(LITERAL_SYMBOL) ? ":#{name}" : ref(name)
      end

      def literal(value)
        value.nil? ? 'nil' : ref(value)
      end

      def ref(object)
        index = @ref_indexes[object] ||= begin
          @refs << object
          @refs.size - 1
        end
        "refs[#{index}]"
      end
    end
  end
end
