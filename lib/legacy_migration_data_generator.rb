class LegacyMigrationDataGenerator
  include Singleton
  include Memery
  
  class BlockNotReadyToImportError < StandardError; end
  
  attr_accessor :imported_facet_transaction_receipts, :imported_facet_transactions,
    :ethereum_client, :legacy_value_mapping, :current_import_block_number
    
  delegate :genesis_block, :v2_fork_block, to: :FacetBlock

  def initialize
    reset_state
    
    @ethereum_client ||= EthRpcClient.new(
      base_url: ENV.fetch('L1_RPC_URL')
    )
    
    unless ENV['FACET_V1_VM_DATABASE_URL'].present?
      raise "FACET_V1_VM_DATABASE_URL is not set"
    end
  end
  
  def reset_state
    @imported_facet_transaction_receipts = []
    @imported_facet_transactions = []
    @legacy_value_mapping = {}
  end
  
  def logger
    Rails.logger
  end
  
  def validate_import?
    Ethscription.validate_import?
  end
  
  def in_v2?(block_number)
    v2_fork_block.blank? || block_number >= v2_fork_block
  end
  
  def blocks_behind
    (v2_fork_block - next_block_to_import) + 1
  end
  
  def import_batch_size
    [blocks_behind, 100].min
  end
  
  def add_legacy_value_mapping_item(legacy_value:, new_value:)
    if legacy_value.blank? || new_value.blank?
      raise "Legacy value or new value is blank: #{legacy_value} -> #{new_value}"
    end
    
    legacy_value = legacy_value.downcase
    new_value = new_value.downcase
    
    current_value = legacy_value_mapping[legacy_value]
    
    if current_value.present? && current_value != new_value
      raise "Mismatch: #{legacy_value} -> #{current_value} != #{new_value}"
    end
    
    legacy_value_mapping[legacy_value] = new_value
  end
  
  def import_blocks_until_done
    MemeryExtensions.clear_all_caches!
    ensure_genesis_blocks
    
    l1_rpc_responses = {}
    
    loop do
      begin
        block_numbers = next_blocks_to_import(import_batch_size)
        
        raise if in_v2?(block_numbers.first)
        
        if block_numbers.blank?
          raise BlockNotReadyToImportError.new("Block not ready")
        end
        
        next_start_block = block_numbers.last + 1
        next_block_numbers = (next_start_block...(next_start_block + import_batch_size * 2)).to_a
        
        blocks_to_import = block_numbers + next_block_numbers
        
        blocks_to_import -= l1_rpc_responses.keys
        
        l1_rpc_responses.reverse_merge!(get_blocks_promises(blocks_to_import))
        
        result = import_blocks(block_numbers, l1_rpc_responses)
        
        if result.nil?
          logger.info "Reorg detected. Restarting import process."
          next
        end
      rescue BlockNotReadyToImportError => e
        puts "#{e.message}. Stopping import."
        break
      end
    end
  end
  
  def ensure_genesis_blocks
    ActiveRecord::Base.transaction do
      return if FacetBlock.exists?
    
      facet_genesis_block = GethDriver.client.call("eth_getBlockByNumber", ["0x0", false])
      facet_latest_block = GethDriver.client.call("eth_getBlockByNumber", ["latest", false])
      
      unless facet_genesis_block['hash'] == facet_latest_block['hash']
        raise "Facet genesis block is not the same as the latest block on geth"
      end
      
      genesis_eth_block = ethereum_client.call("eth_getBlockByNumber", ["0x" + genesis_block.to_s(16), false])
      
      eth_block = EthBlock.from_rpc_result(genesis_eth_block['result'])
      eth_block.save!
      
      current_max_block_number = FacetBlock.maximum(:number).to_i
      
      facet_block = FacetBlock.from_eth_block(eth_block, current_max_block_number + 1)
      facet_block.from_rpc_response(facet_genesis_block)
      facet_block.save!
    end
  end
  
  def get_blocks_promises(block_numbers)
    block_numbers.map do |block_number|
      promise = Concurrent::Promise.execute do
         ethereum_client.get_block(block_number, true)
      end
      
      [block_number, promise]
    end.to_h
  end
  
  def check_block_consistency(block_by_number_responses, latest_db_block)
    sorted_block_numbers = block_by_number_responses.keys.sort
    first_block_number = sorted_block_numbers.first
    first_block_data = block_by_number_responses[first_block_number]['result']

    if latest_db_block
      if first_block_number == latest_db_block.number + 1
        if latest_db_block.block_hash != first_block_data['parentHash']
          reorg_message = "Reorg detected at block #{first_block_number}"
          logger.warn(reorg_message)
          Airbrake.notify(reorg_message)
          
          EthBlock.where("number >= ?", latest_db_block.number).destroy_all
          return false
        end
      else
        unexpected_block_message = "Unexpected block number: expected #{latest_db_block.number + 1}, got #{first_block_number}"
        Airbrake.notify(unexpected_block_message)
        
        raise unexpected_block_message
      end
    end

    # Check consistency of all blocks in the batch
    sorted_block_numbers.each_cons(2) do |current_number, next_number|
      current_block = block_by_number_responses[current_number]['result']
      next_block = block_by_number_responses[next_number]['result']

      unless next_block['parentHash'] == current_block['hash'] && next_number == current_number + 1
        inconsistency_message = "Block inconsistency detected between blocks #{current_number} and #{next_number}"
        logger.warn(inconsistency_message)
        Airbrake.notify(inconsistency_message)
        return false
      end
    end

    true
  end
  
  def import_blocks(block_numbers, l1_rpc_responses)
    logger.info "Block Importer: importing blocks #{block_numbers.join(', ')}"
    start = Time.current
    
    block_numbers = block_numbers.sort
    
    # Fetch the latest block from the database once
    latest_db_block = EthBlock.order(number: :desc).first
    
    block_by_number_responses = l1_rpc_responses.select do |block_number, promise|
      block_numbers.include?(block_number)
    end.to_h.transform_values(&:value!)
    
    l1_rpc_responses.reject! { |block_number, promise| block_by_number_responses.key?(block_number) }
    
    unless check_block_consistency(block_by_number_responses, latest_db_block)
      logger.warn("Block consistency check failed. Restarting import process.")
      return nil
    end
    
    legacy_eth_blocks_future, ethscriptions_future, legacy_tx_receipts_future = [
      LegacyEthBlock.where(block_number: block_numbers).load_async,
      LegacyEthscription.where(block_number: block_numbers).load_async,
      LegacyFacetTransactionReceipt.where(block_number: block_numbers).load_async
    ]
    
    legacy_eth_blocks = legacy_eth_blocks_future.to_a
    
    unless legacy_eth_blocks.all?(&:processed?)
      raise "Requested blocks have not yet been processed on the V1 VM: #{legacy_eth_blocks.map(&:block_number).join(', ')}"
    end
    
    # Create a hash mapping transaction hashes to their "from" addresses
    tx_hash_to_from = {}
    block_by_number_responses.each do |_, block_data|
      block_data['result']['transactions'].each do |tx|
        tx_hash_to_from[tx['hash']] = tx['from']
      end
    end
    
    ethscriptions = ethscriptions_future.to_a.map do |e|
      Ethscription.from_legacy_ethscription(e, tx_hash_to_from[e.transaction_hash])
    end.select(&:valid?)
    
    legacy_tx_receipts = legacy_tx_receipts_future.to_a
    
    ethscriptions_by_block = ethscriptions.group_by(&:block_number)
    legacy_tx_receipts_by_block = legacy_tx_receipts.group_by(&:block_number)
    
    eth_blocks = []
    eth_transactions = []
    all_ethscriptions = []
    facet_blocks = []
    all_facet_txs = []
    all_receipts = []
    res = []
    
    reset_state
    
    # Get the current maximum block number from the database
    current_max_block_number = FacetBlock.maximum(:number).to_i
    
    # Get the earliest block
    earliest = FacetBlock.order(number: :asc).first
    
    # Initialize in-memory representation of blocks
    # TODO: this grows unbounded, need to trim it to last 64 blocks
    in_memory_blocks = FacetBlock.where(number: (current_max_block_number - 64 - block_numbers.size)..current_max_block_number).index_by(&:number)
    
    ActiveRecord::Base.transaction do
      block_numbers.each_with_index do |block_number, index|
        begin
          old_current_import_block_number = current_import_block_number
          @current_import_block_number = block_number
          
          eth_block = EthBlock.from_rpc_result(block_by_number_responses[block_number]['result'])

          eth_blocks << eth_block
          
          block_ethscriptions = Array.wrap(ethscriptions_by_block[block_number]).sort_by(&:transaction_index)
          block_legacy_tx_receipts = Array.wrap(legacy_tx_receipts_by_block[block_number]).sort_by(&:transaction_index)
          
          eth_transactions.concat(block_ethscriptions.map { |e| EthTransaction.from_ethscription(e) })
          
          block_number = current_max_block_number + index + 1
          
          # Determine the head, safe, and finalized blocks
          head_block = in_memory_blocks[block_number - 1] || earliest
          safe_block = in_memory_blocks[block_number - 32] || earliest
          finalized_block = in_memory_blocks[block_number - 64] || earliest
          
          facet_block, facet_txs, receipts = propose_facet_block(
            eth_block,
            block_ethscriptions,
            block_legacy_tx_receipts,
            block_number: block_number,
            head_block: head_block,
            safe_block: safe_block,
            finalized_block: finalized_block
          )
          
          # Update in-memory blocks
          in_memory_blocks[block_number] = facet_block
          
          facet_blocks << facet_block
          all_facet_txs.concat(facet_txs)
          all_receipts.concat(receipts)
          
          imported_facet_transaction_receipts.concat(receipts)
          imported_facet_transactions.concat(facet_txs)

          receipts.each(&:set_legacy_contract_address_map)
          receipts.each(&:update_real_withdrawal_id)
          
          validate_receipts(block_legacy_tx_receipts, receipts) if validate_import?
          
          block_ethscriptions.each(&:clear_caches_if_upgrade!)
          
          res << OpenStruct.new(
            facet_block: facet_block,
            transactions_imported: facet_txs,
            receipts_imported: receipts
          )
        ensure
          @current_import_block_number = old_current_import_block_number
        end
      end
      
      EthBlock.import!(eth_blocks)
      EthTransaction.import!(eth_transactions)
      
      FacetBlock.import!(facet_blocks)
      FacetTransaction.import!(all_facet_txs)
      FacetTransactionReceipt.import!(all_receipts)
      
      legacy_value_objects = legacy_value_mapping.map do |legacy_value, new_value|
        LegacyValueMapping.new(legacy_value: legacy_value, new_value: new_value)
      end
      
      LegacyValueMapping.import!(legacy_value_objects, on_duplicate_key_update: { conflict_target: [:legacy_value], columns: [:new_value] })
      
      validate_receipt_counts if validate_import?
    end
    
    elapsed_time = Time.current - start
    
    blocks = res.map(&:facet_block)
    total_gas = blocks.sum(&:gas_used)
    total_transactions = res.map(&:transactions_imported).flatten.count
    blocks_per_second = (blocks.length / elapsed_time).round(2)
    transactions_per_second = (total_transactions / elapsed_time).round(2)
    total_gas_millions = (total_gas / 1_000_000.0).round(2)
    average_gas_per_block_millions = (total_gas / blocks.length / 1_000_000.0).round(2)
    gas_per_second_millions = (total_gas / elapsed_time / 1_000_000.0).round(2)
    
    puts "Time elapsed: #{elapsed_time.round(2)} s"
    puts "Imported #{block_numbers.length} blocks. #{blocks_per_second} blocks / s"
    puts "Imported #{total_transactions} transactions (#{transactions_per_second} / s)"
    puts "Total gas used: #{total_gas_millions} million (avg: #{average_gas_per_block_millions} million / block)"
    puts "Gas per second: #{gas_per_second_millions} million / s"
    
    block_numbers
  rescue => e
    binding.irb
    raise
  end
  
  def global_special_cases
    [
      "0x7926c3ff3acc5089c01ec03982916cbce09a0b5707df9754ac76488e0ff13b9f",
      "0x71d55e1428ab79f5d2355326ea4fbe9dda74fd7edfd0ef0a45cc24b8cae64a64",
      "0x040a7d80e00abdb3fb9e59103be7323afb90c00fa9ea2444b9b8b6874a2ba311",
      "0x2bb5d730d1553eb725a1190d8981943dabb0a6f88548b6edeb192b688b2e0d7c",
      "0xb3080f456d00e5bc4d2e30cebc2d16ee77e384639f5d21ba9ed48da833afd0b8",
      "0x7f3141145c852f7eb9d98b277ce901b9a707121153ea5b2e2d43a5ea054eafb6",
      
      "0x7926c3ff3acc5089c01ec03982916cbce09a0b5707df9754ac76488e0ff13b9f",
      "0x71d55e1428ab79f5d2355326ea4fbe9dda74fd7edfd0ef0a45cc24b8cae64a64",
      "0x040a7d80e00abdb3fb9e59103be7323afb90c00fa9ea2444b9b8b6874a2ba311",
      "0x124385850e3997f9d91f2fc8c28082cd3162f6e50cfb84a36e13da24821cb0fc",
      "0xd11ff44f9b44d6fc9b118b336447e08028a642db9dd14b6cc155c1e67e9fbd42",
      "0xdad5e47c73dec1ba0e4b7943e588a3deb290ed3b85b9f40d11a9edd3799135ab",
      "0xb5cf66fbaeb93b876a3cb3c6126b16bb73d8897e407ee0d712e52410f18d3542",
      
      "0x8d3cf03f51c9813dffb2f804e2ec6f8f187b687b0e3374bf44936adc15d938f8",
      "0xabea86865dc24c3719ebe2c0d75ff8b81f4124449a66b2a15dc6dcff75cf44d7",
    ]
  end
  
  def validate_receipt_counts
    # First tx in the block is the attributes tx
    our_count = FacetTransactionReceipt.where("transaction_index > 0").count
    
    max_block_number = FacetBlock.maximum(:eth_block_number)
    
    legacy_count = LegacyFacetTransactionReceipt.where("block_number <= ?", max_block_number).count
    
    unless our_count == legacy_count
      raise "Mismatched number of receipts: our count is #{our_count}, legacy count is #{legacy_count}"
    end
  end
  
  def validate_receipts(legacy_tx_receipts, facet_receipts)
    l1_attributes_tx_receipt = facet_receipts.shift
    
    unless l1_attributes_tx_receipt.status == 1
      binding.irb
      raise "L1 attributes transaction failed"
    end
    
    unless legacy_tx_receipts.size == facet_receipts.size
      raise "Mismatched number of legacy and facet receipts"
    end
    
    legacy_tx_receipts.each_with_index do |legacy_receipt, index|
      facet_receipt = facet_receipts[index]
      facet_status = facet_receipt.status == 1 ? 'success' : 'failure'
      
      special_cases = global_special_cases
      
      if special_cases.include?(legacy_receipt.transaction_hash)
        if legacy_receipt.status != 'success' || facet_status != 'failure'
          binding.irb
          raise "Special case status mismatch: Legacy receipt status #{legacy_receipt.status} should be 'success' and Facet receipt status #{facet_status} should be 'failure'"
        end
      elsif legacy_receipt.status != facet_status
        binding.irb
        raise "Status mismatch: Legacy receipt status #{legacy_receipt.status} does not match Facet receipt status #{facet_status}"
      end
      
      if legacy_receipt.created_contract_address && facet_receipts[index].legacy_contract_address_map.keys.exclude?(legacy_receipt.created_contract_address)
        binding.irb
        raise "Contract address mismatch"
      end
      
      if legacy_receipt.status == 'success' && legacy_receipt.logs.present? && facet_receipt.logs.blank? && !special_cases.include?(legacy_receipt.transaction_hash)
        binding.irb
        raise "Log mismatch: Legacy receipt has logs but Facet receipt has none"
      end
      
      # Check for all attributes in CallFromBridge event, with special handling for 'calldata' -> 'outsideCalldata'
      compare_event_attributes(legacy_receipt, facet_receipt, 'CallFromBridge', { 'outsideCalldata' => 'calldata' }, ['outsideCalldata', 'calldata', 'resultData'])

      # Check for all attributes in CallOnBehalfOfUser event, with special handling for 'userCalldata' -> 'calldata'
      compare_event_attributes(legacy_receipt, facet_receipt, 'CallOnBehalfOfUser', { 'userCalldata' => 'calldata' }, ['userCalldata', 'calldata', 'resultData'])

      # Check for all attributes in BridgedIn event
      compare_event_attributes(legacy_receipt, facet_receipt, 'BridgedIn')

      # Check for all attributes in InitiateWithdrawal event, excluding 'withdrawalId'
      compare_events_multi(legacy_receipt, facet_receipt, [
        'InitiateWithdrawal',
        'WithdrawalComplete',
        'BuddyCreated'
      ], except: { 'InitiateWithdrawal' => ['withdrawalId'], 'WithdrawalComplete' => ['withdrawalId'], 'BuddyCreated' => ['buddy'] })

      compare_events_multi(legacy_receipt, facet_receipt, [
        'OfferAccepted',
        'OfferCancelled',
        'AllOffersOnAssetCancelledForUser',
        'AllOffersCancelledForUser',
        'BridgedIn',
        'Minted',
        'PublicMaxPerAddressUpdated',
        'PublicMintStartUpdated',
        'PublicMintEndUpdated',
        'PublicMintPriceUpdated',
        'AllowListMerkleRootUpdated',
        'AllowListMaxPerAddressUpdated',
        'AllowListMintStartUpdated',
        'AllowListMintEndUpdated',
        'AllowListMintPriceUpdated',
        'MaxSupplyUpdated',
        'BaseURIUpdated',
        'MediaURIsUpdated',
        'EditionInitialized',
        'DescriptionUpdated',
        'CollectionInitialized',
        'UpgradeLevelUpdated',
        'TokenUpgraded',
        'ContractInfoUpdated',
        'BatchTransfer',
        'WithdrawStuckTokens',
        'PresaleBuy',
        'PresaleSell',
        'TokensClaimed',
        'MetadataRendererUpdated'
      ])
    end
  end
  
  def compare_event_attributes(legacy_receipt, facet_receipt, event_name, attribute_mapping = {}, except = [])
    legacy_event = legacy_receipt.logs.find { |log| log['event'] == event_name }
    facet_event = facet_receipt.decoded_logs.find { |log| log['event'] == event_name }

    if legacy_event && facet_event
      if legacy_event['contractType'] == 'EtherBridge03' && event_name == 'BridgedIn'
        legacy_to = legacy_event.dig('data', 'to')
        facet_to = facet_event.dig('data', 'to')
        if legacy_event['data'].except('to') == facet_event['data'].except('to') && legacy_to != facet_to
          return
        end
      end
      
      if legacy_event['contractType'] == 'FacetPortV101' && event_name == 'OfferAccepted'
        legacy_buyer = legacy_event.dig('data', 'buyer')
        facet_buyer = facet_event.dig('data', 'buyer')
        if legacy_event['data'].except('buyer') == facet_event['data'].except('buyer') && legacy_buyer != facet_buyer
          return
        end
      end
      
      if legacy_event['contractType'] == 'ERC20BatchTransfer' && event_name == 'BatchTransfer'
        legacy_token_address = legacy_event.dig('data', 'tokenAddress')
        facet_token_address = facet_event.dig('data', 'tokenAddress')

        if legacy_event['data'].except('tokenAddress') == facet_event['data'].except('tokenAddress')
          return
        end
      end
      
      if legacy_event['contractType'] == 'FacetBuddy' && event_name == 'CallOnBehalfOfUser'
        legacy_final_amount = legacy_event.dig('data', 'finalAmount')
        facet_final_amount = facet_event.dig('data', 'finalAmount')
        legacy_calldata = legacy_event.dig('data', 'calldata')
        if legacy_calldata.is_a?(String)
          legacy_calldata_json = JSON.parse(legacy_calldata) rescue nil
          legacy_calldata_function = legacy_calldata_json.is_a?(Hash) ? legacy_calldata_json['function'] : legacy_calldata_json.first
          
          if legacy_calldata_json && legacy_calldata_function == 'upgradeMultipleTokens'
            if legacy_event['data']['resultSuccess'] == false && facet_event['data']['resultSuccess'] == false
              return
            end
          end
        end
      end
      
      attributes = (legacy_event['data'].keys + facet_event['data'].keys).uniq - except
      attributes.each do |attribute|
        legacy_attribute = attribute_mapping[attribute] || attribute
        facet_attribute = attribute_mapping.invert[attribute] || attribute
        legacy_value = legacy_event.dig('data', legacy_attribute)
        facet_value = facet_event.dig('data', facet_attribute)

        both_blank = ['null', ''].include?(legacy_value) && facet_value == "0x"
        
        special_cases = [
          '0x0fc60c42276513dc6965af5d4d7824a846f64ad1c3bbd14afefdb082b32ff833',
          '0x34224c6078e2e58d8d0c6275ac018d0e9c3e29c4139c697634f90fd6824e3b55',
          '0x48efe32573bac786b8ee5215fa26a809a66ad4d2edac933765364a20a0e5c002'
        ]

        if (legacy_value != facet_value && !both_blank) && !special_cases.include?(legacy_receipt.transaction_hash)
          binding.irb
          raise "#{event_name} attribute mismatch: Legacy #{legacy_attribute} #{legacy_value} does not match Facet #{facet_attribute} #{facet_value}"
        end
      end
    elsif (legacy_event || facet_event) && !global_special_cases.include?(legacy_receipt.transaction_hash)
      binding.irb
      raise "#{event_name} event presence mismatch: Legacy event present? #{!!legacy_event}, Facet event present? #{!!facet_event}"
    end
  end

  def compare_events_multi(legacy_receipt, facet_receipt, events, except: {})
    events.each do |event_name|
      compare_event_attributes(legacy_receipt, facet_receipt, event_name, {}, except[event_name] || [])
    end
  end
  
  def import_next_block
    block_number = next_block_to_import
    import_blocks([block_number])
  end
  
  def next_block_to_import
    next_blocks_to_import(1).first
  end
  
  def next_blocks_to_import(n)
    # ensure_genesis_blocks
    
    max_db_block = EthBlock.maximum(:number)
    
    unless max_db_block
      raise "No blocks in the database"
    end
    
    start_block = max_db_block + 1
    
    (start_block...(start_block + n)).to_a
  end

  def facet_txs_from_ethscriptions_in_block(eth_block, ethscriptions, legacy_tx_receipts, facet_block)
    # results = Parallel.map(ethscriptions.sort_by(&:transaction_index).each_with_index, in_threads: 10) do |(ethscription, idx)|
    results = ethscriptions.sort_by(&:transaction_index).map.with_index do |ethscription, idx|
      ethscription.clear_caches_if_upgrade!
      
      legacy_tx_receipt = legacy_tx_receipts.find { |r| r.transaction_hash == ethscription.transaction_hash }
      facet_tx = FacetTransaction.from_eth_tx_and_ethscription(
        ethscription,
        idx,
        eth_block,
        ethscriptions.count,
        facet_block
      )
      
      [idx, facet_tx] # Return the index and the result to preserve order
    end
  
    # Sort the results by their original indices and extract the facet transactions
    results.sort_by { |idx, _| idx }.map { |_, facet_tx| facet_tx }
  end
  
  def propose_facet_block(eth_block, ethscriptions, legacy_tx_receipts, block_number:, head_block:, safe_block:, finalized_block:)
    facet_block = FacetBlock.from_eth_block(eth_block, block_number)
    
    facet_txs = facet_txs_from_ethscriptions_in_block(
      eth_block,
      ethscriptions,
      legacy_tx_receipts,
      facet_block
    )
    
    attributes_tx = FacetTransaction.l1_attributes_tx_from_blocks(eth_block, facet_block)
    
    facet_txs = facet_txs.sort_by(&:eth_call_index).unshift(attributes_tx)
    payload = facet_txs.map(&:to_facet_payload)
    
    response = geth_driver.propose_block(
      payload,
      facet_block,
      head_block,
      safe_block,
      finalized_block
    )
  
    geth_block_future = Concurrent::Promises.future { geth_driver.client.call("eth_getBlockByNumber", [response['blockNumber'], true]) }
    receipts_data_future = Concurrent::Promises.future { geth_driver.client.call("eth_getBlockReceipts", [response['blockNumber']]) }

    # Wait for both futures to complete
    geth_block, receipts_data = Concurrent::Promises.zip(geth_block_future, receipts_data_future).value!
    
    facet_block.from_rpc_response(geth_block)
    receipts_data_by_hash = receipts_data.index_by { |receipt| receipt['transactionHash'] }
    
    facet_txs_by_source_hash = facet_txs.index_by(&:source_hash)
    
    receipts = []
    
    geth_block['transactions'].each do |tx|
      receipt_details = receipts_data_by_hash[tx['hash']]
      
      facet_tx = facet_txs_by_source_hash[tx['sourceHash']]
      raise unless facet_tx

      facet_tx.assign_attributes(
        tx_hash: tx['hash'],
        block_hash: response['blockHash'],
        block_number: response['blockNumber'].to_i(16),
        transaction_index: receipt_details['transactionIndex'].to_i(16),
        deposit_receipt_version: tx['depositReceiptVersion'].to_i(16),
        gas_limit: tx['gas'].to_i(16),
        tx_type: tx['type']
      )
      
      facet_receipt = FacetTransactionReceipt.new(
        transaction_hash: tx['hash'],
        block_hash: response['blockHash'],
        block_number: response['blockNumber'].to_i(16),
        contract_address: receipt_details['contractAddress'],
        cumulative_gas_used: receipt_details['cumulativeGasUsed'].to_i(16),
        deposit_nonce: tx['nonce'].to_i(16),
        deposit_receipt_version: tx['type'].to_i(16),
        effective_gas_price: receipt_details['effectiveGasPrice'].to_i(16),
        from_address: tx['from'],
        gas_used: receipt_details['gasUsed'].to_i(16),
        logs: receipt_details['logs'],
        logs_bloom: receipt_details['logsBloom'],
        status: receipt_details['status'].to_i(16),
        to_address: tx['to'],
        transaction_index: receipt_details['transactionIndex'].to_i(16),
        tx_type: tx['type']
      )
      
      # Pair the receipt with its legacy counterpart
      legacy_receipt = legacy_tx_receipts.find { |legacy_tx| legacy_tx.transaction_hash == facet_tx.eth_transaction_hash }
      facet_receipt.legacy_receipt = legacy_receipt
      
      receipts << facet_receipt
    end
    
    [facet_block, facet_txs, receipts]
  rescue => e
    binding.irb
    raise
  end
  
  def geth_driver
    @_geth_driver ||= GethDriver
  end
end
