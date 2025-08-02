require 'rails_helper'

RSpec.describe FctMintCalculator do
  let(:client) { instance_double('GethClient') }
  
  before do
    allow(FctMintCalculator).to receive(:client).and_return(client)
    # Default stub to prevent nil errors
    allow(client).to receive(:get_l1_attributes).and_return(nil)
  end

  describe '.calculate_historical_total' do
    it 'sums two complete periods and a partial period' do
      original_period_length = FctMintCalculator::ORIGINAL_ADJUSTMENT_PERIOD_TARGET_LENGTH.to_i
      
      # Period 1: blocks 0-9999
      allow(client).to receive(:get_l1_attributes).with(original_period_length - 1).and_return({
        fct_mint_period_l1_data_gas: 50_000,
        fct_mint_rate: 2
      })
      
      # Period 2: blocks 10000-19999  
      allow(client).to receive(:get_l1_attributes).with(original_period_length * 2 - 1).and_return({
        fct_mint_period_l1_data_gas: 60_000,
        fct_mint_rate: 3
      })
      
      # Partial period: blocks 20000-24999
      allow(client).to receive(:get_l1_attributes).with(original_period_length * 2.5 - 1).and_return({
        fct_mint_period_l1_data_gas: 20_000,
        fct_mint_rate: 4
      })
      
      total = described_class.calculate_historical_total((original_period_length * 2.5).to_i)
      expect(total).to eq(50_000 * 2 + 60_000 * 3 + 20_000 * 4) # 360,000
    end

    it 'handles missing attributes gracefully' do
      original_period_length = FctMintCalculator::ORIGINAL_ADJUSTMENT_PERIOD_TARGET_LENGTH.to_i
      
      allow(client).to receive(:get_l1_attributes).with(original_period_length - 1).and_return({
        fct_mint_period_l1_data_gas: 50_000,
        fct_mint_rate: 2
      })
      
      # Second period returns nil (already stubbed as default)
      
      allow(client).to receive(:get_l1_attributes).with(original_period_length * 2.5 - 1).and_return({
        fct_mint_period_l1_data_gas: 20_000,
        fct_mint_rate: 4
      })
      
      total = described_class.calculate_historical_total((original_period_length * 2.5).to_i)
      expect(total).to eq(50_000 * 2 + 20_000 * 4) # 180,000
    end

    it 'returns correct total when fork is exactly on period boundary' do
      original_period_length = FctMintCalculator::ORIGINAL_ADJUSTMENT_PERIOD_TARGET_LENGTH.to_i
      
      # Fork at block 20,000 - exactly 2 complete periods
      allow(client).to receive(:get_l1_attributes).with(original_period_length - 1).and_return({
        fct_mint_period_l1_data_gas: 50_000,
        fct_mint_rate: 2
      })
      
      allow(client).to receive(:get_l1_attributes).with(original_period_length * 2 - 1).and_return({
        fct_mint_period_l1_data_gas: 60_000,
        fct_mint_rate: 3
      })
      
      total = described_class.calculate_historical_total(original_period_length * 2)
      expect(total).to eq(50_000 * 2 + 60_000 * 3) # 280,000
    end
  end

  describe 'fork block parameter computation' do
    it 'has the correct max_supply constant' do
      expect(described_class.max_supply).to eq(1_500_000_000.ether)
    end
    
    it 'has the correct idealized_initial_target_per_period constant' do
      expect(described_class.idealized_initial_target_per_period).to be > 0
      expect(described_class.idealized_initial_target_per_period).to be < described_class.max_supply
    end
    
    it 'computes target per period at bluebird fork correctly' do
      # Test with some example values
      total_minted = 140_000_000.ether
      current_block = 1_000_000
      
      target = described_class.compute_target_per_period_at_bluebird_fork(total_minted, current_block)
      
      # Should return a reasonable positive value
      expect(target).to be > 0
      expect(target).to be < described_class.max_supply / 10 # Less than 10% of max supply per period
    end
  end

  describe '.issuance_on_pace_delta' do
    # Note: This method now uses the fixed max_supply constant

    it 'returns positive delta when ahead of schedule' do
      # At block 1M out of 2.628M, we should have minted ~285M to be on schedule
      # Setting 400M means we're ahead
      allow(client).to receive(:get_l1_attributes).with(1_000_000).and_return({
        fct_total_minted: 400_000_000.ether
      })
      
      delta = described_class.issuance_on_pace_delta(1_000_000)
      expect(delta).to be > 0
    end

    it 'returns negative delta when behind schedule' do
      # At block 1M out of 2.628M, we should have minted ~285M to be on schedule
      # Setting 100M means we're behind
      allow(client).to receive(:get_l1_attributes).with(1_000_000).and_return({
        fct_total_minted: 100_000_000.ether
      })
      
      delta = described_class.issuance_on_pace_delta(1_000_000)
      expect(delta).to be < 0
    end

    it 'uses zero when attrs missing' do
      # nil already stubbed as default, which means no l1_attributes
      # This should use 0 as the total_minted
      
      delta = described_class.issuance_on_pace_delta(1_000_000)
      expect(delta).to eq(-1.0) # Completely behind schedule
    end

    it 'raises when block_number is 0' do
      expect {
        described_class.issuance_on_pace_delta(0)
      }.to raise_error(/Time fraction is zero/)
    end
  end
end