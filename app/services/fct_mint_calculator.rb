module FctMintCalculator
  # TODO: Add Sorbet type checking.
  
  extend SysConfig
  include SysConfig
  extend self
  
  ORIGINAL_ADJUSTMENT_PERIOD_TARGET_LENGTH = Rational(10_000)
  ADJUSTMENT_PERIOD_TARGET_LENGTH = Rational(1_000)
  MAX_MINT_RATE = Rational(((2 ** 128) - 1))
  MIN_MINT_RATE = Rational(1)
  MAX_RATE_ADJUSTMENT_UP_FACTOR = Rational(2)
  MAX_RATE_ADJUSTMENT_DOWN_FACTOR = Rational(1, 2)
  TARGET_ISSUANCE_FRACTION_FIRST_HALVING = Rational(1, 2)

  TARGET_NUM_BLOCKS_IN_HALVING = 2_628_000.to_r
  TARGET_NUM_PERIODS_IN_HALVING = Rational(TARGET_NUM_BLOCKS_IN_HALVING, ADJUSTMENT_PERIOD_TARGET_LENGTH)
  
  def client
    @_client ||= GethDriver.client
  end

  # We calculate these once every time the node starts. It's a fine trade-off
  def fork_parameters
    @fork_parameters ||= compute_bluebird_fork_block_params(SysConfig.bluebird_fork_block_number)
  end

  def bluebird_fork_block_total_minted
    fork_parameters[0]
  end

  def max_supply
    fork_parameters[1]
  end

  def target_per_period
    fork_parameters[2]
  end
  
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

  def compute_bluebird_fork_block_params(block_number)
    # This assumes the fork is before the first halving, which it will be.
    
    # Get actual total minted FCT up to fork
    total_minted = calculate_historical_total(block_number)
    
    # Calculate what percentage through the first halving period we are
    percent_time_elapsed = Rational(block_number) / TARGET_NUM_BLOCKS_IN_HALVING
    
    # The expected percentage of total supply that should be minted by now
    # (50% of supply should be minted in first halving, so we take 50% * percent_elapsed)
    expected_mint_percentage = percent_time_elapsed * TARGET_ISSUANCE_FRACTION_FIRST_HALVING
    
    if expected_mint_percentage.zero?
      raise "Bluebird fork pre-condition failed: expected mint percentage is zero"
    end
    
    # Calculate new max supply based on actual minting rate
    # If we've minted X tokens and that should be Y% of supply, then max supply = X/Y
    new_max_supply = (total_minted / expected_mint_percentage)
    
    # Calculate new initial target per period by targeting 50% issuance in first year.
    target_supply_in_first_halving = Rational(new_max_supply, 2)
    new_initial_target_per_period = (target_supply_in_first_halving / TARGET_NUM_PERIODS_IN_HALVING)
    
    # Convert to integers only for final storage
    [total_minted.to_i, new_max_supply.to_i, new_initial_target_per_period.to_i]
  end

  # --- Core Logic ---
  def assign_mint_amounts(facet_txs, facet_block)
    # Use legacy mint calculator before the Bluebird fork block
    if facet_block.number < SysConfig.bluebird_fork_block_number
      return FctMintCalculatorOld.assign_mint_amounts(facet_txs, facet_block)
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
      )
    else
      total_minted = prev_attrs.fetch(:fct_total_minted)
      period_start_block = prev_attrs.fetch(:fct_period_start_block)
      period_minted = prev_attrs.fetch(:fct_period_minted)
      fct_mint_rate = prev_attrs.fetch(:fct_mint_rate)
    end
    
    engine = MintPeriod.new(
      block_num: current_block_num,
      fct_mint_rate: fct_mint_rate,
      total_minted: total_minted,
      period_minted: period_minted,
      period_start_block: period_start_block
    )

    engine.assign_mint_amounts(facet_txs, current_l1_base_fee)

    facet_block.assign_attributes(
      fct_total_minted:      engine.total_minted.to_i,
      fct_mint_rate:         engine.fct_mint_rate.to_i,
      fct_period_start_block: engine.period_start_block,
      fct_period_minted:     engine.period_minted.to_i
    )

    engine
  end

  def issuance_on_pace_delta(block_number)
    attrs = client.get_l1_attributes(block_number)

    actual_total = if attrs && attrs[:fct_total_minted]
      attrs[:fct_total_minted].to_r
    else
      # Fallback for legacy blocks where total minted wasn't tracked per block
      calculate_historical_total(block_number)
    end

    supply_target_first_halving = max_supply.to_r / 2
    actual_fraction = Rational(actual_total, supply_target_first_halving)

    time_fraction = Rational(block_number) / TARGET_NUM_BLOCKS_IN_HALVING
    raise "Time fraction is zero" if time_fraction.zero?

    ratio = actual_fraction / time_fraction
    (ratio - 1).to_f.round(5)
  end
end
