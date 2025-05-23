require "rails_helper"

RSpec.describe GethDriver do
  let(:client) { GethDriver.non_auth_client }
  
  describe 'block and deposit transaction' do
    it 'deploys a contract with a deposit tx' do
      initial_count = 5
      contract = EVMHelpers.compile_contract('contracts/Counter2')
      facet_data = EVMHelpers.get_deploy_data(contract, [initial_count])
      
      from_address = "0x" + "0" * 39 + 'a'
      to_address = nil
      
      start_block = client.call("eth_getBlockByNumber", ["latest", true])
      
      res = create_and_import_block(
        facet_data: facet_data,
        to_address: to_address,
        from_address: from_address,
      )
      
      expect(res.status).to eq(1)
      
      latest_block = client.call("eth_getBlockByNumber", ["latest", true])
      expect(latest_block).not_to be_nil
      expect(latest_block['transactions'].size).to eq(2)

      deposit_tx_response = latest_block['transactions'].second
      expect(deposit_tx_response['input']).to eq("0x" + facet_data)
      
      deposit_tx_receipt = client.call("eth_getTransactionReceipt", [deposit_tx_response['hash']])
      
      expect(deposit_tx_receipt).not_to be_nil
      expect(deposit_tx_receipt['from']).to eq(from_address)
      expect(deposit_tx_receipt['to']).to eq(to_address)
      
      sender_balance_before = client.call("eth_getBalance", [from_address, start_block['number']])
      sender_balance_after = client.call("eth_getBalance", [from_address, "latest"])
      # Retrieve gas used and gas price
      gas_used = deposit_tx_receipt['gasUsed'].to_i(16)
      gas_price = deposit_tx_receipt['effectiveGasPrice'].to_i(16)
      total_gas_cost = gas_used * gas_price
      
      # Validate balance change considering mint amount and gas cost
      balance_change = sender_balance_after.to_i(16) - sender_balance_before.to_i(16)
      expected_balance_change = res.mint - total_gas_cost
      
      expect(balance_change).to eq(expected_balance_change)

      contract_address = deposit_tx_receipt['contractAddress']
      
      logs = deposit_tx_receipt['logs']
      expect(logs).not_to be_empty

      deployed_event_topic = "0x" + Eth::Util.keccak256("Deployed(address,string)").unpack1('H*')
      log_event = logs.find { |log| log['topics'].include?(deployed_event_topic) }
      
      expect(log_event).not_to be_nil
      expect(log_event['address']).to eq(contract_address)
      expect(log_event['topics'][1]).to eq("0x" + from_address[2..].rjust(64, '0'))
      
      decoded_data = Eth::Abi.decode(["string"], ByteString.from_hex(log_event['data']).to_bin)
      expect(decoded_data[0]).to eq("Hello, World!")
   
      contract = EVMHelpers.get_contract('contracts/Counter2', contract_address)
      function = contract.parent.function_hash['getCount']
      
      data = function.get_call_data
      
      result = client.call("eth_call", [{
        to: contract_address,
        data: data
      }, "latest"])
      
      expect(function.parse_result(result)).to eq(initial_count)
      
      function = contract.parent.function_hash['increment']
      
      facet_data = function.get_call_data
      
      res = create_and_import_block(
        facet_data: facet_data,
        to_address: contract_address,
        from_address: "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf",
      )
      
      expect(res.status).to eq(1)
      
      # Verify the new block and the increment transaction
      latest_block = client.call("eth_getBlockByNumber", ["latest", true])
      expect(latest_block).not_to be_nil
      expect(latest_block['transactions'].size).to eq(2)

      increment_tx_response = latest_block['transactions'].second
      
      tx_of_interest = res
      
      expect(increment_tx_response['input']).to eq(tx_of_interest.input)

      increment_tx_receipt = client.call("eth_getTransactionReceipt", [increment_tx_response['hash']])
      expect(increment_tx_receipt).not_to be_nil
      expect(increment_tx_receipt['from']).to eq(tx_of_interest.from)
      
      expect(increment_tx_receipt['to']).to eq(tx_of_interest.to)

      function = contract.parent.function_hash['getCount']
      
      data = function.get_call_data
      
      result = client.call("eth_call", [{
        to: contract_address,
        data: data
      }, "latest"])
      # binding.pry
      expect(function.parse_result(result)).to eq(initial_count + 1)
    end
    
    it 'creates a block with the correct properties and verifies the deposit transaction' do
      start_block = client.call("eth_getBlockByNumber", ["latest", true])
      
      res = create_and_import_block(
        facet_data: "0x",
        to_address: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd",
        from_address: "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf",
        gas_limit: 21000,
      )
      
      expect(res.status).to eq(1)
      
      # Step 4: Verify the block was created with the correct properties
      latest_block = client.call("eth_getBlockByNumber", ["latest", true])
      expect(latest_block).not_to be_nil
      expect(latest_block['transactions'].size).to eq(2)

      # Step 5: Verify the deposit transaction
      deposit_tx_response = latest_block['transactions'].second
      
      expect(deposit_tx_response['input']).to eq(res.input)
      
      deposit_tx_receipt = client.call("eth_getTransactionReceipt", [deposit_tx_response['hash']])
      expect(deposit_tx_receipt).not_to be_nil
      expect(deposit_tx_receipt['from']).to eq(res.from)
      expect(deposit_tx_receipt['to']).to eq(res.to)
      
      sender_balance_before = client.call("eth_getBalance", [res.from, start_block['number']])
      sender_balance_after = client.call("eth_getBalance", [res.from, "latest"])

      # Retrieve gas used and gas price
      gas_used = deposit_tx_receipt['gasUsed'].to_i(16)
      gas_price = deposit_tx_receipt['effectiveGasPrice'].to_i(16)
      total_gas_cost = gas_used * gas_price

      # Validate balance change considering mint amount and gas cost
      balance_change = sender_balance_after.to_i(16) - sender_balance_before.to_i(16)
      expected_balance_change = res.mint - total_gas_cost
      # binding.pry
      expect(balance_change).to eq(expected_balance_change)
    end
  end
end
