module FctMintCalculator
  extend SysConfig
  include SysConfig
  extend self
  
  ORIGINAL_ADJUSTMENT_PERIOD_TARGET_LENGTH = 10_000.to_r
  ADJUSTMENT_PERIOD_TARGET_LENGTH = 500.to_r
  MAX_MINT_RATE = ((2 ** 128) - 1).to_r
  MIN_MINT_RATE = 1.to_r
  MAX_RATE_ADJUSTMENT_UP_FACTOR = 4.to_r
  MAX_RATE_ADJUSTMENT_DOWN_FACTOR = Rational(1, 4)
  TARGET_ISSUANCE_FRACTION_FIRST_HALVING = Rational(1, 2)

  TARGET_NUM_BLOCKS_IN_HALVING = (2_628_000 * 2).to_r
  
  sig { returns(Rational) }
  def target_num_periods_in_halving
    Rational(TARGET_NUM_BLOCKS_IN_HALVING, ADJUSTMENT_PERIOD_TARGET_LENGTH)
  end
  
  sig { returns(GethClient) }
  def client
    @_client ||= GethDriver.client
  end

  sig { returns(Integer) }
  def bluebird_fork_block_total_minted
    if SysConfig.bluebird_immediate_fork?
      0  # nothing minted pre-fork
    else
      calculate_historical_total(SysConfig.bluebird_fork_block_number)
    end
  end

  sig { returns(Integer) }
  def compute_max_supply
    if SysConfig.bluebird_immediate_fork?
      Integer(ENV.fetch('BLUEBIRD_IMMEDIATE_FORK_MAX_SUPPLY_ETHER')).ether
    else
      # Calculate what percentage through the first halving period we are
      percent_time_elapsed = Rational(SysConfig.bluebird_fork_block_number) / TARGET_NUM_BLOCKS_IN_HALVING
      
      # The expected percentage of total supply that should be minted by now
      # (50% of supply should be minted in first halving, so we take 50% * percent_elapsed)
      expected_mint_percentage = percent_time_elapsed * TARGET_ISSUANCE_FRACTION_FIRST_HALVING
      
      if expected_mint_percentage.zero?
        raise "Bluebird fork pre-condition failed: expected mint percentage is zero"
      end
      
      # Calculate new max supply based on actual minting rate
      # If we've minted X tokens and that should be Y% of supply, then max supply = X/Y
      total_minted = bluebird_fork_block_total_minted
      new_max_supply = total_minted / expected_mint_percentage
      
      new_max_supply.to_i
    end
  end
  
  sig { returns(Integer) }
  def compute_target_per_period
    target_supply_in_first_halving = Rational(compute_max_supply, 2)
    (target_supply_in_first_halving / target_num_periods_in_halving).to_i
  end
  
  sig { params(block_number: Integer).returns(Integer) }
  def calculate_historical_total(block_number)
    # Only used for the fork block calculation. The fork block will be the first block in a new period.
    # Iterate through all completed periods before the fork block
    total = 0
    
    # Start with the last block of the first period
    # Use the original period length (10,000) because we're looking at historical data
    current_period_end = ORIGINAL_ADJUSTMENT_PERIOD_TARGET_LENGTH - 1
    
    # Process all completed periods
    while current_period_end < block_number
      attributes = client.get_l1_attributes(current_period_end.to_i)
      
      if attributes && attributes[:fct_mint_period_l1_data_gas]
        total += attributes[:fct_mint_period_l1_data_gas] * attributes[:fct_mint_rate]
      end
      
      current_period_end += ORIGINAL_ADJUSTMENT_PERIOD_TARGET_LENGTH
    end
    
    # Add minting from the partial period if needed
    last_full_period_end = current_period_end - ORIGINAL_ADJUSTMENT_PERIOD_TARGET_LENGTH
    if last_full_period_end < block_number - 1
      attributes = client.get_l1_attributes(block_number - 1)
      
      if attributes && attributes[:fct_mint_period_l1_data_gas]
        total += attributes[:fct_mint_period_l1_data_gas] * attributes[:fct_mint_rate]
      end
    end
    
    total
  end

  # --- Core Logic ---
  sig { params(facet_txs: T.untyped, facet_block: FacetBlock).returns(MintPeriod) }
  def assign_mint_amounts(facet_txs, facet_block)
    # Use legacy mint calculator before the Bluebird fork block
    if facet_block.number < SysConfig.bluebird_fork_block_number
      return FctMintCalculatorAlbatross.assign_mint_amounts(facet_txs, facet_block)
    end

    current_block_num = facet_block.number
    
    # Retrieve state from previous block (N-1)
    prev_attrs = client.get_l1_attributes(current_block_num - 1)
    current_l1_base_fee = facet_block.eth_block_base_fee_per_gas

    if current_block_num == SysConfig.bluebird_fork_block_number
      total_minted = bluebird_fork_block_total_minted
      period_start_block = current_block_num
      period_minted = 0
      
      fct_mint_rate = Rational(
        prev_attrs.fetch(:fct_mint_rate),
        prev_attrs.fetch(:base_fee) # NOTE: Base fee is never zero.
      ).to_i
      
      # Compute max supply and initial target at fork block
      max_supply_value = compute_max_supply
      initial_target_value = compute_target_per_period
    else
      total_minted = prev_attrs.fetch(:fct_total_minted)
      period_start_block = prev_attrs.fetch(:fct_period_start_block)
      period_minted = prev_attrs.fetch(:fct_period_minted)
      fct_mint_rate = prev_attrs.fetch(:fct_mint_rate)
      
      # Use values from L1 attributes after fork
      max_supply_value = prev_attrs.fetch(:fct_max_supply)
      initial_target_value = prev_attrs.fetch(:fct_initial_target_per_period)
    end
    
    engine = MintPeriod.new(
      block_num: current_block_num,
      fct_mint_rate: fct_mint_rate,
      total_minted: total_minted,
      period_minted: period_minted,
      period_start_block: period_start_block,
      max_supply: max_supply_value,
      target_per_period: initial_target_value
    )

    engine.assign_mint_amounts(facet_txs, current_l1_base_fee)

    facet_block.assign_attributes(
      fct_total_minted:      engine.total_minted.to_i,
      fct_mint_rate:         engine.fct_mint_rate.to_i,
      fct_period_start_block: engine.period_start_block,
      fct_period_minted:     engine.period_minted.to_i,
      fct_max_supply:        max_supply_value,
      fct_initial_target_per_period: initial_target_value
    )

    engine
  end

  sig { params(block_number: T.nilable(Integer)).returns(Float) }
  def issuance_on_pace_delta(block_number = nil)
    block_number ||= EthRpcClient.l2.get_block_number
    attrs = client.get_l1_attributes(block_number)

    actual_total = if attrs && attrs[:fct_total_minted]
      attrs[:fct_total_minted].to_r
    else
      # Fallback for legacy blocks where total minted wasn't tracked per block
      calculate_historical_total(block_number)
    end

    supply_target_first_halving = compute_max_supply.to_r / 2
    actual_fraction = Rational(actual_total, supply_target_first_halving)

    time_fraction = Rational(block_number) / TARGET_NUM_BLOCKS_IN_HALVING
    raise "Time fraction is zero" if time_fraction.zero?

    ratio = actual_fraction / time_fraction
    (ratio - 1).to_f.round(5)
  end
end
