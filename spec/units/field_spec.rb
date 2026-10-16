# frozen_string_literal: true

require 'blueprinter/field'

describe Blueprinter::Field do
  describe '#extract' do
    let(:blueprint) { Class.new(Blueprinter::Base) }
    let(:extractor) { Blueprinter::AutoExtractor.new }
    let(:object) { Struct.new(:name, :created_at).new('Meg', Time.utc(2024, 1, 2, 3, 4, 5)) }
    let(:field) { described_class.new(:name, :name, extractor, blueprint, { block: nil }) }

    after { reset_blueprinter_config! }

    it 'reads the value from an object without going through the extractor' do
      expect(extractor).not_to receive(:extract)

      expect(field.extract(object, {})).to eq('Meg')
    end

    it 'reads the value from a Hash' do
      expect(field.extract({ name: 'Meg' }, {})).to eq('Meg')
    end

    it 'uses the global field_default set after the field was defined' do
      field
      Blueprinter.configure { |config| config.field_default = 'N/A' }

      expect(field.extract({}, {})).to eq('N/A')
    end

    it 'uses the global datetime_format set after the field was defined' do
      date_field = described_class.new(:created_at, :created_at, extractor, blueprint, { block: nil })
      Blueprinter.configure { |config| config.datetime_format = '%Y-%m-%d' }

      expect(date_field.extract(object, {})).to eq('2024-01-02')
    end

    it 'raises for an invalid global datetime_format' do
      date_field = described_class.new(:created_at, :created_at, extractor, blueprint, { block: nil })
      Blueprinter.configure { |config| config.datetime_format = 123 }

      expect { date_field.extract(object, {}) }.to raise_error(Blueprinter::DateTimeFormatter::InvalidDateTimeFormatterError)
    end

    it 'keeps an explicit default: nil over the global field_default' do
      nil_default_field = described_class.new(:name, :name, extractor, blueprint, { block: nil, default: nil })
      Blueprinter.configure { |config| config.field_default = 'N/A' }

      expect(nil_default_field.extract({}, {})).to be_nil
    end

    [
      { block: proc { |obj, _options| obj.created_at } },
      { block: nil, datetime_format: '%Y' },
      { block: nil, default: 'none' },
      { block: nil, default_if: Blueprinter::EMPTY_STRING }
    ].each do |options|
      it "delegates to the extractor when the field has #{options.keys.last}" do
        custom_field = described_class.new(:created_at, :created_at, extractor, blueprint, options)
        expect(extractor).to receive(:extract).and_call_original

        custom_field.extract(object, {})
      end
    end

    it 'delegates to subclasses of AutoExtractor' do
      subclass_extractor = Class.new(Blueprinter::AutoExtractor).new
      custom_field = described_class.new(:name, :name, subclass_extractor, blueprint, { block: nil })
      expect(subclass_extractor).to receive(:extract).and_call_original

      expect(custom_field.extract(object, {})).to eq('Meg')
    end
  end
end
