require 'rails_helper'

RSpec.describe "MintPeriod halving during transaction" do
  it "applies halving mid-transaction when crossing threshold" do
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
    
    # Verify we're in halving level 0
    expect(engine.get_current_halving_level).to eq(0)
    expect(engine.current_target).to eq(FctMintCalculator.idealized_initial_target_per_period)
    
    # Now consume enough ETH to cross the halving boundary
    # We want to mint 2000 FCT total (1000 before halving, 1000 after)
    # At 100 FCT/ETH rate, we need 20 ETH
    eth_to_burn = 20
    
    # Here's what actually happens:
    # 1. In the first iteration, we calculate mint_amount = min(2000, 142694, 750001000) = 2000
    # 2. We mint 2000 FCT atomically, crossing the halving threshold
    # 3. After minting, halving level = 1, but period_minted = 2000
    # 4. New target = 71,347 FCT, remaining_quota = 71,347 - 2000 = 69,347 FCT
    # 5. No new period is triggered because we haven't exhausted the quota
    # 6. The halving IS applied correctly for any subsequent minting
    
    minted = engine.consume_eth(eth_to_burn)
    
    # Should mint exactly 2000 FCT because that's what fits in one iteration
    expect(minted).to eq(2000.ether)
    
    # Verify we crossed into halving level 1
    expect(engine.get_current_halving_level).to eq(1)
    expect(engine.total_minted).to be >= first_halving_threshold
    
    puts "\nHalving mid-transaction test:"
    puts "Started at: #{(total_minted_start / 1.ether).to_i} FCT"
    puts "Halving at: #{(first_halving_threshold / 1.ether).to_i} FCT"
    puts "ETH burned: #{eth_to_burn}"
    puts "FCT minted: #{(minted / 1.ether).to_i}"
    puts "Final total: #{(engine.total_minted / 1.ether).to_i} FCT"
    puts "Final halving level: #{engine.get_current_halving_level}"
    puts "Final rate: #{engine.fct_mint_rate / 1.ether}"
    
    # Now let's mint more to show the halving is in effect
    puts "\nMinting 100 more ETH to show halving effect..."
    
    # Before halving, 100 ETH would mint 10,000 FCT
    # But now we're at halving level 1 with reduced quota
    more_minted = engine.consume_eth(100)
    
    # Should mint only up to the remaining quota (69,347 FCT)
    expect(more_minted).to be < 70_000.ether
    
    puts "Additional minted: #{(more_minted / 1.ether).to_i} FCT"
    puts "Total after second burn: #{(engine.total_minted / 1.ether).to_i} FCT"
  end
  
  it "correctly calculates halving levels at various totals" do
    max_supply = FctMintCalculator.max_supply
    
    test_cases = [
      { total: 0, expected_level: 0 },
      { total: max_supply / 2 - 1, expected_level: 0 },
      { total: max_supply / 2, expected_level: 1 },
      { total: max_supply * 3 / 4 - 1, expected_level: 1 },
      { total: max_supply * 3 / 4, expected_level: 2 },
      { total: max_supply * 7 / 8 - 1, expected_level: 2 },
      { total: max_supply * 7 / 8, expected_level: 3 },
    ]
    
    test_cases.each do |test_case|
      engine = MintPeriod.new(
        block_num: 1_000_000,
        fct_mint_rate: 100.ether,
        total_minted: test_case[:total],
        period_minted: 0,
        period_start_block: 1_000_000,
        max_supply: max_supply,
        bluebird_fork_per_period_target: FctMintCalculator.idealized_initial_target_per_period
      )
      
      actual = engine.get_current_halving_level
      expect(actual).to eq(test_case[:expected_level]), 
        "Expected halving level #{test_case[:expected_level]} at #{test_case[:total] / 1.ether} FCT, but got #{actual}"
    end
  end
end