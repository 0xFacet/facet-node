require 'rails_helper'

RSpec.describe FctMintCalculator do
  let(:client) { instance_double('GethClient') }
  
  before do
    allow(FctMintCalculator).to receive(:client).and_return(client)
    # Default stub to prevent nil errors
    allow(client).to receive(:get_l1_attributes).and_return(nil)
  end


  describe '.max_supply' do
    it 'returns fixed 1.5 billion ether' do
      expect(described_class.max_supply).to eq(1_500_000_000.ether)
    end
  end
  
  describe '.compute_target_per_period_at_bluebird_fork' do
    it 'calculates correct target from bluebird fork' do
      # At bluebird fork with historical amount minted
      # Using a fork block that's within the first halving period
      already_minted = 195_000_000.ether
      fork_block = 1_000_000  # Within first halving period
      
      target = described_class.compute_target_per_period_at_bluebird_fork(already_minted, fork_block)
      
      # Should calculate based on remaining supply and remaining time
      expect(target).to be > 0
      expect(target).to be_a(Integer)
    end
    
    it 'returns 0 when past first halving block' do
      # Past the first halving block
      already_minted = 195_000_000.ether
      fork_block = 5_760_000  # Well past first halving
      
      target = described_class.compute_target_per_period_at_bluebird_fork(already_minted, fork_block)
      
      expect(target).to eq(0)
    end
  end

  describe '.idealized_initial_target_per_period' do
    it 'calculates idealized target for first halving' do
      target = described_class.idealized_initial_target_per_period
      
      expected_periods = FctMintCalculator::TARGET_NUM_BLOCKS_IN_HALVING / FctMintCalculator::ADJUSTMENT_PERIOD_TARGET_LENGTH
      expected_initial_target = (described_class.max_supply / 2) / expected_periods
      
      expect(target).to eq(expected_initial_target.to_i)
    end
  end

  describe '.get_halving_level' do
    it 'returns 0 when nothing minted' do
      expect(described_class.get_halving_level(0)).to eq(0)
    end

    it 'returns 0 when less than half minted' do
      expect(described_class.get_halving_level(700_000_000.ether)).to eq(0)
    end

    it 'returns 1 when more than half but less than 3/4 minted' do
      expect(described_class.get_halving_level(800_000_000.ether)).to eq(1)
    end

    it 'returns correct level for higher halvings' do
      # At exactly 75%, we're still in level 1 (need to be > 75% for level 2)
      expect(described_class.get_halving_level(1_125_000_000.ether)).to eq(1) # 75%
      expect(described_class.get_halving_level(1_125_000_001.ether)).to eq(2) # Just over 75%
      expect(described_class.get_halving_level(1_312_500_000.ether)).to eq(2) # 87.5%
      expect(described_class.get_halving_level(1_312_500_001.ether)).to eq(3) # Just over 87.5%
      expect(described_class.get_halving_level(1_400_000_000.ether)).to eq(3) # 93.33%
    end

    it 'returns 0 when at max supply' do
      expect(described_class.get_halving_level(described_class.max_supply)).to eq(0)
    end
  end

  describe '.issuance_on_pace_delta' do
    it 'returns positive delta when ahead of schedule' do
      # At block 1M, we should have minted about 285M tokens (1M/2.628M * 750M)
      # If we've minted 350M, we're ahead of schedule
      allow(client).to receive(:get_l1_attributes).with(1_000_000).and_return({
        fct_total_minted: 350_000_000.ether
      })
      
      delta = described_class.issuance_on_pace_delta(1_000_000)
      expect(delta).to be > 0
    end

    it 'returns negative delta when behind schedule' do
      # At block 1M, we should have minted about 285M tokens
      # If we've only minted 200M, we're behind schedule
      allow(client).to receive(:get_l1_attributes).with(1_000_000).and_return({
        fct_total_minted: 200_000_000.ether
      })
      
      delta = described_class.issuance_on_pace_delta(1_000_000)
      expect(delta).to be < 0
    end

    it 'raises when block_number is 0' do
      expect {
        described_class.issuance_on_pace_delta(0)
      }.to raise_error(/Time fraction is zero/)
    end
  end
end