module GethDriver
  extend self
  attr_reader :password
  
  def client
    @_client ||= GethClient.new(ENV.fetch('GETH_RPC_URL'))
  end
  
  def non_auth_client
    @_non_auth_client ||= GethClient.new(non_authed_rpc_url)
  end
  
  def non_authed_rpc_url
    ENV.fetch('NON_AUTH_GETH_RPC_URL')
  end
  
  def propose_block(
    transactions:,
    new_facet_block:,
    head_block:,
    safe_block:,
    finalized_block:
  )
    # Create filler blocks if necessary and update head_block
    filler_blocks = create_filler_blocks(
      head_block: head_block,
      new_facet_block: new_facet_block,
      safe_block: safe_block,
      finalized_block: finalized_block
    )
    
    head_block = filler_blocks.last || head_block
    
    new_facet_block.number = head_block.number + 1
    
    # Update block hashes after filler blocks have been added
    head_block_hash = head_block.block_hash
    safe_block_hash = safe_block.block_hash
    finalized_block_hash = finalized_block.block_hash
    
    fork_choice_state = {
      headBlockHash: head_block_hash,
      safeBlockHash: safe_block_hash,
      finalizedBlockHash: finalized_block_hash,
    }
    
    FctMintCalculator.assign_mint_amounts(transactions, new_facet_block)
    
    system_txs = [new_facet_block.attributes_tx]
    
    if new_facet_block.number == 1
      migration_manager_address = "0x22220000000000000000000000000000000000d6"
      function_selector = ByteString.from_bin(Eth::Util.keccak256('transactionsRequired()').first(4)).to_hex

      result = EthRpcClient.l2.eth_call(
        to: migration_manager_address,
        data: function_selector
      )
      
      abi_decoded = Eth::Abi.decode(['uint256'], result)
      num_transactions = abi_decoded.first
      
      num_transactions.times do |i|
        system_txs << FacetTransaction.v1_to_v2_migration_tx_from_block(new_facet_block, batch_number: i + 1)
      end
    end

    if new_facet_block.number == 2
      check_failed_system_txs(1, "First v2 block")
    end
    
    # Add L1Block implementation deployment and upgrade at fork block
    # TODO: Add solady factory deployment tx
    if new_facet_block.number == SysConfig.bluebird_fork_block_number - 1
      # Get nonce at start of block for address calculation
      deployment_nonce = EthRpcClient.l2.get_nonce(FacetTransaction::SYSTEM_ADDRESS.to_hex)

      # First tx is attributes, second is deployment, so deployment uses nonce + 1
      system_txs << FacetTransaction.l1_block_implementation_deployment_tx(new_facet_block)
      system_txs << FacetTransaction.l1_block_proxy_upgrade_tx(new_facet_block, deployment_nonce + 1)
    end
    
    if new_facet_block.number == SysConfig.bluebird_fork_block_number
      check_failed_system_txs(SysConfig.bluebird_fork_block_number - 1, "Bluebird fork block")
    end
    
    transactions_with_attributes = system_txs + transactions
    transaction_payloads = transactions_with_attributes.map(&:to_facet_payload)
    
    payload_attributes = {
      timestamp: "0x" + new_facet_block.timestamp.to_s(16),
      prevRandao: new_facet_block.prev_randao,
      suggestedFeeRecipient: "0x0000000000000000000000000000000000000000",
      withdrawals: [],
      noTxPool: true,
      transactions: transaction_payloads,
      gasLimit: "0x" + SysConfig.block_gas_limit(new_facet_block).to_s(16),
    }
    
    if new_facet_block.parent_beacon_block_root
      version = 3
      payload_attributes[:parentBeaconBlockRoot] = new_facet_block.parent_beacon_block_root
    else
      version = 2
    end
    
    payload_attributes = ByteString.deep_hexify(payload_attributes)
    fork_choice_state = ByteString.deep_hexify(fork_choice_state)
    
    fork_choice_response = client.call("engine_forkchoiceUpdatedV#{version}", [fork_choice_state, payload_attributes])
    if fork_choice_response['error']
      raise "Fork choice update failed: #{fork_choice_response['error']}"
    end
    
    payload_id = fork_choice_response['payloadId']
    unless payload_id
      raise "Fork choice update did not return a payload ID"
    end

    get_payload_response = client.call("engine_getPayloadV#{version}", [payload_id])
    if get_payload_response['error']
      raise "Get payload failed: #{get_payload_response['error']}"
    end

    payload = get_payload_response['executionPayload']
    
    if payload['transactions'].empty?
      raise "No transactions in returned payload"
    end

    new_payload_request = [payload]
    
    if version == 3
      new_payload_request << []
      new_payload_request << new_facet_block.parent_beacon_block_root
    end
    
    new_payload_request = ByteString.deep_hexify(new_payload_request)
    
    new_payload_response = client.call("engine_newPayloadV#{version}", new_payload_request)
    
    status = new_payload_response['status']
    unless status == 'VALID'
      raise "New payload was not valid: #{status}"
    end
    
    unless new_payload_response['latestValidHash'] == payload['blockHash']
      raise "New payload latestValidHash mismatch: #{new_payload_response['latestValidHash']}"
    end
  
    new_safe_block = safe_block
    new_finalized_block = finalized_block
    
    fork_choice_state = {
      headBlockHash: payload['blockHash'],
      safeBlockHash: new_safe_block.block_hash,
      finalizedBlockHash: new_finalized_block.block_hash
    }
    
    fork_choice_state = ByteString.deep_hexify(fork_choice_state)
    
    fork_choice_response = client.call("engine_forkchoiceUpdatedV#{version}", [fork_choice_state, nil])

    status = fork_choice_response['payloadStatus']['status']
    unless status == 'VALID'
      raise "Fork choice update was not valid: #{status}"
    end
    
    unless fork_choice_response['payloadStatus']['latestValidHash'] == payload['blockHash']
      raise "Fork choice update latestValidHash mismatch: #{fork_choice_response['payloadStatus']['latestValidHash']}"
    end
    
    new_facet_block.from_rpc_response(payload)
    filler_blocks + [new_facet_block]
  end

  def create_filler_blocks(
    head_block:,
    new_facet_block:,
    safe_block:,
    finalized_block:
  )
    max_filler_blocks = 100
    block_interval = 12
    last_block = head_block
    filler_blocks = []

    diff = new_facet_block.timestamp - last_block.timestamp
    
    if diff > block_interval
      num_intervals = (diff / block_interval).to_i
      aligns_exactly = (diff % block_interval).zero?
      num_filler_blocks = aligns_exactly ? num_intervals - 1 : num_intervals
      
      if num_filler_blocks > max_filler_blocks
        raise "Too many filler blocks"
      end
      
      num_filler_blocks.times do
        filler_block = FacetBlock.next_in_sequence_from_facet_block(last_block)

        proposed_blocks = GethDriver.propose_block(
          transactions: [],
          new_facet_block: filler_block,
          head_block: last_block,
          safe_block: safe_block,
          finalized_block: finalized_block,
        ).sort_by(&:number)

        filler_blocks.concat(proposed_blocks)
        last_block = proposed_blocks.last
      end
    end

    filler_blocks.sort_by(&:number)
  end
  
  def init_command
    http_port = ENV.fetch('NON_AUTH_GETH_RPC_URL').split(':').last
    authrpc_port = ENV.fetch('GETH_RPC_URL').split(':').last
    discovery_port = ENV.fetch('GETH_DISCOVERY_PORT')
    
    genesis_filename = ChainIdManager.on_mainnet? ? "facet-mainnet.json" : "facet-sepolia.json"
    
    command = [
      "./facet-chain/unzip_genesis.sh &&",
      "make geth &&",
      "mkdir -p ./datadir &&",
      "rm -rf ./datadir/* &&",
      "./build/bin/geth init --cache.preimages --state.scheme=hash --datadir ./datadir facet-chain/#{genesis_filename} &&",
      "./build/bin/geth --datadir ./datadir",
      "--http",
      "--http.api 'eth,net,web3,debug'",
      "--http.vhosts=\"*\"",
      "--authrpc.jwtsecret /tmp/jwtsecret",
      "--http.port #{http_port}",
      '--http.corsdomain="*"',
      "--authrpc.port #{authrpc_port}",
      "--discovery.port #{discovery_port}",
      "--port #{discovery_port}",
      "--authrpc.addr localhost",
      "--authrpc.vhosts=\"*\"",
      "--nodiscover",
      "--cache 16000",
      "--rpc.gascap 5000000000",
      "--rpc.batch-request-limit=10000",
      "--rpc.batch-response-max-size=100000000",
      "--cache.preimages",
      "--maxpeers 0",
      # "--verbosity 2",
      "--syncmode full",
      "--gcmode archive",
      "--history.state 0",
      "--history.transactions 0",
      "--nocompaction",
      "--rollup.enabletxpooladmission=false",
      "--rollup.disabletxpoolgossip",
      "console"
    ].join(' ')

    puts command
  end
  
  def get_state_dump(geth_dir = ENV.fetch('LOCAL_GETH_DIR'))
    command = [
      "#{geth_dir}/build/bin/geth",
      'dump',
      "--datadir #{geth_dir}/datadir"
    ]
    
    full_command = command.join(' ')
    
    data = `#{full_command}`
    
    alloc = {}
    
    data.each_line do |line|
      entry = JSON.parse(line)
      address = entry['address']
      
      next unless address
      
      alloc[address] = {
        'balance' => entry['balance'].to_i(16),
        'nonce' => entry['nonce'],
        'code' => entry['code'].presence || "0x",
        'storage' => entry['storage'].presence || {}
      }
    end
    
    alloc
  end
  
  def trace_transaction(tx_hash)
    non_auth_client.call("debug_traceTransaction", [tx_hash, {
      enableMemory: true,
      disableStack: false,
      disableStorage: false,
      enableReturnData: true,
      debug: true,
      tracer: "callTracer"
    }])
  end

  def check_failed_system_txs(block_to_check, context)
    receipts = EthRpcClient.l2.get_block_receipts(block_to_check)
    
    failed_system_txs = receipts.select do |receipt|
      FacetTransaction::SYSTEM_ADDRESS == Address20.from_hex(receipt['from']) &&
      receipt['status'] != '0x1'
    end

    unless failed_system_txs.empty?
      failed_system_txs.each do |tx|
        trace = EthRpcClient.l2.trace_transaction(tx['transactionHash'])
        ap trace
      end
      raise "#{context} system transactions did not execute successfully"
    end
  end
end
