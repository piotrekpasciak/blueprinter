# frozen_string_literal: true

require 'blueprinter/field'

describe Blueprinter::Field do
  describe '#skip?' do
    let(:blueprint) { Class.new(Blueprinter::Base) }
    let(:object) { Object.new }

    context 'when no :if or :unless callable is configured' do
      let(:field) { described_class.new(:name, :name, nil, blueprint) }

      it 'does not skip the field' do
        expect(field.skip?(:name, object, {})).to be(false)
      end

      it 'resolves the callables only once across calls' do
        expect(field).to receive(:callable_from).with(:if).once.and_call_original
        expect(field).to receive(:callable_from).with(:unless).once.and_call_original

        3.times { field.skip?(:name, object, {}) }
      end
    end

    context 'when :if and :unless callables are configured' do
      let(:field) do
        described_class.new(:name, :name, nil, blueprint, if: ->(*) { true }, unless: ->(*) { false })
      end

      it 'resolves the callables only once across calls' do
        expect(field).to receive(:callable_from).with(:if).once.and_call_original
        expect(field).to receive(:callable_from).with(:unless).once.and_call_original

        3.times { expect(field.skip?(:name, object, {})).to be(false) }
      end
    end
  end
end
