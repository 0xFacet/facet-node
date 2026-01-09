# Simple FCT Mint Simulator - Console only
# Usage: 
#   sim = FctMintSimulator.new
#   sim.simulate_next_block() # Simulate next L2 block
#   sim.simulate_blocks(100) # Simulate 100 blocks

require 'concurrent'
require 'oj'

class FctMintSimulator
  include SysConfig
  
  # Hardcoded fork block state (block 2)
  FORK_BLOCK_STATE = {
    block_number: 2,
    l1_block: 21373002,  # L1 genesis block
    fct_total_minted: 0,
    fct_mint_rate: 16690,
    fct_period_start_block: 2,
    fct_period_minted: 0
  }
  
  # Class-level cache storage
  @minimal_cache = nil
  @cache_mutex = Mutex.new
  
  def self.minimal_cache
    @cache_mutex.synchronize do
      @minimal_cache
    end
  end
  
  def self.minimal_cache=(cache)
    @cache_mutex.synchronize do
      @minimal_cache = cache
    end
  end
  
  def initialize(initial_state: nil)
    @simulated_attributes = {}
    @simulated_l2_blocks = {}
    @current_l2_block_number = nil
    
    # We'll fetch L1 blocks directly
    @l1_client = EthRpcClient.l1
    
    if initial_state
      # Use provided initial state
      @initial_state = initial_state
      @current_l1_block = initial_state[:l1_block]
      @current_l2_block_number = initial_state[:block_number]
    else
      # Default to genesis
      @l1_genesis_block = ENV['L1_GENESIS_BLOCK']&.to_i || 19_135_629
      @current_l1_block = @l1_genesis_block - 1
    end
    
    setup_mock_geth_client
  end
  
  def simulate_and_compare(count, check_each_block: false)
    if check_each_block
      # Check after each block to find exact divergence point
      count.times do |i|
        simulate_single_block(verbose: false)
        
        # Get simulated state
        sim_attrs = @simulated_attributes[@current_l2_block_number]
        
        # Get Geth state
        geth_attrs = GethDriver.client.get_l1_attributes(@current_l2_block_number)
        
        # Compare key attributes
        if sim_attrs[:fct_total_minted] != geth_attrs[:fct_total_minted] ||
           sim_attrs[:fct_mint_rate] != geth_attrs[:fct_mint_rate] ||
           sim_attrs[:fct_period_start_block] != geth_attrs[:fct_period_start_block] ||
           sim_attrs[:fct_period_minted] != geth_attrs[:fct_period_minted]
          
          puts "\nDivergence found at L2 block #{@current_l2_block_number}!"
          puts "\nSimulated state:"
          puts "  Total minted: #{sim_attrs[:fct_total_minted]} (#{(sim_attrs[:fct_total_minted] / 1e18).round(6)} FCT)"
          puts "  Mint rate: #{sim_attrs[:fct_mint_rate]}"
          puts "  Period start: #{sim_attrs[:fct_period_start_block]}"
          puts "  Period minted: #{sim_attrs[:fct_period_minted]}"
          
          puts "\nGeth state:"
          puts "  Total minted: #{geth_attrs[:fct_total_minted]} (#{(geth_attrs[:fct_total_minted] / 1e18).round(6)} FCT)"
          puts "  Mint rate: #{geth_attrs[:fct_mint_rate]}"
          puts "  Period start: #{geth_attrs[:fct_period_start_block]}"
          puts "  Period minted: #{geth_attrs[:fct_period_minted]}"
          
          puts "\nDifferences:"
          puts "  Total minted diff: #{sim_attrs[:fct_total_minted] - geth_attrs[:fct_total_minted]} wei"
          puts "  Mint rate diff: #{sim_attrs[:fct_mint_rate] - geth_attrs[:fct_mint_rate]}"
          puts "  Period start diff: #{sim_attrs[:fct_period_start_block] - geth_attrs[:fct_period_start_block]}"
          puts "  Period minted diff: #{sim_attrs[:fct_period_minted] - geth_attrs[:fct_period_minted]} wei"
          
          # Get the L2 block mapping to show L1 block info
          l2_block_info = @simulated_l2_blocks[@current_l2_block_number]
          if l2_block_info
            puts "\nL1 block processed: #{l2_block_info[:l1_block]}"
          end
          
          binding.irb
          return {
            diverged_at_block: @current_l2_block_number,
            simulated: sim_attrs,
            geth: geth_attrs
          }
        end
        
        if (i + 1) % 100 == 0
          print "\rChecked #{i + 1}/#{count} blocks..."
        end
      end
      
      puts "\nNo divergence found in #{count} blocks!"
    else
      # Original behavior - just check final state
      res = simulate_blocks(count)
      minted = res[:final_total_minted]
      final_l2_block = res[:final_l2_block]
      
      attrs = GethDriver.client.get_l1_attributes(final_l2_block)
      
      geth_minted = attrs[:fct_total_minted]
      
      if minted != geth_minted
        puts "\nDivergence found!"
        puts "Simulated: #{minted} wei (#{(minted / 1e18).round(6)} FCT)"
        puts "Geth: #{geth_minted} wei (#{(geth_minted / 1e18).round(6)} FCT)"
        puts "Difference: #{minted - geth_minted} wei"
        binding.irb
      end
      
      res
    end
  end
  
  def simulate_blocks(count, verbose: false, batch_size: 30)
    puts "Simulating #{count} blocks..."
    start_time = Time.now
    
    # Process in batches
    blocks_to_process = []
    count.times do
      # If we don't have a current L1 block yet, use the one from initial state or genesis
      if @current_l1_block.nil?
        @current_l1_block = @initial_state ? @initial_state[:l1_block] : @l1_genesis_block
      else
        @current_l1_block += 1
      end
      blocks_to_process << @current_l1_block
    end
    
    processed = 0
    next_batch_data = nil
    
    blocks_to_process.each_slice(batch_size).with_index do |batch, batch_idx|
      # Use prefetched data if available, otherwise fetch this batch
      if next_batch_data
        l1_data = next_batch_data
        next_batch_data = nil
      else
        l1_data = get_blocks_promises(batch)
      end
      
      # Start prefetching next batch while processing current one
      is_last_batch = (batch_idx == (blocks_to_process.length.to_f / batch_size).ceil - 1)
      if !is_last_batch
        next_batch_start = (batch_idx + 1) * batch_size
        next_batch_end = [next_batch_start + batch_size, blocks_to_process.length].min
        next_batch = blocks_to_process[next_batch_start...next_batch_end]
        
        # Start prefetching next batch in background
        next_batch_promise = Concurrent::Promise.execute do
          get_blocks_promises(next_batch)
        end
      end
      
      # Process each block sequentially (to maintain state consistency)
      batch.each do |l1_block_num|
        block_promise = l1_data[l1_block_num][:block]
        receipts_promise = l1_data[l1_block_num][:receipts]
        
        # Wait for promises
        block_result = block_promise.value!
        receipts = receipts_promise.value!
        
        # Process the block
        process_block_data(l1_block_num, block_result, receipts, verbose: verbose)
        
        processed += 1
        if !verbose && processed % 100 == 0
          elapsed = Time.now - start_time
          rate = processed / elapsed
          print "\rProcessed #{processed}/#{count} blocks (#{rate.round(1)} blocks/sec)..."
        end
      end
      
      # Get prefetched data for next iteration
      if !is_last_batch && next_batch_promise
        next_batch_data = next_batch_promise.value!
      end
    end
    
    elapsed = Time.now - start_time
    puts "\nSimulated #{count} blocks in #{elapsed.round(1)}s (#{(count/elapsed).round(1)} blocks/sec)"
    
    # Return summary
    {
      blocks_simulated: count,
      final_l2_block: @current_l2_block_number,
      final_total_minted: @simulated_attributes[@current_l2_block_number][:fct_total_minted],
      final_mint_rate: @simulated_attributes[@current_l2_block_number][:fct_mint_rate]
    }
  end
  
  def get_blocks_promises(block_numbers)
    block_numbers.map do |block_number|
      block_promise = Concurrent::Promise.execute do
        @l1_client.get_block(block_number, true)
      end
      
      receipts_promise = Concurrent::Promise.execute do
        @l1_client.get_transaction_receipts(block_number)
      end
      
      [block_number, {
        block: block_promise,
        receipts: receipts_promise
      }]
    end.to_h
  end
  
  def simulate_next_block(verbose: true)
    simulate_single_block(verbose: verbose)
  end
  
  def simulate_single_block(verbose: false)
    # Set or increment L1 block
    if @current_l1_block.nil?
      @current_l1_block = @initial_state ? @initial_state[:l1_block] : @l1_genesis_block
    else
      @current_l1_block += 1
    end
    
    # Get L1 block data
    block_result = @l1_client.get_block(@current_l1_block, true)
    
    # Get receipts for all transactions
    receipts = block_result['transactions'].map do |tx|
      @l1_client.get_transaction_receipt(tx['hash'])
    end
    
    process_block_data(@current_l1_block, block_result, receipts, verbose: verbose)
  end
  
  def process_block_data(l1_block_num, block_result, receipts, verbose: false)
    # Determine L2 block number
    if @current_l2_block_number.nil?
      # If we have initial state, start from the next block after it
      @current_l2_block_number = @initial_state ? @initial_state[:block_number] + 1 : 0
    else
      @current_l2_block_number += 1
    end
    
    puts "Simulating L2 block #{@current_l2_block_number} (from L1 block #{l1_block_num})..." if verbose
    
    # Initialize state if needed
    if @simulated_attributes.empty?
      initialize_from_current_state(verbose: verbose)
    end
    
    if verbose
      puts "L1 Block #{l1_block_num}:"
      puts "  Transactions: #{block_result['transactions'].length}"
      puts "  Base fee: #{block_result['baseFeePerGas'].to_i(16)}"
    end
    
    # Create block objects
    eth_block = EthBlock.from_rpc_result(block_result)
    facet_block = FacetBlock.from_eth_block(eth_block)
    facet_block.number = @current_l2_block_number
    
    # Get deposit transactions
    facet_txs = EthTransaction.facet_txs_from_rpc_results(block_result, receipts)
    puts "  Facet transactions: #{facet_txs.length}" if verbose
    
    # Run mint calculation
    puts "\nRunning mint calculation..." if verbose
    FctMintCalculator.assign_mint_amounts(facet_txs, facet_block)
    
    # Show results
    if verbose
      puts "\nResults for L2 block #{@current_l2_block_number}:"
      puts "  Total minted: #{facet_block.fct_total_minted} wei"
      puts "  Mint rate: #{facet_block.fct_mint_rate}"
      puts "  Period start: #{facet_block.fct_period_start_block}"
      puts "  Period minted: #{facet_block.fct_period_minted}"
      
      # Calculate attributes transaction mint
      attrs_tx_data = L1AttributesTxCalldata.build(facet_block)
      # attrs_gas = calculate_data_gas(attrs_tx_data.to_bin, facet_block.number)
      # attrs_burn = attrs_gas * facet_block.eth_block_base_fee_per_gas
      # attrs_mint = (attrs_burn * facet_block.fct_mint_rate / 1e18).to_i
      
      # puts "\nAttributes transaction:"
      # puts "  Data gas: #{attrs_gas}"
      # puts "  Burn: #{attrs_burn} wei"
      # puts "  Mint: #{attrs_mint} wei FCT"
      
      # Show individual transaction mints
      if facet_txs.any?
        puts "\nDeposit transactions:"
        facet_txs.each_with_index do |tx, i|
          puts "  Tx #{i}: #{tx.mint} wei FCT"
        end
      else
        puts "\nNo deposit transactions in this block"
      end
    end
    
    # Store for next block
    store_attributes(facet_block)
    
    # Store the L2 block mapping
    @simulated_l2_blocks[@current_l2_block_number] = {
      l1_block: l1_block_num,
      facet_block: facet_block
    }
    
    facet_block
  end
  
  def setup_mock_geth_client
    simulator = self
    
    # Create a mock Geth client
    mock_client = Object.new
    mock_client.define_singleton_method(:get_l1_attributes) do |block_number|
      simulator.get_simulated_attributes(block_number)
    end
    
    FctMintCalculator.instance_variable_set(:@_client, mock_client)
  end
  
  # Store original constants for restoration
  ORIGINAL_CONSTANTS = {
    period_length: FctMintCalculator::ADJUSTMENT_PERIOD_TARGET_LENGTH,
    max_up_factor: FctMintCalculator::MAX_RATE_ADJUSTMENT_UP_FACTOR,
    max_down_factor: FctMintCalculator::MAX_RATE_ADJUSTMENT_DOWN_FACTOR,
    min_rate: FctMintCalculator::MIN_MINT_RATE,
    max_rate: FctMintCalculator::MAX_MINT_RATE
  }.freeze

  # Patch constants for testing different parameters
  def patch_constants(period_length: nil, max_up_factor: nil, max_down_factor: nil, 
                     target_per_period: nil, min_rate: nil, max_rate: nil)
    @patched_constants = {}
    
    if period_length
      @patched_constants[:period_length] = FctMintCalculator::ADJUSTMENT_PERIOD_TARGET_LENGTH
      FctMintCalculator.send(:remove_const, :ADJUSTMENT_PERIOD_TARGET_LENGTH)
      FctMintCalculator.const_set(:ADJUSTMENT_PERIOD_TARGET_LENGTH, Rational(period_length))
    end
    
    if max_up_factor
      @patched_constants[:max_up_factor] = FctMintCalculator::MAX_RATE_ADJUSTMENT_UP_FACTOR
      FctMintCalculator.send(:remove_const, :MAX_RATE_ADJUSTMENT_UP_FACTOR)
      FctMintCalculator.const_set(:MAX_RATE_ADJUSTMENT_UP_FACTOR, Rational(max_up_factor))
    end
    
    if max_down_factor
      @patched_constants[:max_down_factor] = FctMintCalculator::MAX_RATE_ADJUSTMENT_DOWN_FACTOR
      FctMintCalculator.send(:remove_const, :MAX_RATE_ADJUSTMENT_DOWN_FACTOR)
      FctMintCalculator.const_set(:MAX_RATE_ADJUSTMENT_DOWN_FACTOR, Rational(max_down_factor))
    end
    
    if target_per_period
      @patched_constants[:target_per_period] = FctMintCalculator.const_defined?(:TARGET_PER_PERIOD) ? 
        FctMintCalculator::TARGET_PER_PERIOD : nil
      FctMintCalculator.send(:remove_const, :TARGET_PER_PERIOD) if FctMintCalculator.const_defined?(:TARGET_PER_PERIOD)
      FctMintCalculator.const_set(:TARGET_PER_PERIOD, Rational(target_per_period))
    end
    
    if min_rate
      @patched_constants[:min_rate] = FctMintCalculator::MIN_MINT_RATE
      FctMintCalculator.send(:remove_const, :MIN_MINT_RATE)
      FctMintCalculator.const_set(:MIN_MINT_RATE, Rational(min_rate))
    end
    
    if max_rate
      @patched_constants[:max_rate] = FctMintCalculator::MAX_MINT_RATE
      FctMintCalculator.send(:remove_const, :MAX_MINT_RATE)
      FctMintCalculator.const_set(:MAX_MINT_RATE, Rational(max_rate))
    end
  end
  
  # Restore original constants
  def restore_constants
    return unless @patched_constants
    
    @patched_constants.each do |key, original_value|
      case key
      when :period_length
        FctMintCalculator.send(:remove_const, :ADJUSTMENT_PERIOD_TARGET_LENGTH)
        FctMintCalculator.const_set(:ADJUSTMENT_PERIOD_TARGET_LENGTH, original_value)
      when :max_up_factor
        FctMintCalculator.send(:remove_const, :MAX_RATE_ADJUSTMENT_UP_FACTOR)
        FctMintCalculator.const_set(:MAX_RATE_ADJUSTMENT_UP_FACTOR, original_value)
      when :max_down_factor
        FctMintCalculator.send(:remove_const, :MAX_RATE_ADJUSTMENT_DOWN_FACTOR)
        FctMintCalculator.const_set(:MAX_RATE_ADJUSTMENT_DOWN_FACTOR, original_value)
      when :target_per_period
        if original_value
          FctMintCalculator.send(:remove_const, :TARGET_PER_PERIOD) if FctMintCalculator.const_defined?(:TARGET_PER_PERIOD)
          FctMintCalculator.const_set(:TARGET_PER_PERIOD, original_value)
        end
      when :min_rate
        FctMintCalculator.send(:remove_const, :MIN_MINT_RATE)
        FctMintCalculator.const_set(:MIN_MINT_RATE, original_value)
      when :max_rate
        FctMintCalculator.send(:remove_const, :MAX_MINT_RATE)
        FctMintCalculator.const_set(:MAX_MINT_RATE, original_value)
      end
    end
    
    @patched_constants = nil
  end
  
  # Run a block with patched constants, ensuring they're restored afterward
  def with_constants(**constants)
    patch_constants(**constants)
    yield
  ensure
    restore_constants
  end
  
  # Generate snapshot analysis from already simulated data
  def generate_snapshot_analysis(output_file: nil, snap_interval: 1000)
    raise "No simulation data available. Run simulate_blocks_minimal first." if @simulated_attributes.empty?
    
    puts "\nGenerating snapshot analysis from simulated data..."
    puts "Snapshot interval: #{snap_interval} blocks"
    puts "-" * 60
    
    # Get block range from simulated data
    blocks = @simulated_attributes.keys.sort
    start_block = blocks.first
    end_block = blocks.last
    
    # Build snapshot blocks
    snapshot_blocks = build_snapshot_blocks(start_block, end_block, snap_interval)
    puts "Total snapshots: #{snapshot_blocks.length}"
    
    snapshots = []
    prev_snapshot = nil
    
    # Process each snapshot point
    snapshot_blocks.each_with_index do |block_num, idx|
      # Find the closest block we have data for
      actual_block = blocks.select { |b| b <= block_num }.max
      next unless actual_block
      
      state = @simulated_attributes[actual_block]
      next unless state
      
      # Calculate metrics
      total_minted_eth = state[:fct_total_minted] / 1e18.to_f
      mint_rate = state[:fct_mint_rate]  # Already in wei FCT per gas
      # Calculate theoretical schedule
      schedule_total = calculate_theoretical_schedule(actual_block)
      schedule_total_eth = schedule_total / 1e18.to_f
      supply_delta_pct = if schedule_total_eth > 0
        ((total_minted_eth - schedule_total_eth) / schedule_total_eth * 100).round(3)
      else
        0.0  # At fork block, both should be 0
      end
      
      # Pace calculation
      if prev_snapshot
        blocks_since_last = actual_block - prev_snapshot[:block]
        minted_since_last = state[:fct_total_minted] - prev_snapshot[:total_minted]
        minted_since_last_eth = minted_since_last / 1e18.to_f
        
        expected_since_last = calculate_theoretical_schedule(actual_block) - 
                             calculate_theoretical_schedule(prev_snapshot[:block])
        expected_mint_eth = expected_since_last / 1e18.to_f
        
        pace_delta_pct = expected_mint_eth > 0 ? 
          ((minted_since_last_eth - expected_mint_eth) / expected_mint_eth * 100).round(3) : 0
        
        rate_change_factor = prev_snapshot[:mint_rate] > 0 ? 
          (mint_rate.to_f / prev_snapshot[:mint_rate]).round(6) : 0
      else
        minted_since_last_eth = 0
        expected_mint_eth = 0
        pace_delta_pct = 0
        rate_change_factor = 1
      end
      
      snapshot = {
        block: actual_block,
        timestamp: 0,
        total_minted_eth: total_minted_eth.round(6),
        schedule_total_eth: schedule_total_eth.round(6),
        supply_delta_pct: supply_delta_pct,
        minted_since_last_eth: minted_since_last_eth.round(6),
        expected_mint_eth: expected_mint_eth.round(6),
        pace_delta_pct: pace_delta_pct,
        mint_rate: mint_rate,  # In wei FCT/gas
        rate_change_factor: rate_change_factor,
        total_minted: state[:fct_total_minted]
      }
      
      snapshots << snapshot
      prev_snapshot = snapshot
    end
    
    # Save to CSV if requested
    if output_file
      require 'csv'
      CSV.open(output_file, 'w') do |csv|
        headers = ['block', 'timestamp', 'total_minted_eth', 'schedule_total_eth', 'supply_delta_pct',
                   'minted_since_last_eth', 'expected_mint_eth', 'pace_delta_pct',
                   'mint_rate', 'rate_change_factor']
        csv << headers
        
        snapshots.each do |snapshot|
          csv << headers.map { |h| snapshot[h.to_sym] }
        end
      end
      puts "Saved #{snapshots.length} snapshots to #{output_file}"
    end
    
    print_snapshot_summary(snapshots)
    snapshots
  end
  
  # Compare snapshots from different parameter configurations
  def self.compare_parameter_snapshots(parameter_sets, blocks_to_simulate: 100_000, 
                                      cache_file: 'tmp/l1_minimal_cache.ndjson',
                                      snap_interval: 1000)
    results = {}
    
    parameter_sets.each do |param_set|
      name = param_set.delete(:name) || param_set.inspect
      puts "\n" + "="*60
      puts "Simulating: #{name}"
      puts "Parameters: #{param_set.inspect}"
      
      # Create fresh simulator
      sim = from_fork
      
      # If period_length is being changed, also adjust target_per_period
      adjusted_params = param_set.dup
      if param_set[:period_length]
        # Calculate adjusted target to maintain same overall issuance rate
        blocks_in_halving = 2_628_000
        max_supply = 750_000_000 * 1e18
        target_supply_first_halving = max_supply / 2
        periods_in_halving = blocks_in_halving / param_set[:period_length].to_f
        adjusted_target = (target_supply_first_halving / periods_in_halving).to_i
        adjusted_params[:target_per_period] = adjusted_target
      end
      
      # Run simulation with patched constants in a safe block
      sim.with_constants(**adjusted_params) do
        # Run full simulation
        result = sim.simulate_blocks_minimal(blocks_to_simulate, cache_file: cache_file)
        
        # Generate snapshots from simulated data
        snapshots = sim.generate_snapshot_analysis(snap_interval: snap_interval)
        
        results[name] = {
          parameters: param_set,
          snapshots: snapshots,
          final_state: result
        }
      end
    end
    
    # Generate comparison CSV
    generate_comparison_csv(results, "tmp/parameter_comparison_#{Time.now.to_i}.csv")
    
    results
  end
  
  private
  
  def self.generate_comparison_csv(results, output_file)
    require 'csv'
    
    # Get all unique blocks across all results
    all_blocks = results.values
      .flat_map { |r| r[:snapshots].map { |s| s[:block] } }
      .uniq
      .sort
    
    CSV.open(output_file, 'w') do |csv|
      # Build headers
      headers = ['block']
      results.each_key do |name|
        headers += [
          "#{name}_total_minted",
          "#{name}_supply_delta_pct", 
          "#{name}_pace_delta_pct",
          "#{name}_mint_rate"
        ]
      end
      csv << headers
      
      # Write data rows
      all_blocks.each do |block|
        row = [block]
        
        results.each do |name, data|
          snapshot = data[:snapshots].find { |s| s[:block] == block }
          if snapshot
            row += [
              snapshot[:total_minted_eth],
              snapshot[:supply_delta_pct],
              snapshot[:pace_delta_pct],
              snapshot[:mint_rate]
            ]
          else
            row += [nil, nil, nil, nil]
          end
        end
        
        csv << row
      end
    end
    
    puts "\nComparison saved to: #{output_file}"
    
    # Print summary
    puts "\n" + "="*80
    puts "PARAMETER COMPARISON SUMMARY"
    puts "="*80
    
    results.each do |name, data|
      final = data[:final_state]
      last_snapshot = data[:snapshots].last
      
      puts "\n#{name}:"
      puts "  Final total: #{(final[:final_total_minted] / 1e18).round(2)} FCT"
      puts "  Final rate: #{(final[:final_mint_rate] / 1e18).round(6)} FCT/gas"
      puts "  Supply delta: #{last_snapshot[:supply_delta_pct]}%"
    end
  end
  
  # Build snapshot blocks matching FctDataCollectorRails logic
  def build_snapshot_blocks(start_block, end_block, snap_interval)
    blocks = Set.new
    
    # Always include block 0 if in range
    blocks << 0 if start_block <= 0
    
    # Include fork block (2)
    blocks << 2 if start_block <= 2 && end_block >= 2
    
    # Add regular snapshots
    current = ((start_block / snap_interval.to_f).ceil * snap_interval)
    while current <= end_block
      blocks << current
      current += snap_interval
    end
    
    # Add halving boundaries
    blocks_in_halving = 2_628_000
    k = 1
    loop do
      halving_block = k * blocks_in_halving
      break if halving_block > end_block
      blocks << halving_block if halving_block >= start_block
      k += 1
    end
    
    # Always include the last block
    blocks << end_block
    
    blocks.to_a.sort
  end
  
  def calculate_theoretical_schedule(block_num)
    return 0 if block_num <= 0
    
    # Account for fork block - minting starts at block 2 in immediate mode
    fork_block = @initial_state ? @initial_state[:block_number] : FORK_BLOCK_STATE[:block_number]
    effective_blocks = block_num - fork_block
    return 0 if effective_blocks <= 0
    
    # Get current period length (might be patched)
    blocks_per_period = FctMintCalculator::ADJUSTMENT_PERIOD_TARGET_LENGTH
    blocks_in_halving = 2_628_000
    
    # Calculate target per period based on current period length
    # This maintains the same overall issuance rate regardless of period length
    max_supply = 750_000_000 * 1e18  # 750M FCT
    target_supply_first_halving = max_supply / 2
    periods_in_halving = blocks_in_halving / blocks_per_period.to_f
    target_per_period = target_supply_first_halving / periods_in_halving
    
    if effective_blocks <= blocks_in_halving
      periods = effective_blocks / blocks_per_period.to_f
      return (periods * target_per_period).round
    end
    
    total = 0
    remaining_blocks = effective_blocks
    halving_level = 0
    
    while remaining_blocks > 0
      blocks_in_this_level = [remaining_blocks, blocks_in_halving].min
      periods_in_this_level = blocks_in_this_level / blocks_per_period.to_f
      mint_per_period = target_per_period / (2 ** halving_level)
      
      total += periods_in_this_level * mint_per_period
      
      remaining_blocks -= blocks_in_this_level
      halving_level += 1
    end
    
    total.round
  end
  
  def print_snapshot_summary(snapshots)
    return if snapshots.empty?
    
    puts "\n" + "="*80
    puts "SNAPSHOT ANALYSIS SUMMARY"
    puts "="*80
    
    final = snapshots.last
    puts "\nFinal State (Block #{final[:block]}):"
    puts "  Total Minted: #{final[:total_minted_eth]} FCT"
    puts "  Theoretical: #{final[:schedule_total_eth]} FCT"
    puts "  Supply Delta: #{final[:supply_delta_pct]}%"
    puts "  Mint Rate: #{final[:mint_rate]} wei FCT/gas"
    
    # Skip snapshots with NaN or nil supply_delta_pct
    valid_snapshots = snapshots.select { |s| s[:supply_delta_pct] && !s[:supply_delta_pct].nan? }
    
    if valid_snapshots.any?
      max_positive_supply = valid_snapshots.max_by { |s| s[:supply_delta_pct] }
      max_negative_supply = valid_snapshots.min_by { |s| s[:supply_delta_pct] }
      
      puts "\nMax Supply Deviations:"
      puts "  Positive: +#{max_positive_supply[:supply_delta_pct]}% (block #{max_positive_supply[:block]})"
      puts "  Negative: #{max_negative_supply[:supply_delta_pct]}% (block #{max_negative_supply[:block]})"
    end
  end
  
  public
  
  def initialize_from_current_state(verbose: true)
    # When starting from block 2, we need the state AT block 2, not block 1
    # This represents the state after block 2 has been processed
    state_block = @initial_state ? @initial_state[:block_number] : @current_l2_block_number - 1
    
    puts "Initializing state for block #{state_block}..." if verbose
    
    if @initial_state
      # Use provided initial state (Bluebird is active from block 2)
      @simulated_attributes[state_block] = {
        fct_total_minted: @initial_state[:fct_total_minted],
        fct_mint_rate: @initial_state[:fct_mint_rate],
        fct_period_start_block: @initial_state[:fct_period_start_block],
        fct_period_minted: @initial_state[:fct_period_minted],
        fct_mint_period_l1_data_gas: 0,
        sequence_number: 0,
        number: state_block,
        timestamp: 0,
        base_fee: 1
      }
      puts "Initialized with provided state:" if verbose
      puts "  Total minted: #{@initial_state[:fct_total_minted]} (#{(@initial_state[:fct_total_minted] / 1e18).round(2)} FCT)" if verbose
      puts "  Mint rate: #{@initial_state[:fct_mint_rate]}" if verbose
      puts "  Pace delta: #{(@initial_state[:pace_delta] * 100).round(2)}%" if verbose && @initial_state[:pace_delta]
    else
      raise "Initial state required - use FctMintSimulator.from_fork to start from fork block"
    end
  end
  
  def store_attributes(facet_block)
    @simulated_attributes[facet_block.number] = {
      fct_total_minted: facet_block.fct_total_minted,
      fct_mint_rate: facet_block.fct_mint_rate,
      fct_period_start_block: facet_block.fct_period_start_block,
      fct_period_minted: facet_block.fct_period_minted,
      fct_mint_period_l1_data_gas: 0,
      sequence_number: facet_block.sequence_number || 0,
      hash: facet_block.eth_block_hash,
      number: facet_block.eth_block_number,
      timestamp: facet_block.eth_block_timestamp,
      base_fee: facet_block.eth_block_base_fee_per_gas
    }
  end
  
  public
  
  def get_simulated_attributes(block_number)
    @simulated_attributes[block_number] || raise("No attributes for block #{block_number}")
  end
  
  def stats
    return {} if @simulated_attributes.empty?
    
    current_attrs = @simulated_attributes[@current_l2_block_number]
    return {} unless current_attrs
    
    {
      current_l2_block: @current_l2_block_number,
      current_l1_block: @current_l1_block,
      total_minted: current_attrs[:fct_total_minted],
      total_minted_fct: (current_attrs[:fct_total_minted] / 1e18).round(2),
      mint_rate: current_attrs[:fct_mint_rate],
      period_start: current_attrs[:fct_period_start_block],
      period_minted: current_attrs[:fct_period_minted],
      blocks_simulated: @simulated_l2_blocks.length
    }
  end
  
  # Create a simulator starting from the fork
  def self.from_fork
    # Start directly from block 2 (the fork block)
    new(initial_state: FORK_BLOCK_STATE)
  end
  
  # Cache only essential L1 data for FCT minting
  def self.cache_l1_minimal(count, output_file: 'tmp/l1_minimal_cache.ndjson', batch_size: 30)
    puts "Caching minimal L1 data for #{count} blocks..."
    
    # Start from the L1 block we need for simulating (fork block + 1)
    # When simulating from L2 block 2, the first block we simulate is L2 block 3,
    # which needs L1 block 21373003
    start_l1_block = FORK_BLOCK_STATE[:l1_block] + 1
    end_l1_block = start_l1_block + count - 1
    
    # Check if file exists and find the last block
    last_cached_block = nil
    if File.exist?(output_file)
      puts "Found existing cache file, checking last block..."
      # Read the last line to get the last block number
      last_line = nil
      File.foreach(output_file) { |line| last_line = line }
      
      if last_line
        last_data = Oj.load(last_line)
        last_cached_block = last_data['l1_block']
        puts "Last cached block: #{last_cached_block}"
        
        # Adjust start block to continue from where we left off
        if last_cached_block >= start_l1_block
          start_l1_block = last_cached_block + 1
          puts "Resuming from block #{start_l1_block}"
        end
        
        if start_l1_block > end_l1_block
          puts "Already have all #{count} blocks cached!"
          return
        end
      end
    end
    
    # Create a temporary simulator instance
    sim = new(initial_state: FORK_BLOCK_STATE)
    start_time = Time.now
    processed = last_cached_block ? (last_cached_block - FORK_BLOCK_STATE[:l1_block]) : 0
    newly_processed = 0
    
    FileUtils.mkdir_p(File.dirname(output_file))
    
    # Open in append mode if we're resuming, write mode if starting fresh
    mode = last_cached_block ? 'a' : 'w'
    out = File.open(output_file, mode)
    
    (start_l1_block..end_l1_block).each_slice(batch_size) do |batch|
      # Fetch blocks and receipts
      l1_data = sim.get_blocks_promises(batch)
      
      batch.each do |l1_block_num|
        block_result = l1_data[l1_block_num][:block].value!
        receipts = l1_data[l1_block_num][:receipts].value!
        
        # Extract only what we need for minting calculation
        eth_block = EthBlock.from_rpc_result(block_result)
        facet_txs = EthTransaction.facet_txs_from_rpc_results(block_result, receipts)
        
        # Build minimal data structure
        minimal_data = {
          l1_block: l1_block_num,
          base_fee: eth_block.base_fee_per_gas,
          timestamp: eth_block.timestamp,
          block_hash: eth_block.block_hash.to_hex,
          parent_beacon_block_root: eth_block.parent_beacon_block_root.to_hex,
          mix_hash: eth_block.mix_hash.to_hex,
          parent_hash: eth_block.parent_hash.to_hex,
          facet_txs: facet_txs.map do |tx|
            {
              contract_initiated: tx.contract_initiated,
              input_size: tx.eth_transaction_input.to_bin.bytesize,
              input_hex: tx.eth_transaction_input.to_hex,
              from: tx.from_address.to_hex,
              to: tx.to_address&.to_hex
            }
          end
        }
        
        # Write as NDJSON
        out.puts Oj.dump(minimal_data, mode: :compat)
        
        newly_processed += 1
        processed += 1
        if processed % 100 == 0
          out.flush  # Flush periodically to ensure data is saved
          elapsed = Time.now - start_time
          rate = newly_processed / elapsed
          print "\rProcessed #{processed}/#{count} blocks (#{rate.round(1)} blocks/sec)..."
        end
      end
      
      # Flush after each batch
      out.flush
    end
    
    elapsed = Time.now - start_time
    file_size_mb = File.size(output_file) / 1024.0 / 1024.0
    new_blocks = processed - (last_cached_block ? (last_cached_block - FORK_BLOCK_STATE[:l1_block]) : 0)
    puts "\nCached #{new_blocks} new blocks in #{elapsed.round(1)}s (total: #{processed} blocks, #{file_size_mb.round(1)} MB)"
  ensure
    out&.close
  end
  
  # Load minimal cache and reconstruct facet transactions
  def preload_minimal_cache(cache_file: 'tmp/l1_minimal_cache.ndjson')
    # Check if cache already loaded at class level
    if self.class.minimal_cache
      @minimal_cache = self.class.minimal_cache
      return @minimal_cache.size
    end
    
    unless File.exist?(cache_file)
      raise "Minimal cache not found: #{cache_file}. Run cache_l1_minimal first."
    end
    
    puts "Loading minimal cache from #{cache_file}..."
    start_time = Time.now
    
    cache = {}
    
    File.foreach(cache_file) do |line|
      data = Oj.load(line)
      cache[data['l1_block']] = data
    end
    
    elapsed = Time.now - start_time
    loaded = cache.size
    puts "Loaded #{loaded} blocks in #{elapsed.round(2)}s (#{(loaded/elapsed).round(0)} blocks/sec)"
    
    # Store at class level for reuse
    self.class.minimal_cache = cache
    @minimal_cache = cache
    
    loaded
  end
  
  # Process block using minimal cached data
  def process_minimal_block_data(l1_block_num, minimal_data, verbose: false)
    # Determine L2 block number
    if @current_l2_block_number.nil?
      @current_l2_block_number = @initial_state ? @initial_state[:block_number] + 1 : 0
    else
      @current_l2_block_number += 1
    end
    
    puts "Simulating L2 block #{@current_l2_block_number} (from L1 block #{l1_block_num})..." if verbose
    
    # Initialize state if needed
    if @simulated_attributes.empty?
      initialize_from_current_state(verbose: verbose)
    end
    
    # Create minimal block objects
    eth_block = EthBlock.new(
      block_hash: Hash32.from_hex(minimal_data['block_hash']),
      number: l1_block_num,
      timestamp: minimal_data['timestamp'],
      base_fee_per_gas: minimal_data['base_fee'],
      parent_beacon_block_root: Hash32.from_hex(minimal_data['parent_beacon_block_root']),
      mix_hash: Hash32.from_hex(minimal_data['mix_hash']),
      parent_hash: Hash32.from_hex(minimal_data['parent_hash'])
    )
    
    facet_block = FacetBlock.from_eth_block(eth_block)
    facet_block.number = @current_l2_block_number
    
    # Reconstruct facet transactions
    facet_txs = minimal_data['facet_txs'].map do |tx_data|
      tx = FacetTransaction.new
      tx.contract_initiated = tx_data['contract_initiated']
      tx.eth_transaction_input = ByteString.from_hex(tx_data['input_hex'])
      tx.from_address = Address20.from_hex(tx_data['from'])
      tx.to_address = tx_data['to'] ? Address20.from_hex(tx_data['to']) : nil
      tx
    end
    
    puts "  Facet transactions: #{facet_txs.length}" if verbose
    
    # Run mint calculation
    FctMintCalculator.assign_mint_amounts(facet_txs, facet_block)
    
    # Store for next block
    store_attributes(facet_block)
    
    # Store the L2 block mapping
    @simulated_l2_blocks[@current_l2_block_number] = {
      l1_block: l1_block_num,
      facet_block: facet_block
    }
    
    facet_block
  end
  
  # Version using minimal cache
  def simulate_blocks_minimal(count, cache_file: 'tmp/l1_minimal_cache.ndjson', verbose: false)
    # Load cache if not already loaded
    if @minimal_cache.nil?
      preload_minimal_cache(cache_file: cache_file)
    end
    
    puts "Simulating #{count} blocks using minimal cache..."
    start_time = Time.now
    processed = 0
    
    count.times do |i|
      # Set or increment L1 block
      if @current_l1_block.nil?
        @current_l1_block = @initial_state ? @initial_state[:l1_block] : @l1_genesis_block
      else
        @current_l1_block += 1
      end
      
      # Get minimal data
      minimal_data = @minimal_cache[@current_l1_block]
      unless minimal_data
        puts "\nNo cached data for L1 block #{@current_l1_block}. Stopping."
        break
      end
      
      process_minimal_block_data(@current_l1_block, minimal_data, verbose: verbose)
      processed += 1
      
      if !verbose && processed % 1000 == 0
        elapsed = Time.now - start_time
        rate = processed / elapsed
        print "\rProcessed #{processed}/#{count} blocks (#{rate.round(1)} blocks/sec)..."
      end
    end
    
    elapsed = Time.now - start_time
    puts "\nSimulated #{processed} blocks in #{elapsed.round(1)}s (#{(processed/elapsed).round(1)} blocks/sec)"
    
    # Return results only if we processed at least one block
    if processed > 0 && @current_l2_block_number && @simulated_attributes[@current_l2_block_number]
      {
        blocks_simulated: processed,
        final_l2_block: @current_l2_block_number,
        final_total_minted: @simulated_attributes[@current_l2_block_number][:fct_total_minted],
        final_mint_rate: @simulated_attributes[@current_l2_block_number][:fct_mint_rate]
      }
    else
      {
        blocks_simulated: processed,
        final_l2_block: nil,
        final_total_minted: nil,
        final_mint_rate: nil
      }
    end
  end
  
end