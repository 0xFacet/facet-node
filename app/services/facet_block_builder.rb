# Builds the final transaction order for an L2 block
# Implements Steps 2-3 of the derivation rules
class FacetBlockBuilder
  attr_reader :collected, :l2_block_gas_limit, :get_authorized_signer, :logger
  
  def initialize(collected:, l2_block_gas_limit:, get_authorized_signer: nil, logger: Rails.logger)
    @collected = collected
    @l2_block_gas_limit = l2_block_gas_limit
    @get_authorized_signer = get_authorized_signer || method(:default_authorized_signer)
    @logger = logger
  end
  
  # Build the ordered list of transactions for the L2 block
  # Returns array of FacetTransaction objects
  def ordered_transactions(l1_block_number)
    transactions = []
    
    # Step 2: Select priority batch (if any)
    priority_batch = select_priority_batch(l1_block_number)
    
    if priority_batch
      logger.info "Selected priority batch from #{priority_batch.source_description} with #{priority_batch.transaction_count} txs"
      
      # Add all transactions from priority batch first
      priority_batch.transactions.each do |tx_bytes|
        facet_tx = create_facet_transaction(tx_bytes, priority_batch)
        transactions << facet_tx if facet_tx
      end
      logger.debug "After adding priority batch: #{transactions.length} total transactions"
    else
      logger.debug "No priority batch selected for block #{l1_block_number}"
    end
    
    # Step 3: Add permissionless transactions
    permissionless_sources = collect_permissionless_sources(priority_batch)
    
    # Sort by L1 transaction index
    permissionless_sources.sort_by! { |source| source[:l1_tx_index] }
    
    # Unwrap transactions from each source
    logger.debug "Processing #{permissionless_sources.length} permissionless sources"
    permissionless_sources.each do |source|
      case source[:type]
      when :single
        # V1 single transaction
        facet_tx = create_v1_transaction(source[:data])
        transactions << facet_tx if facet_tx
      when :batch
        # Forced batch - unwrap all transactions
        logger.debug "Processing forced batch with #{source[:data].transactions.length} transactions"
        source[:data].transactions.each do |tx_bytes|
          facet_tx = create_facet_transaction(tx_bytes, source[:data])
          if facet_tx
            transactions << facet_tx
            logger.debug "Added transaction from forced batch, now have #{transactions.length} total"
          else
            logger.debug "Failed to create transaction from forced batch"
          end
        end
      end
    end
    
    # Build informative summary
    if transactions.length > 0
      priority_count = priority_batch ? priority_batch.transaction_count : 0
      forced_count = transactions.length - priority_count

      parts = []
      parts << "#{priority_count} priority" if priority_count > 0
      parts << "#{forced_count} permissionless" if forced_count > 0

      logger.info "Block #{l1_block_number}: Built with #{transactions.length} txs (#{parts.join(', ')})"
    else
      logger.debug "Block #{l1_block_number}: No transactions to include"
    end
    
    transactions
  end
  
  private
  
  def select_priority_batch(l1_block_number)
    # Filter for priority batches
    priority_batches = collected.batches.select(&:is_priority?)
    
    return nil if priority_batches.empty?
    
    # Get authorized signer for this block
    authorized_signer = get_authorized_signer.call(l1_block_number)
    
    # Filter for eligible batches
    eligible_batches = if SysConfig.enable_sig_verify? && authorized_signer
      priority_batches.select { |b| b.signer == authorized_signer }
    else
      # For testing without signatures
      priority_batches
    end
    
    if eligible_batches.empty?
      logger.debug "No eligible priority batches (#{priority_batches.length} priority batches found)"
      return nil
    end
    
    # Select batch with lowest L1 transaction index
    selected = eligible_batches.min_by(&:l1_tx_index)
    
    # Gas validation
    total_gas = calculate_batch_gas(selected)
    priority_limit = (l2_block_gas_limit * SysConfig::PRIORITY_SHARE_BPS) / 10_000
    
    if total_gas > priority_limit
      logger.warn "Priority batch exceeds gas limit: #{total_gas} > #{priority_limit}, discarding"
      return nil
    end
    
    selected
  end
  
  def collect_permissionless_sources(priority_batch)
    sources = []
    
    logger.debug "Collecting permissionless sources. Total batches: #{collected.batches.length}"
    
    # Add all forced batches
    collected.batches.each do |batch|
      logger.debug "Batch role: #{batch.role}, is_priority: #{batch.is_priority?}, tx_count: #{batch.transaction_count}"
      if batch.is_priority?
        logger.debug "Skipping priority batch with #{batch.transaction_count} txs"
        next  # Skip priority batches
      end
      next if priority_batch && batch.content_hash == priority_batch.content_hash  # Skip selected priority
      
      logger.debug "Adding forced batch with #{batch.transaction_count} txs to permissionless sources"
      sources << {
        type: :batch,
        l1_tx_index: batch.l1_tx_index,
        data: batch
      }
    end
    
    # Add all V1 single transactions
    collected.single_txs.each do |single|
      sources << {
        type: :single,
        l1_tx_index: single[:l1_tx_index],
        data: single
      }
    end
    
    sources
  end
  
  def calculate_batch_gas(batch)
    # Calculate total gas for all transactions in batch
    # This is simplified - in production would parse each transaction
    total_gas = 0
    
    batch.transactions.each do |tx_bytes|
      # Parse transaction to get gas limit
      gas_limit = parse_transaction_gas_limit(tx_bytes)
      # Skip transactions with 0 gas (they'll be excluded anyway)
      next if gas_limit == 0
      total_gas += gas_limit
    end
    
    total_gas
  end
  
  def parse_transaction_gas_limit(tx_bytes)
    # Parse EIP-2718 typed transaction to extract gas limit
    tx_type = tx_bytes.to_bin[0].ord
    
    case tx_type
    when 0x02  # EIP-1559 transaction
      # Skip type byte and decode RLP
      rlp_data = tx_bytes.to_bin[1..-1]
      decoded = Eth::Rlp.decode(rlp_data)
      
      # EIP-1559 format: [chain_id, nonce, max_priority_fee, max_fee, gas_limit, to, value, data, access_list, ...]
      # gas_limit is at index 4
      gas_limit = decoded[4].empty? ? 0 : decoded[4].unpack1('H*').to_i(16)
      if gas_limit == 0
        logger.warn "Rejecting EIP-1559 transaction with 0 gas limit"
        return 0  # Will cause transaction to be excluded
      end
      gas_limit
      
    when 0x01  # EIP-2930 transaction (access list)
      # Skip type byte and decode RLP
      rlp_data = tx_bytes.to_bin[1..-1]
      decoded = Eth::Rlp.decode(rlp_data)
      
      # EIP-2930 format: [chain_id, nonce, gas_price, gas_limit, to, value, data, access_list, ...]
      # gas_limit is at index 3
      gas_limit = decoded[3].empty? ? 0 : decoded[3].unpack1('H*').to_i(16)
      if gas_limit == 0
        logger.warn "Rejecting EIP-2930 transaction with 0 gas limit"
        return 0  # Will cause transaction to be excluded
      end
      gas_limit
      
    when 0x00, nil  # Legacy transaction (no type byte)
      # Legacy transactions don't have a type byte, decode directly
      decoded = Eth::Rlp.decode(tx_bytes.to_bin)
      
      # Legacy format: [nonce, gas_price, gas_limit, to, value, data, v, r, s]
      # gas_limit is at index 2
      gas_limit = decoded[2].empty? ? 0 : decoded[2].unpack1('H*').to_i(16)
      if gas_limit == 0
        logger.warn "Rejecting legacy transaction with 0 gas limit"
        return 0  # Will cause transaction to be excluded
      end
      gas_limit
      
    else
      # Unknown transaction type, use default
      logger.warn "Unknown transaction type: 0x#{tx_type.to_s(16)}"
      21_000
    end
  rescue => e
    logger.error "Failed to parse transaction gas limit: #{e.message}"
    21_000  # Default fallback
  end
  
  def create_facet_transaction(tx_bytes, batch)
    # Create StandardL2Transaction from raw bytes
    # These are standard EIP-2718 typed transactions (EIP-1559, EIP-2930, legacy)
    StandardL2Transaction.from_raw_bytes(tx_bytes)
  rescue => e
    logger.error "Failed to create transaction from batch: #{e.message}"
    logger.error "Transaction bytes (hex): #{tx_bytes.to_hex[0..100]}..."
    logger.error e.backtrace.first(5).join("\n")
    nil
  end
  
  def create_v1_transaction(single_tx_data)
    # Create FacetTransaction from V1 single format
    
    if single_tx_data[:source] == 'calldata'
      # Direct calldata submission
      # Use L1 sender address for mint attribution
      from_address = if single_tx_data[:from_address]
        Address20.from_hex(single_tx_data[:from_address])
      else
        Address20.from_hex("0x" + "0" * 40)  # Fallback to zero if not provided
      end
      
      FacetTransaction.from_payload(
        contract_initiated: false,
        from_address: from_address,
        eth_transaction_input: single_tx_data[:payload],
        tx_hash: Hash32.from_hex(single_tx_data[:tx_hash])
      )
    else
      # Event-based submission
      # Process first event (V1 doesn't support multiple)
      event = single_tx_data[:events].first
      return nil unless event
      
      FacetTransaction.from_payload(
        contract_initiated: true,
        from_address: Address20.from_hex(event[:address]),
        eth_transaction_input: event[:payload],
        tx_hash: Hash32.from_hex(single_tx_data[:tx_hash])
      )
    end
  rescue => e
    logger.error "Failed to create V1 transaction: #{e.message}"
    nil
  end
  
  def default_authorized_signer(block_number)
    # Default implementation for testing
    # In production, this would query a registry or configuration
    
    if ENV['PRIORITY_SIGNER_ADDRESS']
      Address20.from_hex(ENV['PRIORITY_SIGNER_ADDRESS'])
    else
      nil
    end
  end
end