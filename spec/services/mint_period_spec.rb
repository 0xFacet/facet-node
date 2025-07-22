require 'rails_helper'

RSpec.describe MintPeriod do
  describe '#compute_and_cap_rate' do
    let(:instance) do
      described_class.new(
        block_num: 1000,
        fct_mint_rate: 100,
        total_minted: 0,
        period_minted: 0,
        period_start_block: 1000
      )
    end

    it 'caps values above MAX_MINT_RATE' do
      huge_rate = FctMintCalculator::MAX_MINT_RATE + 1000
      adjustment_factor = 2.to_r
      
      capped = instance.send(:compute_and_cap_rate, huge_rate, adjustment_factor)
      expect(capped).to eq(FctMintCalculator::MAX_MINT_RATE)
    end

    it 'caps values below MIN_MINT_RATE' do
      tiny_rate = 10.to_r
      adjustment_factor = Rational(1, 100_000) # Very small adjustment
      
      capped = instance.send(:compute_and_cap_rate, tiny_rate, adjustment_factor)
      expect(capped).to eq(FctMintCalculator::MIN_MINT_RATE)
    end

    it 'returns unchanged value when within bounds' do
      normal_rate = 1000.to_r
      adjustment_factor = Rational(3, 2) # 1.5x
      
      result = instance.send(:compute_and_cap_rate, normal_rate, adjustment_factor)
      expect(result).to eq(1500.to_r)
    end
  end
end