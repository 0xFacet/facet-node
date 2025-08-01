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

  TARGET_NUM_BLOCKS_IN_HALVING = 2_628_000.to_r
  
  sig { returns(Integer) }
  def self.max_supply
    1_500_000_000.ether  # 1.5B tokens in wei
  end
  
  sig { returns(Rational) }
  def target_num_periods_in_halving
    Rational(TARGET_NUM_BLOCKS_IN_HALVING, ADJUSTMENT_PERIOD_TARGET_LENGTH)
  end
  
  sig { returns(GethClient) }
  def client
    @_client ||= GethDriver.client
  end
  
  # Target per period if we had started from block 0
  sig { returns(Integer) }
  def idealized_initial_target_per_period
    supply_target_first_halving = Rational(max_supply, 2)
    total_periods = TARGET_NUM_BLOCKS_IN_HALVING / ADJUSTMENT_PERIOD_TARGET_LENGTH
    (supply_target_first_halving / total_periods).to_i
  end
  
  # Get halving level based on total minted
  sig { params(total_minted: Integer).returns(Integer) }
  def get_halving_level(total_minted)
    return 0 if total_minted >= max_supply
    
    level = 0
    threshold = max_supply / 2
    
    while total_minted > threshold
      level += 1
      remaining = max_supply - threshold
      threshold += (remaining / 2)
    end
    
    level
  end
  
  # Calculate the target for the current period based on halving level
  sig { params(halving_level: Integer, stored_target: T.nilable(Integer)).returns(Integer) }
  def calculate_current_period_target(halving_level, stored_target)
    if halving_level == 0
      # First halving period - use the stored target (accounts for midstream fork)
      stored_target
    else
      # Subsequent halvings - use idealized target divided by 2^halving_level
      idealized = idealized_initial_target_per_period
      (idealized.to_r / (2 ** halving_level.to_r)).to_i
    end
  end

  # Remaining-supply / remaining-periods calculation
  sig { params(total_minted: Integer, current_block_num: Integer).returns(Integer) }
  def compute_target_per_period_at_bluebird_fork(total_minted, current_block_num)
    supply_target_first_halving = Rational(max_supply, 2)

    remaining_supply = supply_target_first_halving - total_minted
    return 0 if remaining_supply <= 0

    remaining_blocks  = TARGET_NUM_BLOCKS_IN_HALVING - current_block_num
    remaining_periods = (remaining_blocks.to_r / ADJUSTMENT_PERIOD_TARGET_LENGTH).ceil

    return 0 if remaining_periods <= 0
    
    dynamic_target = (remaining_supply / remaining_periods).to_i
    [idealized_initial_target_per_period, dynamic_target].max
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
  sig { params(facet_txs: T::Array[FacetTransaction], facet_block: FacetBlock).returns(MintPeriod) }
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
      # Calculate historical total instead of starting from 0
      total_minted = calculate_historical_total(current_block_num)
      period_start_block = current_block_num
      period_minted = 0
      
      fct_mint_rate = Rational(
        prev_attrs.fetch(:fct_mint_rate),
        prev_attrs.fetch(:base_fee) # NOTE: Base fee is never zero.
      ).to_i
      
      # Compute initial target based on historical total and current block
      initial_target_value = compute_target_per_period_at_bluebird_fork(
        total_minted,
        current_block_num
      )
    else
      total_minted = prev_attrs.fetch(:fct_total_minted)
      period_start_block = prev_attrs.fetch(:fct_period_start_block)
      period_minted = prev_attrs.fetch(:fct_period_minted)
      fct_mint_rate = prev_attrs.fetch(:fct_mint_rate)
      
      # Get the halving level for the total minted
      current_halving_level = get_halving_level(total_minted)
      
      # Always calculate what the target should be for this halving level
      # This ensures consistency after halvings
      stored_target = prev_attrs.fetch(:fct_initial_target_per_period)
      initial_target_value = calculate_current_period_target(current_halving_level, stored_target)
    end
    
    engine = MintPeriod.new(
      block_num: current_block_num,
      fct_mint_rate: fct_mint_rate,
      total_minted: total_minted,
      period_minted: period_minted,
      period_start_block: period_start_block,
      max_supply: max_supply,
      current_target: initial_target_value
    )

    engine.assign_mint_amounts(facet_txs, current_l1_base_fee)

    facet_block.assign_attributes(
      fct_total_minted:      engine.total_minted.to_i,
      fct_mint_rate:         engine.fct_mint_rate.to_i,
      fct_period_start_block: engine.period_start_block,
      fct_period_minted:     engine.period_minted.to_i,
      fct_initial_target_per_period: initial_target_value
    )

    engine
  end

  sig { params(block_number: T.nilable(Integer)).returns(Float) }
  def issuance_on_pace_delta(block_number = nil)
    block_number ||= EthRpcClient.l2.get_block_number
    
    time_fraction = Rational(block_number) / TARGET_NUM_BLOCKS_IN_HALVING
    raise "Time fraction is zero" if time_fraction.zero?
    
    attrs = client.get_l1_attributes(block_number)
    actual_total = attrs&.dig(:fct_total_minted).to_r
    
    supply_target_first_halving = max_supply.to_r / 2
    actual_fraction = Rational(actual_total, supply_target_first_halving)

    ratio = actual_fraction / time_fraction
    (ratio - 1).to_f.round(5)
  end
end
