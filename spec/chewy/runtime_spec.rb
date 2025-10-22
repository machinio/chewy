require 'spec_helper'

describe Chewy::Runtime do
  describe '.version' do
    specify { expect(described_class.version).to be_a(described_class::Version) }
  end
end
