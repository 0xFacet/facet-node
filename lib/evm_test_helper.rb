module EVMTestHelper
  include Memery
  include FacetTransactionHelper

  extend self
  
  class << self
    def contract_addresses
      @contract_addresses ||= {}
    end
  end
  
  def call_contract_function(
    contract:,
    address:,
    from:,
    function:,
    args: [],
    value: 0,
    gas_limit: 1_000_000,
    expect_failure: false,
    expect_blank: false,
    sub_calls: []
  )
    call_contract_functions([{
      contract: contract,
      address: address,
      from: from,
      function: function,
      args: args,
      value: value,
      gas_limit: gas_limit,
      expect_failure: expect_failure,
      expect_blank: expect_blank,
      sub_calls: sub_calls
    }]).first
  end
  
  def deploy_contract(
    from:,
    contract:,
    args: [],
    value: 0,
    gas_limit: 5_000_000,
    expect_failure: false
  )
    data = EVMHelpers.get_deploy_data(contract, args)
    
    res = create_and_import_block(
      facet_data: data,
      to_address: nil,
      from_address: from,
      value: value,
      gas_limit: gas_limit,
      expect_failure: expect_failure
    )
    
    EVMTestHelper.contract_addresses[res.contract_address] = contract
    res
  end
  
  def deploy_contract_with_proxy(
    from:,
    implementation:,
    args: [],
    value: 0,
    gas_limit: 5_000_000,
    expect_failure: false
  )
    begin
      pre_deploy = PredeployManager.get_contract_from_predeploy_info(name: implementation.split("/").last)
    rescue KeyError
      pre_deploy = nil
    end
    
    implementation_contract = if pre_deploy
      pre_deploy
    else
      address = deploy_contract(
        from: from,
        contract: EVMHelpers.compile_contract(implementation),
        args: [],
        value: value,
        gas_limit: gas_limit,
        expect_failure: expect_failure
      ).contract_address
      
      c = EVMTestHelper.contract_addresses[address]
      c.address = address
      c
    end
    
    initialize_calldata = TransactionHelper.get_function_calldata(
      contract: implementation_contract,
      function: 'initialize',
      args: args
    )
    
    res = deploy_contract(
      from: from,
      contract: PredeployManager.get_contract_from_predeploy_info(name: "ERC1967Proxy"),
      args: [implementation_contract.address, initialize_calldata],
      value: value,
      gas_limit: gas_limit,
      expect_failure: expect_failure
    )
    
    EVMTestHelper.contract_addresses[res.contract_address] = implementation
    res
  end
  
  def facet_transaction_to_eth_payload(facet_transaction)
    raise unless facet_transaction.gas_limit > 0
    
    chain_id_bin = Eth::Util.serialize_int_to_big_endian(facet_transaction.chain_id)
    to_bin = Eth::Util.hex_to_bin(facet_transaction.to_address.to_s)
    value_bin = Eth::Util.serialize_int_to_big_endian(facet_transaction.value)
    gas_limit_bin = Eth::Util.serialize_int_to_big_endian(facet_transaction.gas_limit)
    data_bin = Eth::Util.hex_to_bin(facet_transaction.input)

    # Encode the fields using RLP
    rlp_encoded = Eth::Rlp.encode([chain_id_bin, to_bin, value_bin, max_gas_fee_bin, gas_limit_bin, data_bin])

    # Add the transaction type prefix and convert to hex
    hex_payload = Eth::Util.bin_to_prefixed_hex([FacetTransaction::FACET_TX_TYPE].pack('C') + rlp_encoded)

    hex_payload
  end
  
  def create_and_import_block(*args, **kwargs)
    # If first arg is an array, we're doing multiple transactions
    if args.first.is_a?(Array)
      transactions = args.first
      
      # Convert each transaction params to facet payload
      eth_transactions = transactions.map do |tx|
        facet_payload = generate_facet_tx_payload(
          input: tx[:facet_data],
          to: tx[:to_address],
          gas_limit: tx[:gas_limit] || 1_000_000,
          value: tx[:value] || 0
        )
        
        {
          input: facet_payload,
          from_address: tx[:from_address],
          expect_error: tx[:expect_failure],
          expect_no_tx: tx[:expect_blank],
          events: tx[:events] || []
        }
      end
      
      import_eth_txs(eth_transactions)
    else
      # Original single transaction case
      facet_payload = generate_facet_tx_payload(
        input: kwargs[:facet_data],
        to: kwargs[:to_address],
        gas_limit: kwargs[:gas_limit] || 1_000_000,
        value: kwargs[:value] || 0
      )
      
      import_eth_tx(
        input: facet_payload,
        expect_error: kwargs[:expect_failure],
        expect_no_tx: kwargs[:expect_blank],
        from_address: kwargs[:from_address]
      )
    end
  end
  
  def trigger_contract_interaction(from:, payload:, expect_failure: false, expect_blank: false, block_timestamp: nil)
    contract = EVMTestHelper.contract_addresses.fetch(payload[:to]) rescue binding.irb

    contract = EVMHelpers.get_contract(contract, payload[:to])
    function = contract.functions.find { |f| f.name == payload[:data][:function] }
    args = TransactionHelper.convert_args(contract, payload[:data][:function], payload[:data][:args])

    # Get the call data for the function
    call_data = function.get_call_data(*args) rescue binding.irb

    # Create and import the block
    res = create_and_import_block(
      facet_data: call_data,
      from_address: from,
      to_address: payload[:to],
      value: payload[:data][:value] || 0,
      gas_limit: payload[:data][:gas_limit] || 1_000_000,
      expect_failure: expect_failure,
      block_timestamp: block_timestamp
    )

    res
  rescue => e
    binding.pry
    raise
  end

  def trigger_contract_interaction_and_expect_success(from:, payload:, block_timestamp: nil)
    if payload[:to].nil?
      res = deploy_contract_with_proxy(
        from: from,
        implementation: payload[:data][:type],
        args: (payload[:data][:args].is_a?(Hash) ? payload[:data][:args].values : payload[:data][:args]),
        value: payload[:data][:value] || 0,
        gas_limit: payload[:data][:gas_limit] || 1_000_000,
        expect_failure: false
      )
    else
      res = trigger_contract_interaction(from: from, payload: payload, expect_failure: false, block_timestamp: block_timestamp)
      
      unless res.status == 1
        raise "Transaction failed"
      end
      
      res
    end
  end

  def trigger_contract_interaction_and_expect_error(from:, payload:, error_msg_includes: nil, block_timestamp: nil)
    res = trigger_contract_interaction(from: from, payload: payload, expect_failure: true, block_timestamp: block_timestamp)

    # Ensure the transaction failed
    if res.status == 1
      raise "Transaction succeeded unexpectedly"
    end

    # Check for the expected error message
    # unless res.error_message.include?(error_msg_includes)
    #   raise "Expected error message not found"
    # end

    res
  end
  
  def fill_in_block_data(facet_block)
    geth_block = GethDriver.client.call("eth_getBlockByNumber", ["0x" + facet_block.number.to_s(16), true])
    receipts_data = GethDriver.client.call("eth_getBlockReceipts", ["0x" + facet_block.number.to_s(16)])
    
    facet_block.from_rpc_response(geth_block)

    receipts_data_by_hash = receipts_data.index_by { |receipt| receipt['transactionHash'] }

    receipts = []
    facet_txs = []

    geth_block['transactions'].each.with_index do |tx, index|
      receipt_details = receipts_data_by_hash[tx['hash']]

      facet_tx = FacetTransaction.new(source_hash: tx['sourceHash'])

      facet_tx.assign_attributes(
        tx_hash: tx['hash'],
        transaction_index: receipt_details['transactionIndex'].to_i(16),
        deposit_receipt_version: tx['depositReceiptVersion'].to_i(16),
        gas_limit: tx['gas'].to_i(16),
        tx_type: tx['type'],
        from_address: tx['from'],
        to_address: tx['to'],
        value: tx['value'].to_i(16),
        input: tx['input'],
        mint: tx['mint'].to_i(16)
      )

      facet_receipt = FacetTransactionReceipt.new(
        transaction_hash: tx['hash'],
        block_hash: facet_block.block_hash,
        block_number: facet_block.number,
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
      
      facet_txs << facet_tx
      receipts << facet_receipt
    end

    [facet_block, facet_txs, receipts]
  end
  
  def make_static_call(contract:, function_name:, function_args: {})
    address = contract
    contract = EVMTestHelper.contract_addresses.fetch(contract)

    contract_object = EVMHelpers.get_contract(contract, address)
    args = TransactionHelper.convert_args(contract_object, function_name, function_args)
    res = TransactionHelper.static_call(contract: contract_object, address: address, function: function_name, args: args)
    
    return unless res
    
    # if res.length == 1
    #   res.is_a?(Hash) ? res.values.first : res.first
    # else
      res
    # end
    
  rescue => e
    binding.irb
    raise
  end

  def call_contract_functions(calls)
    transactions = calls.map do |call|
      data = TransactionHelper.get_function_calldata(
        contract: call[:contract], 
        function: call[:function], 
        args: call[:args] || []
      )
      
      {
        facet_data: data,
        to_address: call[:address],
        from_address: call[:from],
        value: call[:value] || 0,
        gas_limit: call[:gas_limit] || 1_000_000,
        expect_failure: call[:expect_failure] || false,
        expect_blank: call[:expect_blank] || false,
        sub_calls: call[:sub_calls] || []
      }
    end
    
    create_and_import_block(transactions)
  end
end