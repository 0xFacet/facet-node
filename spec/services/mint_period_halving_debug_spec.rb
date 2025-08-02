require 'rails_helper'

RSpec.describe "MintPeriod halving debug" do
  it "debugs halving behavior step by step" do
    max_supply = FctMintCalculator.max_supply
    first_halving_threshold = max_supply / 2
    
    # Start just before the halving threshold
    # Leave room for exactly 1000 FCT before halving
    total_minted_start = first_halving_threshold - 1000.ether
    
    engine = MintPeriod.new(
      block_num: 1_000_000,
      fct_mint_rate: 100.ether,  # 100 FCT per ETH
      total_minted: total_minted_start,
      period_minted: 0,
      period_start_block: 1_000_000,
      max_supply: max_supply,
      bluebird_fork_per_period_target: FctMintCalculator.idealized_initial_target_per_period
    )
    
    puts "\n=== Initial State ==="
    puts "Total minted: #{(engine.total_minted / 1.ether).to_i} FCT"
    puts "Period minted: #{engine.period_minted} FCT"
    puts "Halving level: #{engine.get_current_halving_level}"
    puts "Current target: #{(engine.current_target / 1.ether).to_i} FCT"
    puts "Remaining quota: #{(engine.remaining_period_quota / 1.ether).to_i} FCT"
    
    # Manually simulate the consume_eth loop
    remaining_eth = 20.to_r
    minted = 0.to_r
    step = 0
    
    until remaining_eth.zero? || engine.supply_exhausted?
      step += 1
      
      # Calculate mint amount
      mint_possible = remaining_eth * engine.fct_mint_rate
      quota = engine.remaining_period_quota
      supply = engine.remaining_supply
      mint_amount = [mint_possible, quota, supply].min
      
      puts "\n=== Step #{step} ==="
      puts "Remaining ETH: #{remaining_eth.to_f}"
      puts "Mint possible: #{(mint_possible / 1.ether).to_i} FCT"
      puts "Remaining quota: #{(quota / 1.ether).to_i} FCT"
      puts "Remaining supply: #{(supply / 1.ether).to_i} FCT"
      puts "Will mint: #{(mint_amount / 1.ether).to_i} FCT"
      
      # Simulate the minting
      burn_used = mint_amount / engine.fct_mint_rate
      remaining_eth -= burn_used
      
      minted += mint_amount
      engine.instance_variable_set(:@period_minted, engine.period_minted + mint_amount)
      engine.instance_variable_set(:@total_minted, engine.total_minted + mint_amount)
      
      puts "After minting:"
      puts "  Total minted: #{(engine.total_minted / 1.ether).to_i} FCT"
      puts "  Period minted: #{(engine.period_minted / 1.ether).to_i} FCT"
      puts "  Halving level: #{engine.get_current_halving_level}"
      puts "  Current target: #{(engine.current_target / 1.ether).to_i} FCT"
      
      if engine.remaining_period_quota.zero?
        puts "  -> Triggering new period (quota exhausted)"
        engine.start_new_period(:adjust_down)
        puts "  New rate: #{engine.fct_mint_rate / 1.ether}"
      end
      
      break if step > 10  # Safety limit
    end
    
    puts "\n=== Final Result ==="
    puts "Total minted in transaction: #{(minted / 1.ether).to_i} FCT"
    puts "Final total: #{(engine.total_minted / 1.ether).to_i} FCT"
    puts "Final halving level: #{engine.get_current_halving_level}"
  end
end