module FacetTransactionHelper
  def import_eth_txs(transactions)
    mock_ethereum_client = instance_double(EthRpcClient)
    
    current_max_eth_block = EthBlockImporter.instance.current_max_eth_block
    
    # Convert transaction params to EthTransaction objects
    eth_transactions = transactions.map.with_index do |tx_params, index|
      EthTransaction.new(
        block_hash: Hash32.from_hex(bytes_stub(rand)),
        block_number: current_max_eth_block.number + 1,
        block_timestamp: current_max_eth_block.timestamp + 12,
        tx_hash: Hash32.from_hex(bytes_stub(rand)),
        transaction_index: index,  # Use index for transaction ordering
        input: ByteString.from_hex(tx_params[:input]),
        chain_id: 1,
        from_address: Address20.from_hex(tx_params[:from_address] || "0x" + "2" * 40),
        to_address: FacetTransaction::FACET_INBOX_ADDRESS,
        status: 1,
        logs: tx_params[:events] || []
      )
    end

    rpc_results = eth_txs_to_rpc_result(eth_transactions)
    block_result = rpc_results[0].merge('parentHash' => current_max_eth_block.block_hash.to_hex)
    receipt_result = rpc_results[1]
    
    instance = EthBlockImporter.instance
    instance.ethereum_client = mock_ethereum_client

    allow(mock_ethereum_client).to receive(:get_block_number).and_return(eth_transactions.first.block_number)
    allow(mock_ethereum_client).to receive(:get_block).and_return(block_result)
    allow(mock_ethereum_client).to receive(:get_transaction_receipts).and_return(receipt_result)

    importer = EthBlockImporter.instance
    facet_blocks, eth_blocks = importer.import_next_block# rescue binding.irb
    
    latest_l2_block = EthRpcClient.l2.get_block("latest", true)
    # binding.irb
    # Return array of receipts
    res = eth_transactions.map do |eth_tx|
      tx_in_geth = latest_l2_block['transactions'].find do |tx|
        eth_tx.facet_tx_source_hash == Hash32.from_hex(tx['sourceHash'])
      end
      
      next nil if tx_in_geth.nil?
      
      receipt_in_geth = EthRpcClient.l2.get_transaction_receipt(tx_in_geth['hash'])
      next nil if receipt_in_geth.nil?
      
      combined_receipt = combine_transaction_data(receipt_in_geth, tx_in_geth)
      combined_receipt.l2_block = latest_l2_block
      
      combined_receipt
    end.compact

    res
  end

  # Keep the original method for backwards compatibility
  def import_eth_tx(**params)
    receipts = import_eth_txs([params])
    
    if params[:expect_no_tx]
      expect(receipts).to be_empty
      return
    end
    
    receipt = receipts.first
    binding.irb unless receipt.present?
    expect(receipt).to be_present
    
    expected_status = params[:expect_error] ? 0 : 1
    unless receipt.status == expected_status
      ap EthRpcClient.l2.trace(receipt.hash)
      binding.irb
    end
    expect(receipt.status).to eq(expected_status)
    
    receipt
  end

  def alias_addr(addr)
    AddressAliasHelper.apply_l1_to_l2_alias(addr)
  end
  
  def bytes_stub(i, len = 32)
    hsh = Eth::Util.keccak256(["stub", i.to_s].join(":"))
    ByteString.from_bin(hsh.last(len)).to_hex
  end

  def generate_facet_tx_payload(
    input:,
    to:,
    gas_limit:,
    value: 0
  )
    chain_id = ChainIdManager.current_l2_chain_id
    
    rlp_encoded = Eth::Rlp.encode([
      Eth::Util.serialize_int_to_big_endian(chain_id),
      Eth::Util.hex_to_bin(to.to_s),
      Eth::Util.serialize_int_to_big_endian(value),
      Eth::Util.serialize_int_to_big_endian(gas_limit),
      Eth::Util.hex_to_bin(input),
      '',
    ])

    "0x#{FacetTransaction::FACET_TX_TYPE.to_s(16).rjust(2, '0')}#{rlp_encoded.unpack1('H*')}"
  end
  
  def calldata_mint_amount(hex_string)
    bytes = ByteString.from_hex(hex_string).to_bin
    zero_count = bytes.count("\x00")
    non_zero_count = bytes.bytesize - zero_count
    
    zero_count * 4 + non_zero_count * 16
  end
  
  def generate_event_log(data, from_address, log_index, removed = false)
    {
      'address' => from_address,
      'topics' => [EthTransaction::FacetLogInboxEventSig.to_hex],
      'data' => data,
      'logIndex' => "0x" + log_index.to_s(16),
      'removed' => removed
    }
  end
  
  def calldata_mint_amount_for_tx(facet_block, hex_string)
    prev_l1_attributes = GethDriver.client.get_l1_attributes(facet_block.number - 1)
    prev_rate = prev_l1_attributes[:fct_mint_rate]
    
    new_rate = FctMintCalculator.compute_new_rate(facet_block, prev_rate, prev_l1_attributes[:fct_mint_period_l1_data_gas])
    
    calldata_mint_amount(hex_string) * new_rate
  end
  
  def expect_calldata_mint_to_be(facet_block, hex_string, expected_mint)
    expect(calldata_mint_amount_for_tx(facet_block, hex_string)).to eq(expected_mint)
  end

  def combine_transaction_data(receipt, tx_data)
    combined = receipt.merge(tx_data) do |key, receipt_val, tx_val|
      if receipt_val != tx_val
        [receipt_val, tx_val]
      else
        receipt_val
      end
    end
  
    # Convert hex strings to integers where appropriate
    %w[blockNumber gasUsed cumulativeGasUsed effectiveGasPrice status transactionIndex nonce value gas depositNonce mint depositReceiptVersion gasPrice].each do |key|
      combined[key] = combined[key].to_i(16) if combined[key].is_a?(String) && combined[key].start_with?('0x')
    end
  
    # Remove duplicate keys with different casing
    combined.delete('transactionHash')  # Keep 'transactionHash' instead
  
    obj = OpenStruct.new(combined)
    
    def obj.method_missing(method, *args, &block)
      if respond_to?(method.to_s.camelize(:lower))
        send(method.to_s.camelize(:lower), *args, &block)
      else
        super
      end
    end
    
    obj
  end
  
  def eth_txs_to_rpc_result(eth_transactions)
    block_result = {
      'hash' => eth_transactions.first.block_hash.to_hex,
      'number' => "0x" + eth_transactions.first.block_number.to_s(16),
      'baseFeePerGas' => "0x" + 1.gwei.to_s(16),
      'timestamp' => "0x" + eth_transactions.first.block_timestamp.to_s(16),
      'parentBeaconBlockRoot' => eth_transactions.first.block_hash.to_hex,
      'mixHash' => eth_transactions.first.block_hash.to_hex,
      'transactions' => eth_transactions.map do |tx|
        {
          'hash' => tx.tx_hash.to_hex,
          'transactionIndex' => "0x" + tx.transaction_index.to_s(16),
          'input' => tx.input.to_hex,
          'chainId' => "0x" + tx.chain_id.to_s(16),
          'from' => tx.from_address.to_hex,
          'to' => tx.to_address.to_hex
        }
      end
    }

    receipt_result = eth_transactions.map do |tx|
      {
        'transactionHash' => tx.tx_hash.to_hex,
        'status' => "0x" + tx.status.to_s(16),
        'logs' => tx.logs
      }
    end
    
    [block_result, receipt_result]
  end
end
