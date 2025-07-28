require "rails_helper"

RSpec.describe "Halted Deposit Gas Consumption" do
  let(:client) { GethDriver.non_auth_client }
  let(:from_address) { "0x4800000000000000000000000000000000000000" }
  let(:mint_value) { 10_000_000 }
  let(:base_fee) { 100 }
  let(:gas_limit) { 100_000 }
  
  it 'should count gas for halted deposits that consume gas before halting' do
    # Compile the contract that consumes gas before halting
    contract = EVMHelpers.compile_contract('contracts/HaltedDepositGasConsumer')
    facet_data = EVMHelpers.get_deploy_data(contract, [])
    
    # Get initial state
    start_block = client.call("eth_getBlockByNumber", ["latest", true])
    sender_balance_before = client.call("eth_getBalance", [from_address, start_block['number']])
    
    # Deploy the contract via deposit transaction
    # This should consume gas before halting with INVALID opcode
    res = create_and_import_block(
      facet_data: facet_data,
      to_address: nil,
      from_address: from_address,
      gas_limit: gas_limit,
      expect_failure: true  # We expect this to fail due to INVALID opcode
    )
    
    # Get the latest block and transaction
    latest_block = client.call("eth_getBlockByNumber", ["latest", true])
    expect(latest_block).not_to be_nil
    expect(latest_block['transactions'].size).to eq(2)
    
    deposit_tx_response = latest_block['transactions'].second
    deposit_tx_receipt = client.call("eth_getTransactionReceipt", [deposit_tx_response['hash']])
    
    # THIS IS THE KEY TEST: Halted deposits should report actual gas consumed, not 0
    gas_used = deposit_tx_receipt['gasUsed'].to_i(16)
    
    expect(gas_used).to be > 0, 
      "Halted deposits that consume gas before halting should report actual gas used, not 0. " \
      "This allows attackers to fill blocks with computation that doesn't count against gas limit!"
    
    # Verify gas was properly deducted from the balance
    sender_balance_after = client.call("eth_getBalance", [from_address, "latest"])
    gas_price = deposit_tx_receipt['effectiveGasPrice'].to_i(16)
    total_gas_cost = gas_used * gas_price
    
    # Balance should be: previous + mint - gas_cost
    balance_change = sender_balance_after.to_i(16) - sender_balance_before.to_i(16)
    expected_balance_change = res.mint - total_gas_cost
    
    expect(balance_change).to eq(expected_balance_change),
      "Balance should be mint minus gas actually consumed"
    
    # Verify transaction status (should be failed but gas should still be consumed)
    expect(deposit_tx_receipt['status']).to eq('0x0'), "Transaction should have failed status"
    
    # Verify nonce was incremented despite failure
    # Note: This behavior might vary based on implementation
    # Some implementations might not increment nonce on failed deposits
  end
  
  it 'should count gas for deposits that run expensive operations before reverting' do
    # Use the Counter2 contract which has a createRevert function
    counter_contract = EVMHelpers.compile_contract('contracts/Counter2')
    counter_deploy_data = EVMHelpers.get_deploy_data(counter_contract, [0])
    
    # First deploy the counter contract
    deploy_res = create_and_import_block(
      facet_data: counter_deploy_data,
      to_address: nil,
      from_address: from_address
    )
    
    counter_address = deploy_res.contract_address
    
    # Now call createRevert with shouldRevert=true
    # This will do some work then revert
    call_contract_function(
      contract: counter_contract,
      address: counter_address,
      from: from_address,
      function: 'createRevert',
      args: [true],
      gas_limit: gas_limit,
      expect_failure: true
    )
    
    latest_block = client.call("eth_getBlockByNumber", ["latest", true])
    revert_tx = latest_block['transactions'].second
    revert_receipt = client.call("eth_getTransactionReceipt", [revert_tx['hash']])
    
    gas_used = revert_receipt['gasUsed'].to_i(16)
    
    expect(gas_used).to be > 21000, # Should be more than base transaction cost
      "Reverted deposits that perform expensive operations should report actual gas consumed"
  end
  
  it 'should count gas for deposits that consume all available gas' do
    # Deploy a contract that tries to consume all gas via infinite loop
    infinite_loop_contract = EVMHelpers.compile_contract('contracts/Counter2')
    counter_deploy_data = EVMHelpers.get_deploy_data(infinite_loop_contract, [0])
    
    # First deploy the counter contract normally
    deploy_res = create_and_import_block(
      facet_data: counter_deploy_data,
      to_address: nil,
      from_address: from_address
    )
    
    counter_address = deploy_res.contract_address
    
    # Now call the runOutOfGas function which should consume all available gas
    call_contract_function(
      contract: infinite_loop_contract,
      address: counter_address,
      from: from_address,
      function: 'runOutOfGas',
      args: [],
      gas_limit: gas_limit,
      expect_failure: true
    )
    
    latest_block = client.call("eth_getBlockByNumber", ["latest", true])
    out_of_gas_tx = latest_block['transactions'].second
    out_of_gas_receipt = client.call("eth_getTransactionReceipt", [out_of_gas_tx['hash']])
    
    gas_used = out_of_gas_receipt['gasUsed'].to_i(16)
    
    # When running out of gas, should consume all provided gas
    expect(gas_used).to eq(gas_limit),
      "Transactions that run out of gas should consume all provided gas limit"
  end
end