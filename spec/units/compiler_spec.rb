# frozen_string_literal: true

require 'blueprinter/compiler'

describe Blueprinter::Compiler do
  let(:item_class) { Struct.new(:id, :name, :status, :child, keyword_init: true) }
  let(:item) { item_class.new(id: 1, name: 'Leak', status: 'open') }

  before do
    reset_blueprinter_config!
    Blueprinter.configuration.compile_views = true
  end
  after { reset_blueprinter_config! }

  def blueprint(&body)
    Class.new(Blueprinter::Base, &body)
  end

  def generated_code(blueprint, view = :default)
    collection = blueprint.send(:view_collection)
    described_class::Generator.new(blueprint, view, :render_x, [], collection.fields_for(view),
                                   collection.transformers(view)).code
  end

  it 'compiles a plain view into a Hash literal with direct method calls' do
    plain = blueprint do
      identifier :id
      fields :status, :name
    end

    code = generated_code(plain)

    expect(code).to include('{ id: object.id, name: object.name, status: object.status }')
    expect(code).to include('{ id: object[:id], name: object[:name], status: object[:status] }')
    expect(code).not_to include('public_send')
    expect(plain.render_as_hash(item)).to eq(id: 1, name: 'Leak', status: 'open')
  end

  it 'keeps the generated methods private' do
    plain = blueprint { identifier :id }
    plain.render_as_hash(item)

    expect(plain.singleton_methods.grep(/__bp_/)).to be_empty
    expect(plain.private_methods.grep(/__bp_render/)).not_to be_empty
  end

  it 'uses standard rendering again when compile_views is turned off' do
    plain = blueprint { identifier :id }
    plain.render_as_hash(item)
    Blueprinter.configuration.compile_views = false

    expect(described_class).not_to receive(:entry_point)
    expect(plain.render_as_hash(item)).to eq(id: 1)
  end

  it 'recompiles when a view is changed after rendering' do
    lite = blueprint do
      identifier :id
      view(:extended) { field :name }
    end
    expect(lite.render_as_hash(item, view: :extended)).to eq(id: 1, name: 'Leak')

    lite.class_eval { view(:extended) { field :status } }

    expect(lite.render_as_hash(item, view: :extended)).to eq(id: 1, name: 'Leak', status: 'open')
  end

  it 'recompiles when a compiled setting changes after rendering' do
    dated = blueprint { field :created_at }
    record = Struct.new(:created_at).new(Time.utc(2026, 1, 2))
    expect(dated.render_as_hash(record)).to eq(created_at: Time.utc(2026, 1, 2))

    Blueprinter.configure { |config| config.datetime_format = '%Y' }
    expect(dated.render_as_hash(record)).to eq(created_at: '2026')

    reset_blueprinter_config!
    Blueprinter.configuration.compile_views = true
    expect(dated.render_as_hash(record)).to eq(created_at: Time.utc(2026, 1, 2))
  end

  it 'picks up changes to the parent of an association' do
    child = blueprint { identifier :id }
    parent = blueprint do
      identifier :id
      association :child, blueprint: child
    end
    record = item_class.new(id: 1, child: item_class.new(id: 2, name: 'Child'))
    expect(parent.render_as_hash(record)).to eq(id: 1, child: { id: 2 })

    child.class_eval { view(:default) { field :name } }

    expect(parent.render_as_hash(record)).to eq(id: 1, child: { id: 2, name: 'Child' })
  end

  it 'supports blueprints that reference each other' do
    node_a = blueprint { identifier :id }
    node_b = blueprint { identifier :id }
    node_a.class_eval { view(:default) { association :child, blueprint: node_b } }
    node_b.class_eval { view(:default) { association :child, blueprint: node_a } }
    chain = item_class.new(id: 1, child: item_class.new(id: 2, child: item_class.new(id: 3)))

    expect(node_a.render_as_hash(chain)).to eq(id: 1, child: { id: 2, child: { id: 3, child: nil } })
  end

  it 'compiles safely when many threads render for the first time' do
    threaded = blueprint do
      identifier :id
      fields :name, :status
      view(:extended) { field(:upcased) { |record, _options| record.name.upcase } }
    end

    results = Array.new(16) do |i|
      Thread.new { threaded.render_as_hash([item], view: i.even? ? :default : :extended) }
    end.map(&:value)

    expect(results.uniq).to contain_exactly([{ id: 1, name: 'Leak', status: 'open' }],
                                            [{ id: 1, name: 'Leak', status: 'open', upcased: 'LEAK' }])
  end

  it 'never evaluates names or method names as code' do
    $blueprinter_compiler_injected = false
    payload = '#{$blueprinter_compiler_injected = true}"); $blueprinter_compiler_injected = true; ("'
    target = Struct.new(:id) do
      define_method(payload) { 'value' }
    end
    unusual = blueprint do
      identifier :id, name: payload.to_sym
      field payload.to_sym
    end

    expect(unusual.render_as_hash(target.new(1))).to eq(payload.to_sym => 'value')
    expect($blueprinter_compiler_injected).to be(false)
  end

  it 'does not print method redefinition warnings when recompiling' do
    plain = blueprint { identifier :id }
    original_verbose = $VERBOSE
    $VERBOSE = true

    expect do
      plain.render_as_hash(item)
      Blueprinter.configure { |config| config.field_default = 'x' }
      plain.render_as_hash(item)
    end.not_to output.to_stderr
  ensure
    $VERBOSE = original_verbose
  end
end
