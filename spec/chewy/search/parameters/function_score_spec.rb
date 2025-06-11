require 'chewy/search/parameters/hash_storage_examples'

describe Chewy::Search::Parameters::FunctionScore do
  subject { described_class.new(query: {match_all: {}}) }

  describe '#initialize' do
    specify { expect(described_class.new.value).to eq({}) }
    specify { expect(described_class.new(nil).value).to eq({}) }
    specify { expect(subject.value).to eq(query: {match_all: {}}) }
  end

  describe '#update!' do
    specify { expect(subject.update!(max_boost: 42)).to eq(query: {match_all: {}}, max_boost: 42) }
    specify do
      expect(subject.update!(functions: [{foo: 'bar'}]))
        .to eq(query: {match_all: {}}, functions: [{foo: 'bar'}])
    end

    specify do
      subject.update!(functions: [{foo: 'bar'}])

      expect(subject.update!(functions: [{foo: 'baz'}]))
        .to eq(query: {match_all: {}}, functions: [{foo: 'bar'}, {foo: 'baz'}])
    end
  end

  describe '#render' do
    specify { expect(described_class.new.render).to be_nil }
    specify { expect(described_class.new(max_boost: 42).render).to eq(query: {function_score: {max_boost: 42}}) }
  end
end
