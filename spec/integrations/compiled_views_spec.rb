# frozen_string_literal: true

require 'date'

# Covers what ViewCompiler generates code for: direct reads, Hash reads, conditions, exclude_if_nil, associations,
# global settings, and the fields it reads with Field#extract instead.
describe 'Compiled views' do
  before { reset_blueprinter_config! }
  after { reset_blueprinter_config! }

  let(:vehicle_class) { Struct.new(:id, :make, :model, :miles, keyword_init: true) }
  let(:user_class) do
    Struct.new(:id, :first_name, :last_name, :company, :birthday, :deleted_at, :vehicles, keyword_init: true)
  end
  let(:vehicles) { [vehicle_class.new(id: 10, make: 'Super Car', model: 'ACME', miles: 5), vehicle_class.new(id: 11)] }
  let(:user) do
    user_class.new(id: 1, first_name: 'Meg', last_name: 'Ryan', company: 'Procore', birthday: Date.new(1994, 3, 4),
                   vehicles:)
  end
  let(:vehicle_blueprint) do
    Class.new(Blueprinter::Base) do
      identifier :id
      fields :make, :model

      view :extended do
        field :miles
        field(:seen_view) { |_vehicle, options| options[:view] }
      end
    end
  end

  def render(blueprint, object = user, **options)
    blueprint.render_as_hash(object, **options)
  end

  it 'renders fields and views in the order the view defines them' do
    blueprint = Class.new(Blueprinter::Base) do
      identifier :id
      fields :last_name, :first_name
      field :company, name: :employer

      view :extended do
        exclude :last_name
        field :birthday
      end
    end

    expect(render(blueprint).to_a).to eq([[:id, 1], [:employer, 'Procore'], [:first_name, 'Meg'], [:last_name, 'Ryan']])
    expect(render(blueprint, view: :extended).to_a)
      .to eq([[:id, 1], [:birthday, Date.new(1994, 3, 4)], [:employer, 'Procore'], [:first_name, 'Meg']])
    expect(render(blueprint, view: :identifier)).to eq(id: 1)
    expect(render(blueprint, [user, user_class.new(id: 2)], view: :identifier)).to eq([{ id: 1 }, { id: 2 }])
    expect(render(blueprint, [])).to eq([])
  end

  it 'reads Hash objects by key, including in a collection mixed with other objects' do
    blueprint = Class.new(Blueprinter::Base) do
      identifier :id
      field :first_name, name: :name
      field :'kebab-name', name: :'Kebab Name'
    end
    kebab = Struct.new(:id, :first_name, :'kebab-name')

    expect(render(blueprint, { id: 1, first_name: 'Meg', 'kebab-name': 'k' }))
      .to eq(id: 1, name: 'Meg', 'Kebab Name': 'k')
    expect(render(blueprint, [{ id: 1, first_name: 'Meg' }, kebab.new(2, 'Ann', 'x')]))
      .to eq([{ id: 1, name: 'Meg', 'Kebab Name': nil }, { id: 2, name: 'Ann', 'Kebab Name': 'x' }])
  end

  it 'applies if, unless and exclude_if_nil' do
    blueprint = Class.new(Blueprinter::Base) do
      identifier :id
      field :first_name, if: ->(_name, user, _options) { user.first_name }
      field :last_name, exclude_if_nil: true
      field :company, unless: ->(_name, _user, options) { options[:hide_company] }
      field :birthday, if: :show_birthday?
      field :deleted_at, if: ->(*) { true }, unless: :hidden?

      def self.show_birthday?(_name, _user, options) = options[:show_birthday]
      def self.hidden?(name, _user, options) = options[:hidden]&.include?(name)
    end

    expect(render(blueprint)).to eq(id: 1, first_name: 'Meg', last_name: 'Ryan', company: 'Procore', deleted_at: nil)
    expect(render(blueprint, user_class.new(id: 2), hide_company: true, show_birthday: true, hidden: [:deleted_at]))
      .to eq(id: 2, birthday: nil)
  end

  it 'applies the global if and unless' do
    Blueprinter.configure do |config|
      config.if = ->(name, _object, options) { !options[:skip]&.include?(name) }
      config.unless = ->(name, _object, _options) { name == :company }
    end
    blueprint = Class.new(Blueprinter::Base) do
      identifier :id
      fields :first_name, :last_name, :company
      field :birthday, if: ->(*) { false }
    end

    expect(render(blueprint, skip: [:last_name])).to eq(id: 1, first_name: 'Meg')
  end

  it 'calls blocks with the object and options, and Symbol#to_proc blocks with the object only' do
    blueprint = Class.new(Blueprinter::Base) do
      field(:full_name) { |user, options| "#{options[:prefix]}#{user.first_name} #{user.last_name}" }
      field :upcased, &->(user, _options) { user.first_name.upcase }
      field :first_name, name: :symbol_proc, &:first_name
      field(:keywords) { |user, view:, **| "#{user.id}@#{view}" }
    end

    expect(render(blueprint, prefix: 'Dr. '))
      .to eq(full_name: 'Dr. Meg Ryan', keywords: '1@default', symbol_proc: 'Meg', upcased: 'MEG')
  end

  it 'reads fields with their own defaults or datetime_format through their extractor' do
    blueprint = Class.new(Blueprinter::Base) do
      field :deleted_at, default: 'N/A'
      field :company, default: 'none', default_if: Blueprinter::EMPTY_STRING
      field :birthday, datetime_format: '%Y/%m/%d'
      field(:empty_list, default: [0], default_if: Blueprinter::EMPTY_COLLECTION) { |_user, _options| [] }
    end

    expect(render(blueprint, user_class.new(company: '', birthday: Date.new(1994, 3, 4))))
      .to eq(birthday: '1994/03/04', company: 'none', deleted_at: 'N/A', empty_list: [0])
    expect { render(Class.new(Blueprinter::Base) { field :first_name, datetime_format: '%Y' }) }
      .to raise_error(Blueprinter::DateTimeFormatter::InvalidDateTimeFormatterError)
  end

  it 'uses custom extractors' do
    upcase = Class.new(Blueprinter::Extractor) do
      def extract(field_name, object, _local_options, _options = {})
        object.public_send(field_name).to_s.upcase
      end
    end
    blueprint = Class.new(Blueprinter::Base) do
      field :first_name, extractor: upcase
      field :last_name, extractor: Class.new(Blueprinter::AutoExtractor).new
    end

    expect(render(blueprint)).to eq(first_name: 'MEG', last_name: 'Ryan')
  end

  context 'with global settings set before the first render' do
    let(:blueprint) do
      vehicles = vehicle_blueprint
      Class.new(Blueprinter::Base) do
        fields :birthday, :deleted_at, :first_name
        association(:nothing, blueprint: vehicles) { |_user, _options| nil }
        association :vehicles, blueprint: vehicles
      end
    end

    it 'formats dates and times with datetime_format' do
      Blueprinter.configure { |config| config.datetime_format = '%d-%m-%Y' }

      expect(render(blueprint)).to include(birthday: '04-03-1994', deleted_at: nil, first_name: 'Meg')
    end

    it 'replaces nil association values with association_default' do
      Blueprinter.configure { |config| config.association_default = 'none' }

      expect(render(blueprint)).to include(deleted_at: nil, nothing: 'none')
    end

    it 'replaces nil values with field_default, including the value an association reads' do
      Blueprinter.configure { |config| config.field_default = 'N/A' }
      without_associations = Class.new(Blueprinter::Base) { fields :deleted_at, :first_name }

      expect(render(without_associations)).to eq(deleted_at: 'N/A', first_name: 'Meg')
      expect { render(blueprint) }.to raise_error(NoMethodError, /id/)
    end

    it 'keeps the configuration a view was compiled with at its first render' do
      without_associations = Class.new(Blueprinter::Base) { field :deleted_at }
      expect(render(without_associations)).to eq(deleted_at: nil)

      Blueprinter.configure { |config| config.field_default = 'N/A' }

      expect(render(without_associations)).to eq(deleted_at: nil)
      expect(render(Class.new(without_associations))).to eq(deleted_at: 'N/A')
    end
  end

  context 'with associations' do
    let(:log) { [] }

    before do
      calls = log
      Blueprinter.configure do |config|
        config.extensions << Class.new(Blueprinter::Extension) do
          define_method(:pre_render) do |object, _blueprint, view, _options|
            calls << [object.respond_to?(:make) || object.is_a?(Array) ? :vehicles : :user, view]
            object
          end
        end.new
      end
    end

    it 'renders each association with its blueprint and view, and runs extensions for it' do
      vehicles = vehicle_blueprint
      blueprint = Class.new(Blueprinter::Base) do
        identifier :id
        association :vehicles, blueprint: vehicles
        association :vehicles, name: :detailed, blueprint: vehicles, view: :extended,
                               if: ->(_name, _user, options) { options[:detailed] }
        association(:first_vehicle, blueprint: vehicles, exclude_if_nil: true) { |user, _options| user.vehicles&.first }
      end

      expect(render(blueprint, user_class.new(id: 2))).to eq(id: 2, vehicles: nil)
      expect(render(blueprint, detailed: true)).to eq(
        id: 1,
        detailed: [{ id: 10, make: 'Super Car', miles: 5, model: 'ACME', seen_view: :extended },
                   { id: 11, make: nil, miles: nil, model: nil, seen_view: :extended }],
        first_vehicle: { id: 10, make: 'Super Car', model: 'ACME' },
        vehicles: [{ id: 10, make: 'Super Car', model: 'ACME' }, { id: 11, make: nil, model: nil }]
      )
      expect(log.last(4)).to eq([%i[user default], %i[vehicles extended], %i[vehicles default], %i[vehicles default]])
    end

    it 'reads associations with a dynamic blueprint or :options through their extractor' do
      vehicles = vehicle_blueprint
      owned = Class.new(Blueprinter::Base) { field(:owner) { |_vehicle, options| options[:owner] } }
      blueprint = Class.new(Blueprinter::Base) do
        association :vehicles, name: :dynamic, blueprint: ->(_vehicles) { vehicles }
        association :vehicles, name: :static_options, blueprint: owned, options: { owner: 'static' }
        association :vehicles, name: :dynamic_options, blueprint: owned, options: ->(user) { { owner: user.first_name } }
      end

      expect(render(blueprint, user_class.new(first_name: 'Meg', vehicles: [user.vehicles.first]))).to eq(
        dynamic: [{ id: 10, make: 'Super Car', model: 'ACME' }],
        dynamic_options: [{ owner: 'Meg' }],
        static_options: [{ owner: 'static' }]
      )
    end

    it "uses the associated blueprint's hashify, and keeps options it changes to itself" do
      wrapped = Class.new(Blueprinter::Base) do
        identifier :id
        field :make, if: ->(_name, _vehicle, options) { options[:written_by_association] = true }

        def self.hashify(object, view_name:, local_options:)
          super.map { |vehicle| vehicle.merge(wrapped: true) }
        end
      end
      blueprint = Class.new(Blueprinter::Base) do
        association :vehicles, blueprint: wrapped
        field(:written_by_association) { |_user, options| options[:written_by_association] }
      end

      expect(render(blueprint)).to eq(
        vehicles: [{ id: 10, make: 'Super Car', wrapped: true }, { id: 11, make: nil, wrapped: true }],
        written_by_association: nil
      )
    end

    it 'raises for an unknown association view only when there is a value to render' do
      vehicles = vehicle_blueprint
      broken = Class.new(Blueprinter::Base) { association :vehicles, blueprint: vehicles, view: :missing }
      nil_broken = Class.new(Blueprinter::Base) do
        association(:nothing, blueprint: vehicles, view: :missing) { |_user, _options| nil }
      end

      expect { render(broken) }.to raise_error(Blueprinter::Errors::UnknownView, "View 'missing' is not defined")
      expect(render(nil_broken)).to eq(nothing: nil)
    end
  end

  it 'runs transformers after the fields, default view first' do
    blueprint = Class.new(Blueprinter::Base) do
      identifier :id
      field :first_name
      transform(Class.new(Blueprinter::Transformer) do
        def transform(hash, object, options)
          hash[:transformed] = "#{object.id}-#{options[:view]}"
        end
      end)

      view :extended do
        field :last_name
        transform(Class.new(Blueprinter::Transformer) do
          def transform(hash, _object, _options)
            hash.delete(:first_name)
          end
        end)
      end
    end

    expect(render(blueprint)).to eq(id: 1, first_name: 'Meg', transformed: '1-default')
    expect(render(blueprint, view: :extended)).to eq(id: 1, last_name: 'Ryan', transformed: '1-extended')
  end

  it 'sorts fields by definition when configured' do
    Blueprinter.configure { |config| config.sort_fields_by = :definition }
    blueprint = Class.new(Blueprinter::Base) do
      field :last_name
      identifier :id
      field :first_name

      view :normal do
        field :company
      end

      view :extended do
        field :birthday
        include_view :normal
      end
    end

    expect(render(blueprint, view: :extended).keys).to eq(%i[id last_name first_name birthday company])
  end

  it 'keeps the first position and the last value of a name defined twice' do
    parent = Class.new(Blueprinter::Base) do
      identifier :id
      field :first_name, name: :id
      field :last_name
    end

    expect(render(Class.new(parent) { field :company }).to_a)
      .to eq([[:id, 'Meg'], [:company, 'Procore'], [:last_name, 'Ryan']])
  end
end
