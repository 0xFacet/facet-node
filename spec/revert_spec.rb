require "rails_helper"

RSpec.describe "Reverts" do
  let(:node_url) { 'http://localhost:8551' }
  let(:client) { GethClient.new(node_url) }
  let(:engine_api) { GethDriver }
  
  let(:from_address) { "0x000000000000000000000000000000000000000a" }
  
  let(:counter_contract) { EVMHelpers.compile_contract('contracts/Counter2') }
  
  let!(:counter_address) {
    facet_data = EVMHelpers.get_deploy_data(counter_contract, [1])
            
    res = create_and_import_block(
      facet_data: facet_data,
      to_address: nil,
      from_address: from_address
    )
    
    res.contract_address
  }
  
  # it do
  #   airdrop_address = deploy_contract_with_proxy(
  #     implementation: 'predeploys/AirdropERC20Vb02',
  #     from: from_address,
  #     args: [
  #       "Facet Cards",
  #       "Card",
  #       from_address,
  #       18,
  #       100.ether,
  #       1.ether
  #     ]
  #   ).contract_address
    
  #   create_and_import_block(
  #     facet_data: "0x7b227461626c65223a7b22616d6f756e74223a22323030303030303030303030303030303039353239343538363838227d7d",
  #     to_address: airdrop_address,
  #     from_address: from_address,
  #     expect_failure: true
  #   )
  # end
  
  it 'handles reverts' do
    call_contract_function(
      contract: counter_contract,
      address: counter_address,
      from: from_address,
      function: 'createRevert',
      args: [false]
    )
    
    call_contract_function(
      contract: counter_contract,
      address: counter_address,
      from: from_address,
      function: 'createRevert',
      args: [true],
      expect_failure: true
    )
  end
  
  it 'calls to non-existant function' do
    create_and_import_block(
      facet_data: "0x1234",
      to_address: counter_address,
      from_address: from_address,
      expect_failure: true
    )
  end
  
  it 'deploys an invalid contract' do
    create_and_import_block(
      facet_data: "0x1234",
      to_address: nil,
      from_address: from_address,
      expect_failure: true
    )
  end
  
  it 'reverts immediately in constructor' do
    counter_contract = EVMHelpers.compile_contract('contracts/ImmediateRevert')
  
    facet_data = EVMHelpers.get_deploy_data(counter_contract, [])
              
    res = create_and_import_block(
      facet_data: facet_data,
      to_address: nil,
      from_address: from_address,
      expect_failure: true
    )
  end
  
  it 'calls with wrong args' do
    data = TransactionHelper.get_function_calldata(
      contract: counter_contract,
      function: 'createRevert',
      args: [false]
    ).dup
    data[-1] = 'a'
    
    create_and_import_block(
      facet_data: data,
      to_address: counter_address,
      from_address: from_address,
      expect_failure: true
    )
  end
  
  it 'runs out of gas' do
    call_contract_function(
      contract: counter_contract,
      address: counter_address,
      from: from_address,
      function: 'runOutOfGas',
      args: [],
      expect_failure: true
    )
  end
  
  it 'sets an invalid to' do
    create_and_import_block(
      facet_data: "0x",
      to_address: "0x1234",
      from_address: from_address,
      expect_blank: true
    )
  end
  
  it 'hits the block gas limit' do
    block = Struct.new(:timestamp, :number).new(1, 1)
    limit = SysConfig.block_gas_limit(block)
    over_limit = limit + 1
    
    call_contract_function(
      contract: counter_contract,
      address: counter_address,
      from: from_address,
      function: 'runOutOfGas',
      args: [],
      expect_failure: true,
      gas_limit: over_limit
    )
  end
  
  it 'is underpriced' do
    call_contract_function(
      contract: counter_contract,
      address: counter_address,
      from: from_address,
      function: 'createRevert',
      args: [false],
    )
  end
  
  it 'tries to transfer too much' do
    from_address_balance = GethDriver.client.call('eth_getBalance', [from_address, 'latest']).to_i(16)
    
    create_and_import_block(
      facet_data: "0x",
      to_address: counter_address,
      from_address: from_address,
      value: from_address_balance + 1000.ether,
      eth_gas_used: 0,
      expect_failure: true
    )
  end
  
  it 'tries and invalid opcode' do
    create_and_import_block(
      facet_data: "0xaaaa",
      to_address: nil,
      from_address: from_address,
      expect_failure: true
    )
  end
end
