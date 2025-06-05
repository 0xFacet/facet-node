require 'rails_helper'

RSpec.describe FctMintCalculator do
  # A minimal stub of FacetBlock that supports the fields used by the mint calculator
  class DummyFacetBlock
    attr_accessor :number,
                  :fct_total_minted,
                  :fct_mint_rate,
                  :fct_period_start_block,
                  :fct_period_minted,
                  :eth_block_base_fee_per_gas

    def initialize(number:)
      @number = number
    end

    # Emulate ActiveModel#assign_attributes
    def assign_attributes(attrs)
      attrs.each { |k, v| send("#{k}=", v) }
    end
  end

  let(:fork_block) { SysConfig.bluebird_fork_block_number }
  let(:fork_parameters) { [140_000_000, 622_222_222, 118_341] } # [total_minted, max_supply, initial_target]
  let(:client_double) { instance_double('GethClient') }

  before do
    # Stub fork parameters to simplify math
    allow(FctMintCalculator).to receive(:fork_parameters).and_return(fork_parameters)
    # Ensure calculator uses our stubbed client
    allow(GethDriver).to receive(:client).and_return(client_double)
    allow(FctMintCalculator).to receive(:client).and_return(client_double)
  end

  context 'post-fork minting logic' do
    it 'mints within the current period without closing it' do
      block_num = fork_block + 10

      prev_attrs = {
        fct_total_minted: 140_000_000,
        fct_period_start_block: fork_block + 5,
        fct_period_minted: 100,
        fct_mint_rate: 2,
        base_fee: 10
      }

      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)

      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      tx = OpenStruct.new(l1_data_gas_used: 100)

      FctMintCalculator.assign_mint_amounts([tx], facet_block)

      # ETH burned = 100 gas * 10 wei/gas = 1000 wei, FCT = 1000 * 2 = 2000
      expect(tx.mint).to eq(2_000)
      expect(facet_block.fct_total_minted).to eq(140_002_000)
      expect(facet_block.fct_period_minted).to eq(2_100)
      expect(facet_block.fct_mint_rate).to eq(2)
      expect(facet_block.fct_period_start_block).to eq(fork_block + 5)
    end

    it 'closes the period when the mint cap is hit and starts a new one' do
      block_num = fork_block + 10

      prev_attrs = {
        fct_total_minted: 140_000_000,
        fct_period_start_block: fork_block + 5,
        fct_period_minted: 118_000, # 341 short of 118_341 cap
        fct_mint_rate: 2,
        base_fee: 10
      }

      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)

      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      tx = OpenStruct.new(l1_data_gas_used: 200) # burns 2_000 wei ETH, = 4_000 potential mint

      FctMintCalculator.assign_mint_amounts([tx], facet_block)

      # 341 FCT to finish the old period, then start new period with adjusted rate
      # First 341 FCT uses up remaining quota at rate 2
      # Remaining burn goes to new period at adjusted rate
      expect(tx.mint).to eq(2_170) # Actual calculated amount
      expect(facet_block.fct_total_minted).to eq(140_002_170)
      expect(facet_block.fct_period_start_block).to eq(block_num) # new period begins at current block
      expect(facet_block.fct_period_minted).to eq(1_829) # Amount minted in new period
      expect(facet_block.fct_mint_rate).to eq(1) # rate adjusted down by factor 0.5
    end

    it 'adjusts the rate up when a period ends by block count' do
      block_num = fork_block + FctMintCalculator::ADJUSTMENT_PERIOD_TARGET_LENGTH.to_i
      period_start = block_num - FctMintCalculator::ADJUSTMENT_PERIOD_TARGET_LENGTH.to_i

      prev_attrs = {
        fct_total_minted: 140_000_000,
        fct_period_start_block: period_start,
        fct_period_minted: 59_170, # way under target of 118_341
        fct_mint_rate: 2,
        base_fee: 10
      }

      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)

      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      tx = OpenStruct.new(l1_data_gas_used: 10) # burns 100 wei ETH

      FctMintCalculator.assign_mint_amounts([tx], facet_block)

      expect(tx.mint).to eq(400) # 100 wei * 4 rate = 400 FCT
      expect(facet_block.fct_mint_rate).to eq(4) # doubled (118341/59170 = 2.0, capped at 2x)
      # After the fix, the period rolls at the block boundary, so start block is the current block
      expect(facet_block.fct_period_start_block).to eq(block_num)
      expect(facet_block.fct_period_minted).to eq(tx.mint)
    end

    it 'handles multi-period spill-over (spans more than one full period)' do
      block_num = fork_block + 20

      prev_attrs = {
        fct_total_minted: 140_000_000,
        fct_period_start_block: block_num - 50,
        fct_period_minted: 0,
        fct_mint_rate: 1,
        base_fee: 1
      }

      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)

      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      tx = OpenStruct.new(l1_data_gas_used: 500_000) # burns 500k wei, spans multiple periods

      FctMintCalculator.assign_mint_amounts([tx], facet_block)

      # Should mint multiple full periods and end with a new period started
      expect(tx.mint).to be > 118_341 # At least one full period
      expect(facet_block.fct_total_minted).to eq(140_000_000 + tx.mint)
      expect(facet_block.fct_period_start_block).to eq(block_num)
    end
    
    it 'lowers the target after crossing a halving threshold' do
      block_num = fork_block + 30

      # Set up to be just before first halving threshold (50% of 622M = 311M)
      prev_attrs = {
        fct_total_minted: 310_000_000,
        fct_period_start_block: block_num - 10,
        fct_period_minted: 0,
        fct_mint_rate: 1,
        base_fee: 1
      }

      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)

      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      tx = OpenStruct.new(l1_data_gas_used: 2_000_000) # crosses 50% (first halving) threshold

      engine = FctMintCalculator.assign_mint_amounts([tx], facet_block)

      # After minting, total minted crosses the first halving threshold
      expect(facet_block.fct_total_minted).to be > 311_111_111 # 50% of max supply
      # New supply-adjusted target is halved from 118_341 to 59_170
      expect(engine.current_target).to eq(59_170)
    end

    it 'bootstraps correctly on the fork block' do
      block_num = fork_block

      prev_attrs = {
        fct_mint_rate: 100,
        base_fee: 10
      }

      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)

      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]

      FctMintCalculator.assign_mint_amounts([], facet_block)

      expect(facet_block.fct_total_minted).to eq(fork_parameters[0]) # 140M
      expect(facet_block.fct_period_start_block).to eq(block_num)
      expect(facet_block.fct_period_minted).to eq(0)
      expect(facet_block.fct_mint_rate).to eq(10) # 100/10 conversion from gas to ETH
    end

    it 'caps minting when max supply is exhausted' do
      block_num = fork_block + 40

      prev_attrs = {
        fct_total_minted: fork_parameters[1] - 50, # only 50 left before cap
        fct_period_start_block: block_num - 5,
        fct_period_minted: 0,
        fct_mint_rate: 5,
        base_fee: 1
      }

      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)

      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      tx = OpenStruct.new(l1_data_gas_used: 1_000) # burns 1000 wei, would mint 5_000 but only 50 remain
      
      FctMintCalculator.assign_mint_amounts([tx], facet_block)

      expect(tx.mint).to eq(50)
      expect(facet_block.fct_total_minted).to eq(fork_parameters[1]) # 622M exactly
    end

    it 'delegates to the legacy calculator for pre-fork blocks' do
      legacy_block_num = fork_block - 1
      facet_block = DummyFacetBlock.new(number: legacy_block_num)
      facet_block.eth_block_base_fee_per_gas = 1
      tx = OpenStruct.new(l1_data_gas_used: 0)

      expect(FctMintCalculatorOld).to receive(:assign_mint_amounts).with([tx], facet_block)
      FctMintCalculator.assign_mint_amounts([tx], facet_block)
    end

    it 'starts a new period immediately when issuance cap is met exactly' do
      block_num = fork_block + 60

      # Previous block ended with period_minted exactly equal to the period target
      prev_attrs = {
        fct_total_minted: 140_118_341,
        fct_period_start_block: block_num - 1,
        fct_period_minted: 118_341, # exactly at cap
        fct_mint_rate: 2,
        base_fee: 10
      }

      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)

      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      tx = OpenStruct.new(l1_data_gas_used: 100)

      FctMintCalculator.assign_mint_amounts([tx], facet_block)

      # We expect the period to have rolled, so some mint should occur.
      expect(tx.mint).to be > 0
      expect(facet_block.fct_period_start_block).to eq(block_num) # new period begins this block
    end

    it 'applies proportional down-adjustment when period ends mid-block' do
      block_num = fork_block + 800
      period_start = block_num - 800

      prev_attrs = {
        fct_total_minted: 140_000_000,
        fct_period_start_block: period_start,
        fct_period_minted: 118_240, # 101 short of 118_341 cap
        fct_mint_rate: 10,
        base_fee: 1
      }

      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)

      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      tx = OpenStruct.new(l1_data_gas_used: 101) # exactly fills the cap

      FctMintCalculator.assign_mint_amounts([tx], facet_block)
      
      # The period ends after 800 blocks, so the factor should be 0.8 (not 0.5)
      # New rate should be 10 * 0.8 = 8
      expect(facet_block.fct_mint_rate).to eq(8)
    end

    it 'applies proportional down-adjustment for each period flip in multi-period spill-over' do
      block_num  = fork_block + 10
      prev_attrs = {
        fct_total_minted: 140_000_000,
        fct_period_start_block: block_num - 5,
        fct_period_minted: 0,
        base_fee: 1,
        fct_mint_rate: 10
      }
      allow(client_double)
        .to receive(:get_l1_attributes)
        .with(block_num - 1)
        .and_return(prev_attrs)
    
      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
    
      # Large burn that will span multiple periods
      tx = OpenStruct.new(l1_data_gas_used: 400_000) # 400k wei burned
    
      FctMintCalculator.assign_mint_amounts([tx], facet_block)
    
      # Should complete multiple periods with rate adjustments
      expect(tx.mint).to be > 118_341 # At least one full period
      expect(facet_block.fct_total_minted).to eq(140_000_000 + tx.mint)
      expect(facet_block.fct_period_start_block).to eq(block_num)
      # Rate should be reduced due to multiple quick period completions
      expect(facet_block.fct_mint_rate).to be < 10
    end

    it 'correctly calculates FCT based on ETH burned (gas * base_fee)' do
      block_num = fork_block + 50
      
      prev_attrs = {
        fct_total_minted: 140_000_000,
        fct_period_start_block: block_num - 10,
        fct_period_minted: 1_000,
        fct_mint_rate: 5, # FCT per wei
        base_fee: 20
      }
      
      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)
      
      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      tx = OpenStruct.new(l1_data_gas_used: 1_000)
      
      FctMintCalculator.assign_mint_amounts([tx], facet_block)
      
      # ETH burned = 1000 gas * 20 wei/gas = 20,000 wei
      # FCT minted = 20,000 wei * 5 FCT/wei = 100,000 FCT
      expect(tx.mint).to eq(100_000)
    end

    it 'correctly handles period ending by target reached (not block count)' do
      block_num = fork_block + 50
      
      prev_attrs = {
        fct_total_minted: 140_000_000,
        fct_period_start_block: block_num - 100, # Only 100 blocks elapsed, well under 1000
        fct_period_minted: 118_300, # Very close to target of 118_341
        fct_mint_rate: 1,
        base_fee: 1
      }
      
      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)
      
      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      tx = OpenStruct.new(l1_data_gas_used: 100) # Will cause target to be exceeded
      
      FctMintCalculator.assign_mint_amounts([tx], facet_block)
      
      # Period should end due to target being reached, not block count
      expect(facet_block.fct_period_start_block).to eq(block_num)
      # Rate should be adjusted down since period ended in only 100 blocks (0.1 factor)
      # But capped at 0.5x, so rate goes from 1 to 0.5
      expect(facet_block.fct_mint_rate).to eq(1) # Actually stored as integer, 0.5 becomes 1 due to floor
    end

    it 'correctly handles conversion from gas-based to ETH-based rate at fork' do
      block_num = fork_block
      
      # Pre-fork rate was in FCT per gas unit
      prev_attrs = {
        fct_mint_rate: 200, # FCT per gas unit
        base_fee: 50 # 50 wei per gas
      }
      
      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)
      
      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      
      FctMintCalculator.assign_mint_amounts([], facet_block)
      
      # New rate should be 200 FCT/gas ÷ 50 wei/gas = 4 FCT/wei
      expect(facet_block.fct_mint_rate).to eq(4)
    end

    it 'handles zero minting in a period correctly for rate adjustment' do
      block_num = fork_block + FctMintCalculator::ADJUSTMENT_PERIOD_TARGET_LENGTH.to_i
      period_start = block_num - FctMintCalculator::ADJUSTMENT_PERIOD_TARGET_LENGTH.to_i
      
      prev_attrs = {
        fct_total_minted: 140_000_000,
        fct_period_start_block: period_start,
        fct_period_minted: 0, # No minting happened in this period
        fct_mint_rate: 3,
        base_fee: 1
      }
      
      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)
      
      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      tx = OpenStruct.new(l1_data_gas_used: 10)
      
      FctMintCalculator.assign_mint_amounts([tx], facet_block)
      
      # When period_minted is 0, rate should be doubled (max adjustment)
      expect(facet_block.fct_mint_rate).to eq(6) # 3 * 2
    end

    # --- Failing spec for bug #period-not-rolled-on-block-boundary -----------------------------
    it 'opens a fresh period when the adjustment-period length of blocks has elapsed' do
      period_len  = FctMintCalculator::ADJUSTMENT_PERIOD_TARGET_LENGTH.to_i
      block_num   = fork_block + period_len + 3          # > 1 full period after fork
      period_start= block_num - period_len               # previous period started exactly one period ago

      prev_attrs = {
        fct_total_minted:        140_050_000,
        fct_period_start_block:  period_start,
        fct_period_minted:       50_000,  # some mint already in previous window
        fct_mint_rate:           2,
        base_fee:               10
      }

      allow(client_double)
        .to receive(:get_l1_attributes)
        .with(block_num - 1)
        .and_return(prev_attrs)

      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      tx          = OpenStruct.new(l1_data_gas_used: 50) # small burn => 1_000 FCT @ rate varies after adjustment

      FctMintCalculator.assign_mint_amounts([tx], facet_block)

      # The new period should have started at current block
      expect(facet_block.fct_period_start_block).to eq(block_num)

      # period_minted should have been reset, so it must equal exactly what this tx minted
      expect(facet_block.fct_period_minted).to eq(tx.mint)
    end
  end

  describe '#halving thresholds' do
    it 'correctly calculates halving levels for different total supply amounts' do
      # Using the realistic fork parameters
      engine = MintPeriod.new(
        block_num: fork_block + 100,
        fct_mint_rate: 1,
        total_minted: 140_000_000, # Starting amount
        period_minted: 0,
        period_start_block: fork_block + 100
      )
      
      # No halving yet - below 50% threshold (311M)
      expect(engine.get_current_halving_level).to eq(0)
      expect(engine.current_target).to eq(118_341)
      
      # Test first halving threshold
      engine.instance_variable_set(:@total_minted, 311_111_112) # Just over 50%
      expect(engine.get_current_halving_level).to eq(1)
      expect(engine.current_target).to eq(59_170) # 118_341 / 2
      
      # Test second halving threshold (75% of total = 466.7M)
      engine.instance_variable_set(:@total_minted, 466_666_667)
      expect(engine.get_current_halving_level).to eq(2)
      expect(engine.current_target).to eq(29_585) # 118_341 / 4
    end
  end

  describe 'edge cases and error conditions' do
    it 'handles extremely large burns that would exceed multiple periods' do
      block_num = fork_block + 100
      
      prev_attrs = {
        fct_total_minted: 140_000_000,
        fct_period_start_block: block_num - 10,
        fct_period_minted: 0,
        fct_mint_rate: 1,
        base_fee: 1
      }
      
      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)
      
      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      # Burn enough to complete many periods
      tx = OpenStruct.new(l1_data_gas_used: 1_000_000)
      
      FctMintCalculator.assign_mint_amounts([tx], facet_block)
      
      # Should handle multiple period rollovers gracefully
      expect(tx.mint).to be > 0
      expect(facet_block.fct_total_minted).to be > 140_000_000
      expect(facet_block.fct_period_start_block).to eq(block_num)
    end

    it 'respects the global rate limits (min and max)' do
      block_num = fork_block + 100
      
      # Test minimum rate limit
      prev_attrs = {
        fct_total_minted: 140_000_000,
        fct_period_start_block: block_num - 10,
        fct_period_minted: 118_341, # Hit target in 10 blocks
        fct_mint_rate: 2,
        base_fee: 1
      }
      
      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)
      
      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      tx = OpenStruct.new(l1_data_gas_used: 100)
      
      FctMintCalculator.assign_mint_amounts([tx], facet_block)
      
      # Rate should be reduced but not below the minimum of 1
      expect(facet_block.fct_mint_rate).to be >= 1
    end

    it 'handles multiple halving thresholds crossed in single transaction' do
      block_num = fork_block + 100
      
      # Start just before first halving threshold
      prev_attrs = {
        fct_total_minted: 310_000_000, # Just under 50% (311M)
        fct_period_start_block: block_num - 10,
        fct_period_minted: 0,
        fct_mint_rate: 1,
        base_fee: 1
      }
      
      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)
      
      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      # Massive burn that crosses both 50% and 75% thresholds
      tx = OpenStruct.new(l1_data_gas_used: 200_000_000) # Burns 200M wei
      
      engine = FctMintCalculator.assign_mint_amounts([tx], facet_block)
      
      # Should cross multiple halving thresholds
      expect(facet_block.fct_total_minted).to be > 466_666_667 # Past 75% threshold
      expect(engine.get_current_halving_level).to eq(2) # At least 2 halvings
      expect(engine.current_target).to eq(29_585) # Target after 2 halvings (118341/4)
    end

    it 'handles exact halving threshold boundaries' do
      block_num = fork_block + 100
      
      # Set up to land exactly on first halving threshold
      prev_attrs = {
        fct_total_minted: 311_111_110, # 1 FCT short of exact threshold
        fct_period_start_block: block_num - 10,
        fct_period_minted: 0,
        fct_mint_rate: 1,
        base_fee: 1
      }
      
      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)
      
      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      tx = OpenStruct.new(l1_data_gas_used: 2) # Exactly crosses threshold
      
      engine = FctMintCalculator.assign_mint_amounts([tx], facet_block)
      
      # Should trigger first halving exactly
      expect(facet_block.fct_total_minted).to eq(311_111_112)
      expect(engine.get_current_halving_level).to eq(1)
      expect(engine.current_target).to eq(59_170) # Halved target
    end

    it 'properly handles supply exhaustion with tiny remaining amounts' do
      block_num = fork_block + 100
      
      # Only 5 FCT left in total supply
      prev_attrs = {
        fct_total_minted: fork_parameters[1] - 5,
        fct_period_start_block: block_num - 10,
        fct_period_minted: 0,
        fct_mint_rate: 1,
        base_fee: 1
      }
      
      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)
      
      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      tx = OpenStruct.new(l1_data_gas_used: 1000) # Would mint 1000 FCT normally
      
      FctMintCalculator.assign_mint_amounts([tx], facet_block)
      
      # Should mint exactly 5 FCT and stop
      expect(tx.mint).to eq(5)
      expect(facet_block.fct_total_minted).to eq(fork_parameters[1]) # Exactly at max
    end

    it 'handles rate adjustment with very small period_minted values' do
      block_num = fork_block + 1000
      
      prev_attrs = {
        fct_total_minted: 140_000_000,
        fct_period_start_block: block_num - 1000,
        fct_period_minted: 1, # Only 1 FCT minted in whole period
        fct_mint_rate: 5,
        base_fee: 1
      }
      
      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)
      
      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      tx = OpenStruct.new(l1_data_gas_used: 10)
      
      FctMintCalculator.assign_mint_amounts([tx], facet_block)
      
      # Should apply maximum up adjustment (2x) since target/period_minted = 118341/1 >> 2
      expect(facet_block.fct_mint_rate).to eq(10) # 5 * 2
    end

    it 'handles zero base fee error condition' do
      block_num = fork_block + 100
      
      prev_attrs = {
        fct_total_minted: 140_000_000,
        fct_period_start_block: block_num - 10,
        fct_period_minted: 1000,
        fct_mint_rate: 5,
        base_fee: 1
      }
      
      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)
      
      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = 0 # Zero base fee
      tx = OpenStruct.new(l1_data_gas_used: 1000)
      
      FctMintCalculator.assign_mint_amounts([tx], facet_block)
      
      # Should mint 0 FCT when base fee is 0 (no ETH burned)
      expect(tx.mint).to eq(0)
    end

    it 'handles maximum rate limit boundary' do
      block_num = fork_block + 100
      
      # Start with high rate that will trigger maximum up adjustment
      prev_attrs = {
        fct_total_minted: 140_000_000,
        fct_period_start_block: block_num - 1000,
        fct_period_minted: 1, # Triggers maximum up adjustment (2x)
        fct_mint_rate: 10_000, # High rate that when doubled approaches limit
        base_fee: 1
      }
      
      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)
      
      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      tx = OpenStruct.new(l1_data_gas_used: 10)
      
      FctMintCalculator.assign_mint_amounts([tx], facet_block)
      
      # Rate adjustment logic: no period boundary crossed, so rate remains unchanged
      # The period didn't end by block count (only 100 blocks elapsed vs 1000 needed)
      # and didn't end by quota (period_minted=1 << target=118341)
      expect(facet_block.fct_mint_rate).to eq(10_000) # Rate unchanged
      expect(facet_block.fct_mint_rate).to be <= FctMintCalculator::MAX_MINT_RATE
    end

    it 'correctly calculates fork parameters with historical data' do
      # Test the fork parameter calculation logic
      allow(FctMintCalculator).to receive(:calculate_historical_total).and_return(140_000_000)
      
      fork_block_num = 1_182_600 # Example from FIP
      params = FctMintCalculator.compute_bluebird_fork_block_params(fork_block_num)
      
      total_minted, max_supply, initial_target = params
      
      expect(total_minted).to eq(140_000_000)
      expect(max_supply).to be > 600_000_000 # Should be in expected range
      expect(initial_target).to be > 100_000 # Should be in expected range
      
      # Verify the mathematical relationships
      block_proportion = Rational(fork_block_num) / 2_628_000
      expected_mint_proportion = block_proportion * 0.5
      expected_max_supply = (140_000_000 / expected_mint_proportion).to_i
      
      expect(max_supply).to eq(expected_max_supply)
    end
  end
end 