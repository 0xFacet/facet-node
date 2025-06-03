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
  let(:fork_parameters) { [0, 100_000, 5_000] } # [total_minted, max_supply, initial_target]
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
        fct_total_minted: 1_000,
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

      expect(tx.mint).to eq(2_000)
      expect(facet_block.fct_total_minted).to eq(3_000)
      expect(facet_block.fct_period_minted).to eq(2_100)
      expect(facet_block.fct_mint_rate).to eq(2)
      expect(facet_block.fct_period_start_block).to eq(fork_block + 5)
    end

    it 'closes the period when the mint cap is hit and starts a new one' do
      block_num = fork_block + 10

      prev_attrs = {
        fct_total_minted: 1_000,
        fct_period_start_block: fork_block + 5,
        fct_period_minted: 4_500, # 500 short of 5_000 cap
        fct_mint_rate: 2,
        base_fee: 10
      }

      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)

      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      tx = OpenStruct.new(l1_data_gas_used: 300) # burns 3_000 eth, = 6_000 potential mint

      FctMintCalculator.assign_mint_amounts([tx], facet_block)

      expect(tx.mint).to eq(3_250) # 500 to finish old period, 2,750 in new one
      expect(facet_block.fct_total_minted).to eq(4_250)
      expect(facet_block.fct_period_start_block).to eq(block_num) # new period begins at current block
      expect(facet_block.fct_period_minted).to eq(2_750)
      expect(facet_block.fct_mint_rate).to eq(1) # rate adjusted down by factor 0.5
    end

    it 'adjusts the rate up when a period ends by block count' do
      block_num = fork_block + FctMintCalculator::ADJUSTMENT_PERIOD_TARGET_LENGTH.to_i
      period_start = block_num - FctMintCalculator::ADJUSTMENT_PERIOD_TARGET_LENGTH.to_i

      prev_attrs = {
        fct_total_minted: 1_000,
        fct_period_start_block: period_start,
        fct_period_minted: 100, # way under target
        fct_mint_rate: 2,
        base_fee: 10
      }

      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)

      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      tx = OpenStruct.new(l1_data_gas_used: 10) # trivial burn

      FctMintCalculator.assign_mint_amounts([tx], facet_block)

      expect(tx.mint).to eq(400)
      expect(facet_block.fct_mint_rate).to eq(4) # doubled
      # After the fix, the period rolls at the block boundary, so start block is the current block
      expect(facet_block.fct_period_start_block).to eq(block_num)
      expect(facet_block.fct_period_minted).to eq(tx.mint)
    end

    it 'handles multi-period spill-over (spans more than one full period)' do
      block_num = fork_block + 20

      prev_attrs = {
        fct_total_minted: 0,
        fct_period_start_block: block_num - 50,
        fct_period_minted: 0,
        fct_mint_rate: 1,
        base_fee: 1
      }

      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)

      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      tx = OpenStruct.new(l1_data_gas_used: 15_000) # produces 15k FCT mint @ rate 1

      FctMintCalculator.assign_mint_amounts([tx], facet_block)

      expect(tx.mint).to eq(15_000)
      expect(facet_block.fct_total_minted).to eq(15_000)
      expect(facet_block.fct_period_minted).to eq(0)
      expect(facet_block.fct_period_start_block).to eq(block_num)
      expect(facet_block.fct_mint_rate).to eq(1)
    end
    
    it 'lowers the target after crossing a halving threshold' do
      block_num = fork_block + 30

      prev_attrs = {
        fct_total_minted: 49_000,
        fct_period_start_block: block_num - 10,
        fct_period_minted: 0,
        fct_mint_rate: 1,
        base_fee: 1
      }

      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)

      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      tx = OpenStruct.new(l1_data_gas_used: 2_000) # crosses 50% (first halving) threshold

      engine = FctMintCalculator.assign_mint_amounts([tx], facet_block)

      # After minting, total minted should be 51_000
      expect(facet_block.fct_total_minted).to eq(51_000)
      # New supply-adjusted target is halved to 2_500
      expect(engine.current_target).to eq(2_500)
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

      expect(facet_block.fct_total_minted).to eq(fork_parameters[0])
      expect(facet_block.fct_period_start_block).to eq(block_num)
      expect(facet_block.fct_period_minted).to eq(0)
      expect(facet_block.fct_mint_rate).to eq(10) # 100/10
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
      tx = OpenStruct.new(l1_data_gas_used: 1_000) # would mint 5_000 but only 50 remain
      
      FctMintCalculator.assign_mint_amounts([tx], facet_block)

      expect(tx.mint).to eq(50)
      expect(facet_block.fct_total_minted).to eq(fork_parameters[1])
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
        fct_total_minted: 5_000,
        fct_period_start_block: block_num - 1,
        fct_period_minted: 5_000, # exactly at cap
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
        fct_total_minted: 1_000,
        fct_period_start_block: period_start,
        fct_period_minted: 4_900, # 100 short of 5_000 cap
        fct_mint_rate: 10,
        base_fee: 1
      }

      allow(client_double).to receive(:get_l1_attributes).with(block_num - 1).and_return(prev_attrs)

      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      tx = OpenStruct.new(l1_data_gas_used: 10) # exactly fills the cap

      FctMintCalculator.assign_mint_amounts([tx], facet_block)
      
      # The period ends after 800 blocks, so the factor should be 0.8 (not 0.5)
      # New rate should be 10 * 0.8 = 8
      expect(facet_block.fct_mint_rate).to eq(8)
    end

    # it 'applies proportional down-adjustment for each period flip in multi-period spill-over' do
    #   # Stub target to 5 000 so flips are deterministic
    #   allow(MintPeriod).to receive(:current_target).and_return(5_000)
    
    #   block_num  = fork_block + 10
    #   prev_attrs = {
    #     fct_total_minted:           0,
    #     fct_period_start_block: block_num - 5,
    #     fct_period_minted:  0,
    #     base_fee: 1,
    #     fct_mint_rate:              10
    #   }
    #   allow(client_double)
    #     .to receive(:get_l1_attributes)
    #     .with(block_num - 1)
    #     .and_return(prev_attrs)
    
    #   facet_block = DummyFacetBlock.new(number: block_num)
    #   facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
    
    #   # 3 500 gas × 10 = 35 000 wei → 15 000 FCT across 3 flips
    #   tx = OpenStruct.new(l1_data_gas_used: 3_500)
    
    #   FctMintCalculator.assign_mint_amounts([tx], facet_block)
    
    #   expect(tx.mint).to eq(15_000)                   # 3 × 5 000
    #   expect(facet_block.fct_total_minted).to        eq(15_000)
    #   expect(facet_block.fct_period_minted).to eq(5_000) # fourth period filled
    #   # Rate path: 10 → 5 → 2.5 → 1.25 → stored as 1
    #   expect(facet_block.fct_mint_rate).to eq(1)
    # end

    # --- Failing spec for bug #period-not-rolled-on-block-boundary -----------------------------
    it 'opens a fresh period when the adjustment-period length of blocks has elapsed' do
      period_len  = FctMintCalculator::ADJUSTMENT_PERIOD_TARGET_LENGTH.to_i
      block_num   = fork_block + period_len + 3          # > 1 full period after fork
      period_start= block_num - period_len               # previous period started exactly one period ago

      prev_attrs = {
        fct_total_minted:        1_000,
        fct_period_start_block:  period_start,
        fct_period_minted:       4_000,  # some mint already in previous window
        fct_mint_rate:           2,
        base_fee:               10
      }

      allow(client_double)
        .to receive(:get_l1_attributes)
        .with(block_num - 1)
        .and_return(prev_attrs)

      facet_block = DummyFacetBlock.new(number: block_num)
      facet_block.eth_block_base_fee_per_gas = prev_attrs[:base_fee]
      tx          = OpenStruct.new(l1_data_gas_used: 50) # small burn => 1_000 FCT @ rate 2 & baseFee 10

      FctMintCalculator.assign_mint_amounts([tx], facet_block)

      # The new period should have started at current block
      expect(facet_block.fct_period_start_block).to eq(block_num)

      # period_minted should have been reset, so it must equal exactly what this tx minted
      expect(facet_block.fct_period_minted).to eq(tx.mint)
    end
  end

  describe '#calculate_supply_adjusted_target' do
    # it 'halves the target when the minted supply crosses each halving threshold' do
    #   allow(FctMintCalculator).to receive(:fork_parameters).and_return([0, 100, 20])

    #   expect(FctMintCalculator.calculate_supply_adjusted_target(40)).to eq(20)
    #   expect(FctMintCalculator.calculate_supply_adjusted_target(60)).to eq(10)
    #   expect(FctMintCalculator.calculate_supply_adjusted_target(90)).to eq(Rational(5, 2))
    # end
  end
end 