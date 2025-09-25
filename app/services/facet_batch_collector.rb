# Collects Facet transactions from all sources (calldata, events, blobs)
# Implements Step 1 of the derivation rules
class FacetBatchCollector
  attr_reader :eth_block, :receipts, :blob_provider, :parser, :logger
  
  CollectorResult = Struct.new(:single_txs, :batches, :stats, keyword_init: true)
  
  def initialize(eth_block:, receipts:, blob_provider: nil, logger: Rails.logger)
    @eth_block = eth_block
    @receipts = receipts
    @blob_provider = blob_provider || BlobProvider.new
    @parser = FacetBatchParser.new(logger: logger)
    @logger = logger
  end
  
  # Collect all Facet transactions from the L1 block
  # Returns CollectorResult with single_txs and batches arrays
  def call
    return empty_result unless SysConfig.facet_batch_v2_enabled?
    
    logger.debug "FacetBatchCollector: Processing block with #{eth_block['transactions'].length} transactions"
    
    stats = {
      single_txs_calldata: 0,
      single_txs_events: 0,
      batches_calldata: 0,
      batches_blobs: 0,
      deduped_batches: 0,
      missing_blobs: 0
    }
    
    single_txs = []
    all_batches = []
    
    # Index receipts by tx hash for quick lookup
    receipt_map = receipts.index_by { |r| r['transactionHash'] }
    
    # Process each transaction in the block
    eth_block['transactions'].each_with_index do |tx, tx_index|
      receipt = receipt_map[tx['hash']]
      next unless receipt && receipt['status'].to_i(16) == 1  # Skip failed txs
      
      # Collect V1 single transactions
      single_tx = collect_v1_single(tx, receipt, tx_index)
      if single_tx
        single_txs << single_tx
        stats[:single_txs_calldata] += 1 if single_tx[:source] == 'calldata'
        stats[:single_txs_events] += 1 if single_tx[:source] == 'events'
      end
      
      # Collect batches from calldata
      calldata_batches = collect_batches_from_calldata(tx, tx_index)
      if calldata_batches.any?
        logger.debug "Found #{calldata_batches.length} batches in tx #{tx['hash']}"
      end
      all_batches.concat(calldata_batches)
      stats[:batches_calldata] += calldata_batches.length
      
      # Events don't support batches in V2 - only single transactions
    end
    
    # Collect batches from blobs
    blob_batches, missing = collect_batches_from_blobs
    all_batches.concat(blob_batches)
    stats[:batches_blobs] += blob_batches.length
    stats[:missing_blobs] += missing
    
    # Deduplicate batches by content hash
    unique_batches = deduplicate_batches(all_batches)
    stats[:deduped_batches] = all_batches.length - unique_batches.length

    # Count total Facet transactions
    total_txs = single_txs.length
    unique_batches.each do |batch|
      total_txs += batch.transactions.length
    end
    stats[:total_transactions] = total_txs

    log_stats(stats) if stats.values.any?(&:positive?)

    CollectorResult.new(
      single_txs: single_txs,
      batches: unique_batches,
      stats: stats
    )
  end
  
  private
  
  def empty_result
    CollectorResult.new(single_txs: [], batches: [], stats: {})
  end
  
  # Collect V1 single transaction format
  def collect_v1_single(tx, receipt, tx_index)
    # Check for calldata submission to inbox
    if tx['to'] && tx['to'].downcase == EthTransaction::FACET_INBOX_ADDRESS.to_hex.downcase
      input = ByteString.from_hex(tx['input'])
      
      # Skip if contains batch magic (this is a batch, not a single)
      return nil if input.to_bin.include?(FacetBatchConstants::MAGIC_PREFIX.to_bin)
      
      return {
        source: 'calldata',
        l1_tx_index: tx_index,
        tx_hash: tx['hash'],
        from_address: tx['from'],  # Include L1 sender for mint attribution
        payload: input,
        events: []
      }
    end
    
    # Check for event-based submission (only first valid event per V1 protocol)
    receipt['logs'].each do |log|
      next if log['removed']
      next unless log['topics'].length == 1
      next unless log['topics'][0] == EthTransaction::FacetLogInboxEventSig.to_hex
      
      data = ByteString.from_hex(log['data'])
      
      # Skip if starts with batch magic
      next if data.to_bin.start_with?(FacetBatchConstants::MAGIC_PREFIX.to_bin)
      
      # V1 protocol: only the FIRST valid event is used
      return {
        source: 'events',
        l1_tx_index: tx_index,
        tx_hash: tx['hash'],
        payload: nil,  # Events don't have a single payload
        events: [{
          log_index: log['logIndex'].to_i(16),
          address: log['address'],
          payload: data
        }]
      }
    end
    
    nil  # No valid V1 transaction found
  end
  
  # Scan calldata for batch magic prefix
  def collect_batches_from_calldata(tx, tx_index)
    return [] unless tx['input'] && tx['input'].length > 2
    
    input = ByteString.from_hex(tx['input'])
    source_details = {
      tx_hash: tx['hash'],
      to: tx['to']
    }
    
    parser.parse_payload(
      input,
      eth_block['number'].to_i(16),
      tx_index,
      FacetBatchConstants::Source::CALLDATA,
      source_details
    )
  rescue => e
    logger.error "Failed to parse calldata batches from tx #{tx['hash']}: #{e.message}"
    []
  end
  
  # Collect batches from EIP-4844 blobs
  def collect_batches_from_blobs
    batches = []
    missing_count = 0
    
    # Skip if no blob provider
    return [[], 0] unless blob_provider
    
    # Get list of blob carriers
    carriers = blob_provider.list_carriers(eth_block['number'].to_i(16))
    
    carriers.each do |carrier|
      carrier[:versioned_hashes].each_with_index do |versioned_hash, blob_index|
        # Fetch blob data (returns ByteString by default)
        block_number = eth_block['number'].to_i(16)
        blob_data = blob_provider.get_blob(versioned_hash, block_number: block_number)
        
        if blob_data.nil?
          logger.warn "Missing blob #{versioned_hash} from tx #{carrier[:tx_hash]}"
          missing_count += 1
          next
        end
        
        source_details = {
          tx_hash: carrier[:tx_hash],
          blob_index: blob_index,
          versioned_hash: versioned_hash
        }
        
        batch_list = parser.parse_payload(
          blob_data,
          block_number,
          carrier[:tx_index],
          FacetBatchConstants::Source::BLOB,
          source_details
        )
        
        batches.concat(batch_list)
      end
    end
    
    [batches, missing_count]
  rescue => e
    logger.error "Failed to collect blob batches: #{e.message}"
    [[], 0]
  end
  
  # Deduplicate batches by content hash, keeping earliest by L1 tx index
  def deduplicate_batches(batches)
    # Group by content hash
    grouped = batches.group_by(&:content_hash)
    
    # Keep earliest by l1_tx_index for each content hash
    grouped.map do |_content_hash, batch_list|
      batch_list.min_by(&:l1_tx_index)
    end.sort_by(&:l1_tx_index)
  end
  
  def log_stats(stats)
    block_num = eth_block['number'].to_i(16)

    # Build a more readable summary
    summary_parts = []

    # Report on L1 transactions
    tx_count = eth_block['transactions']&.length || 0
    summary_parts << "#{tx_count} L1 txs"

    # Report on blobs if any
    if stats[:batches_blobs] > 0 || stats[:missing_blobs] > 0
      summary_parts << "#{stats[:batches_blobs]} blob batches"
      summary_parts << "#{stats[:missing_blobs]} missing blobs" if stats[:missing_blobs] > 0
    end

    # Report on calldata batches
    if stats[:batches_calldata] > 0
      summary_parts << "#{stats[:batches_calldata]} calldata batches"
    end

    # Report on V1 singles
    total_singles = stats[:single_txs_calldata] + stats[:single_txs_events]
    if total_singles > 0
      summary_parts << "#{total_singles} V1 singles"
    end

    # Report deduplication if any
    if stats[:deduped_batches] > 0
      summary_parts << "#{stats[:deduped_batches]} deduped"
    end

    # Total Facet transactions found
    total_facet_txs = stats[:total_transactions]
    if total_facet_txs && total_facet_txs > 0
      summary_parts << "→ #{total_facet_txs} Facet txs"
    end

    if summary_parts.any?
      logger.info "Block #{block_num}: #{summary_parts.join(', ')}"
    else
      logger.info "Block #{block_num}: No Facet activity"
    end
  end
end