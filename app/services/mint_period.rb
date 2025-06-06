class MintPeriod
  include SysConfig
  
  HALVING_FACTOR = 2.to_r

  attr_reader :fct_mint_rate, :period_minted, :total_minted, :period_start_block, 
              :block_num

  def initialize(block_num:, fct_mint_rate:, total_minted:, period_minted:, period_start_block:)
    @block_num            = block_num
    @fct_mint_rate        = fct_mint_rate
    @total_minted         = total_minted
    @period_minted        = period_minted
    @period_start_block   = period_start_block
  end
  
  # Consumes an ETH burn amount, returns FCT minted for this tx (Rational)
  def consume_eth(eth_burn)
    remaining_eth = eth_burn.to_r
    minted        = 0.to_r
    
    until remaining_eth.zero? || supply_exhausted?
      mint_possible = remaining_eth * fct_mint_rate
      mint_amount   = [mint_possible, remaining_period_quota, remaining_supply].min

      burn_used     = mint_amount / fct_mint_rate
      remaining_eth -= burn_used

      minted        += mint_amount
      @period_minted += mint_amount
      @total_minted  += mint_amount
      
      start_new_period(:adjust_down) if remaining_period_quota.zero?
    end

    minted
  end
  
  sig { returns(Rational) }
  def remaining_period_quota
    [current_target - period_minted, 0].max.floor.to_r
  end
  
  sig { returns(Rational) }
  def remaining_supply
    [max_supply - total_minted, 0].max.floor.to_r
  end

  def assign_mint_amounts(facet_txs, current_l1_base_fee)
    if blocks_elapsed_in_period >= FctMintCalculator::ADJUSTMENT_PERIOD_TARGET_LENGTH
      start_new_period(:adjust_up)
    end
    
    facet_txs.each do |tx|
      burn = tx.l1_data_gas_used(block_num) * current_l1_base_fee
      tx.mint = consume_eth(burn).to_i
    end
  end

  def max_supply
    FctMintCalculator.max_supply.to_r
  end
  
  def current_target
    target = FctMintCalculator.target_per_period
    get_current_halving_level.times { target /= HALVING_FACTOR }
    [target, 1].max.floor.to_r
  end
  
  def get_current_halving_level
    level = 0
    threshold = max_supply / HALVING_FACTOR
    
    # Find how many halving thresholds we've crossed
    while total_minted >= threshold && threshold < max_supply && total_minted < max_supply
      level += 1
      remaining = max_supply - threshold
      threshold += (remaining / HALVING_FACTOR) # Add half of the remaining supply
    end
    
    level
  end

  def supply_exhausted?
    total_minted >= max_supply
  end

  def blocks_elapsed_in_period
    block_num - period_start_block
  end

  def start_new_period(adjustment_type)
    raise unless [:adjust_up, :adjust_down].include?(adjustment_type)
    
    adjustment_type == :adjust_down ? down_adjust_rate : up_adjust_rate
    
    @period_start_block = block_num
    @period_minted = 0
  end

  # --- rate helpers -------------------------------------------------------
  def down_adjust_rate
    raw_ratio = Rational(blocks_elapsed_in_period, FctMintCalculator::ADJUSTMENT_PERIOD_TARGET_LENGTH)
    capped_ratio = [raw_ratio, FctMintCalculator::MAX_RATE_ADJUSTMENT_DOWN_FACTOR].max
    
    @fct_mint_rate = compute_and_cap_rate(fct_mint_rate, capped_ratio)
  end
  
  def up_adjust_rate
    capped_ratio = if period_minted.zero?
               FctMintCalculator::MAX_RATE_ADJUSTMENT_UP_FACTOR
             else
               [Rational(current_target, period_minted), FctMintCalculator::MAX_RATE_ADJUSTMENT_UP_FACTOR].min
             end
    
    @fct_mint_rate = compute_and_cap_rate(fct_mint_rate, capped_ratio)
  end
  
  def compute_and_cap_rate(prev_rate, adjustment_factor)
    raw_new_rate = prev_rate.to_r * adjustment_factor
    raw_new_rate.clamp(FctMintCalculator::MIN_MINT_RATE, FctMintCalculator::MAX_MINT_RATE)
  end
end
