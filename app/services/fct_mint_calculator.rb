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
  HALVING_FACTOR = Rational(2)
  TARGET_ISSUANCE_FRACTION_FIRST_HALVING = Rational(1, 2)

  SECONDS_PER_YEAR = Rational(31_556_952) # length of a gregorian year (365.2425 days)
  
  TARGET_NUM_BLOCKS_IN_HALVING = Rational(SECONDS_PER_YEAR, SysConfig::L2_BLOCK_TIME)
  TARGET_NUM_PERIODS_IN_HALVING = Rational(TARGET_NUM_BLOCKS_IN_HALVING, ADJUSTMENT_PERIOD_TARGET_LENGTH)
  
  def client
    @_client ||= GethDriver.client
  end

  # --- Fork parameters (calculate only once) ---
  # This will lazily initialize these values when first accessed
  def fork_parameters
    @fork_parameters ||= compute_bluebird_fork_block_params(SysConfig.bluebird_fork_block_number)
  end

  def bluebird_fork_block_total_minted
    fork_parameters[0]
  end

  def bluebird_fork_block_max_supply
    fork_parameters[1]
  end

  def bluebird_fork_block_initial_target_per_period
    fork_parameters[2]
  end

  # --- Helper Functions ---

  # Determines the number of halvings completed based on total minted FCT.
  # Each halving represents a period where a decreasing fraction of the remaining
  # supply is issued. The first halving is 50%, then 25%, 12.5%, and so on.
  def get_current_halving_level(total_minted_fct)
    max_supply = Rational(bluebird_fork_block_max_supply)
    
    level = 0
    threshold = max_supply / HALVING_FACTOR # 50% of max supply
    
    # Find how many halving thresholds we've crossed
    while total_minted_fct >= threshold && threshold < max_supply
      level += 1
      remaining_supply = max_supply - threshold
      threshold += (remaining_supply / HALVING_FACTOR) # Add half of the remaining supply
    end
    
    level
  end

  def calculate_supply_adjusted_target(total_minted_fct)
    return 0 if total_minted_fct >= bluebird_fork_block_max_supply

    target = bluebird_fork_block_initial_target_per_period
    get_current_halving_level(total_minted_fct).times { target /= HALVING_FACTOR }
    target
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
      attributes = client.get_l1_attributes(current_period_end)
      
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
    target_supply_in_first_halving = Rational(new_max_supply, HALVING_FACTOR)
    new_initial_target_per_period = (target_supply_in_first_halving / TARGET_NUM_PERIODS_IN_HALVING)
    
    # Convert to integers only for final storage
    [total_minted.to_i, new_max_supply.to_i, new_initial_target_per_period.to_i]
  end

  def calculate_fct_mint_rate(prev_rate, adjustment_factor)
    fct_mint_rate = Rational(prev_rate) * adjustment_factor
    fct_mint_rate = [fct_mint_rate, MAX_MINT_RATE].min
    [fct_mint_rate, MIN_MINT_RATE].max
  end

  # Calculates the mint amount for a transaction based on the ETH burned,
  # current mint rate, and period constraints.
  #
  # This method handles both scenarios:
  # 1. The transaction fits within the current period's remaining mint cap
  # 2. The transaction exceeds the period cap and must span multiple periods
  #
  # For case 2, the method will apply a rate adjustment between periods
  # according to the blocks elapsed in the period.
  #
  # @param remaining_eth_burn [Integer, Rational] The amount of ETH burned in this TX
  # @param fct_mint_rate [Integer, Rational] Current FCT mint rate
  # @param period_minted [Integer, Rational] Amount already minted in current period
  # @param total_minted [Integer, Rational] Total FCT minted so far
  # @param period_start_block [Integer] The block where the current period started
  # @param current_block_num [Integer] The current block number
  # @return [Array] [tx_mint, new_mint_rate, new_period_minted, new_total_minted, new_period_start_block]
  def calculate_tx_mint(remaining_eth_burn, fct_mint_rate, period_minted, total_minted, period_start_block, current_block_num)
    # Ensure inputs are Rational where calculations expect them
    tx_mint = Rational(0)
    remaining_eth_burn = Rational(remaining_eth_burn)
    fct_mint_rate = Rational(fct_mint_rate)
    period_minted = Rational(period_minted)
    total_minted = Rational(total_minted)
  
    loop do
      remaining_supply = Rational(bluebird_fork_block_max_supply) - total_minted
  
      # Base cases / loop termination conditions
      if remaining_supply <= 0 || remaining_eth_burn <= 0
        return [tx_mint, fct_mint_rate, period_minted, total_minted, period_start_block]
      end
  
      current_target_per_period = calculate_supply_adjusted_target(total_minted)
      remaining_period_mint = current_target_per_period - period_minted
  
      # If the period target is zero (e.g., max supply almost reached) or already exceeded, no more minting can occur.
      if remaining_period_mint <= 0 || current_target_per_period.zero?
        return [tx_mint, fct_mint_rate, period_minted, total_minted, period_start_block]
      end
  
      new_tx_mint = remaining_eth_burn * fct_mint_rate
  
      # Early exit when this burn is enough to mint the entire remaining supply.
      if new_tx_mint >= remaining_supply
        tx_mint += remaining_supply
        period_minted += remaining_supply
        total_minted += remaining_supply
        return [tx_mint, fct_mint_rate, period_minted, total_minted, period_start_block]
      elsif new_tx_mint <= remaining_period_mint
        tx_mint += new_tx_mint
        period_minted += new_tx_mint
        total_minted += new_tx_mint
        return [tx_mint, fct_mint_rate, period_minted, total_minted, period_start_block]
      else
        # Period cap reached, mint what we can and start a new period
        eth_burnt_in_this_period = Rational(remaining_period_mint, fct_mint_rate)
        actual_new_tx_mint = [remaining_period_mint, remaining_supply].min
  
        remaining_eth_burn -= eth_burnt_in_this_period
        tx_mint += actual_new_tx_mint
        total_minted += actual_new_tx_mint
        period_minted = 0 # Reset for the new period
  
        # Recalculate fct_mint_rate and update period_start_block
        blocks_elapsed = current_block_num - period_start_block + 1
        adjustment_factor = [Rational(blocks_elapsed, ADJUSTMENT_PERIOD_TARGET_LENGTH), MAX_RATE_ADJUSTMENT_DOWN_FACTOR].max
        fct_mint_rate = calculate_fct_mint_rate(fct_mint_rate, adjustment_factor)
        period_start_block = current_block_num # Start the new period from the current block
      end
    end
  end

  # --- Core Logic ---
  def assign_mint_amounts(facet_txs, facet_block)
    # Use legacy mint calculator before the Bluebird fork block
    if facet_block.number < SysConfig.bluebird_fork_block_number
      return FctMintCalculatorOld.assign_mint_amounts(facet_txs, facet_block)
    end

    current_block_num = facet_block.number
    
    # Retrieve state from previous block (N-1)
    prev_attrs = client.get_l1_attributes(current_block_num - 1) || {}
    l1_base_fee = prev_attrs.fetch(:base_fee)

    if current_block_num == SysConfig.bluebird_fork_block_number
      # Special handling for the fork block
      total_minted = bluebird_fork_block_total_minted
      period_start_block = current_block_num
      period_minted = 0
      prev_rate = Rational(prev_attrs.fetch(:fct_mint_rate), prev_attrs.fetch(:base_fee))
      fct_mint_rate = calculate_fct_mint_rate(prev_rate, 1)
    else
      # Normal block processing
      total_minted = prev_attrs.fetch(:fct_total_minted)
      period_start_block = prev_attrs.fetch(:fct_period_start_block)
      period_minted = prev_attrs.fetch(:fct_period_minted)
      fct_mint_rate = prev_attrs.fetch(:fct_mint_rate)
    end
    
    # If previous period hit the cap **exactly**, start a new period immediately so the first tx can mint.
    current_target_per_period = calculate_supply_adjusted_target(total_minted)
    if period_minted == current_target_per_period && current_target_per_period.positive?
      blocks_elapsed = current_block_num - period_start_block + 1
      factor = [Rational(blocks_elapsed, ADJUSTMENT_PERIOD_TARGET_LENGTH), MAX_RATE_ADJUSTMENT_DOWN_FACTOR].max
      fct_mint_rate      = calculate_fct_mint_rate(fct_mint_rate, factor)
      period_start_block = current_block_num
      period_minted      = 0
    end

    # Process each transaction
    facet_txs.each do |tx|
      tx_eth_burnt = tx.l1_data_gas_used * l1_base_fee
      tx_mint, fct_mint_rate, period_minted, total_minted, period_start_block = 
        calculate_tx_mint(tx_eth_burnt, fct_mint_rate, period_minted, total_minted, period_start_block, current_block_num)
      
      # Only convert to integer when assigning to tx.mint
      tx.mint = tx_mint.to_i
    end

    # Check if period ends by blocks and apply adjustment if needed
    blocks_elapsed = current_block_num - period_start_block + 1
    current_target_per_period = calculate_supply_adjusted_target(total_minted)
    
    # If issuance cap reached (== or >) by the end of the block, apply down-adjustment now
    if period_minted >= current_target_per_period && current_target_per_period.positive?
      factor = if period_minted > current_target_per_period
        [Rational(current_target_per_period, period_minted), MAX_RATE_ADJUSTMENT_DOWN_FACTOR].max
      else
        [Rational(blocks_elapsed, ADJUSTMENT_PERIOD_TARGET_LENGTH), MAX_RATE_ADJUSTMENT_DOWN_FACTOR].max
      end
      fct_mint_rate      = calculate_fct_mint_rate(fct_mint_rate, factor)
      period_start_block = current_block_num
      # keep period_minted as is (it will roll next block)
    end

    if blocks_elapsed >= ADJUSTMENT_PERIOD_TARGET_LENGTH
      # Apply up adjustment at end of period
      adjustment_factor = if period_minted > 0
        [Rational(current_target_per_period, period_minted), MAX_RATE_ADJUSTMENT_UP_FACTOR].min
      else
        MAX_RATE_ADJUSTMENT_UP_FACTOR
      end
      
      fct_mint_rate = calculate_fct_mint_rate(fct_mint_rate, adjustment_factor)
    end

    # Store state for next block - convert to integers only when storing
    facet_block.assign_attributes(
      fct_total_minted: total_minted.to_i,
      fct_mint_rate: fct_mint_rate.to_i,
      fct_period_start_block: period_start_block,
      fct_period_minted: period_minted.to_i
    )

    nil
  end
end
