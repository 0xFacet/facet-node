require "rails_helper"

RSpec.describe "L1Block end-to-end" do
  include ActiveSupport::Testing::TimeHelpers
  include EVMTestHelper

  let(:depositor_address) { "0xdeaddeaddeaddeaddeaddeaddeaddeaddead0001" }

  # Define test values as variables for maintainability
  let(:sequence_number) { 7 }
  let(:eth_block_timestamp) { 1_700_000_000 }
  let(:eth_block_number) { 12_345 }
  let(:eth_block_base_fee_per_gas) { 1_000_000_000 }
  let(:fct_mint_rate) { 1_234 }
  let(:fct_total_minted) { 9_876 }
  let(:fct_period_start_block) { 5 }
  let(:fct_period_minted) { 321 }
  let(:fct_max_supply) { 622_222_222 }
  let(:fct_initial_target_per_period) { 29_595 }

  # Build a synthetic FacetBlock that is post-Bluebird fork so that
  # the Ruby calldata helper will include the new FCT fields.
  let(:facet_block) do
    FacetBlock.new(
      number: SysConfig.bluebird_fork_block_number + 1,
      sequence_number: sequence_number,
      eth_block_timestamp: eth_block_timestamp,
      eth_block_number: eth_block_number,
      eth_block_base_fee_per_gas: eth_block_base_fee_per_gas,
      eth_block_hash: Hash32.from_hex("0x" + "11" * 32),
      fct_mint_rate: fct_mint_rate,
      fct_total_minted: fct_total_minted,
      fct_period_start_block: fct_period_start_block,
      fct_period_minted: fct_period_minted,
      fct_mint_period_l1_data_gas: nil,
      fct_max_supply: nil, # Not used anymore, max_supply is a constant
      fct_bluebird_fork_per_period_target: fct_initial_target_per_period
    )
  end

  it "writes L1 attributes via setL1BlockValuesEcotone and reads them back" do
    # 1. Deploy implementation behind proxy so helpers recognise it.
    deploy_receipt = deploy_contract(
      from: depositor_address,
      contract: EVMHelpers.compile_contract("upgrades/L1Block"),
      args: []
    )
    l1_block_address = deploy_receipt.contract_address

    # 2. Build calldata for the attributes tx.
    calldata_bs = L1AttributesTxCalldata.build(facet_block) # ByteString
    calldata_hex = calldata_bs.to_hex

    # 3. Send the tx from the depositor account.
    tx_receipt = create_and_import_block(
      facet_data: calldata_hex,
      from_address: depositor_address,
      to_address: l1_block_address,
      gas_limit: 1_000_000
    )
    expect(tx_receipt.status).to eq(1)
    
    # 4. Decode the calldata for comparison.
    decoded = L1AttributesTxCalldata.decode(calldata_bs, facet_block.number)

    # 5. Read back values from the contract and compare.
    seq          = make_static_call(contract: l1_block_address, function_name: "sequenceNumber")
    block_time   = make_static_call(contract: l1_block_address, function_name: "timestamp")
    block_num    = make_static_call(contract: l1_block_address, function_name: "number")
    mint_rate    = make_static_call(contract: l1_block_address, function_name: "fctMintRate")
    total_minted = make_static_call(contract: l1_block_address, function_name: "fctTotalMinted")
    period_start = make_static_call(contract: l1_block_address, function_name: "fctPeriodStartBlock")
    period_minted = make_static_call(contract: l1_block_address, function_name: "fctPeriodMinted")
    max_supply   = make_static_call(contract: l1_block_address, function_name: "fctMaxSupply")
    initial_target = make_static_call(contract: l1_block_address, function_name: "fctBluebirdForkPerPeriodTarget")

    # Verify decoded values match contract values
    expect(seq).to eq(decoded[:sequence_number])
    expect(block_time).to eq(decoded[:timestamp])
    expect(block_num).to eq(decoded[:number])
    expect(mint_rate).to eq(decoded[:fct_mint_rate])
    expect(total_minted).to eq(decoded[:fct_total_minted])
    expect(period_start).to eq(decoded[:fct_period_start_block])
    expect(period_minted).to eq(decoded[:fct_period_minted])
    # fct_max_supply is not in decoded data since it's a constant
    expect(initial_target).to eq(decoded[:fct_bluebird_fork_per_period_target])
    
    # Verify contract values match original input values
    expect(seq).to eq(sequence_number)
    expect(block_time).to eq(eth_block_timestamp)
    expect(block_num).to eq(eth_block_number)
    expect(mint_rate).to eq(fct_mint_rate)
    expect(total_minted).to eq(fct_total_minted)
    expect(period_start).to eq(fct_period_start_block)
    expect(period_minted).to eq(fct_period_minted)
    expect(max_supply).to eq(FctMintCalculator.max_supply) # Now a constant
    expect(initial_target).to eq(fct_initial_target_per_period)
    
    # Verify decoded values match original input values
    expect(decoded[:sequence_number]).to eq(sequence_number)
    expect(decoded[:timestamp]).to eq(eth_block_timestamp)
    expect(decoded[:number]).to eq(eth_block_number)
    expect(decoded[:fct_mint_rate]).to eq(fct_mint_rate)
    expect(decoded[:fct_total_minted]).to eq(fct_total_minted)
    expect(decoded[:fct_period_start_block]).to eq(fct_period_start_block)
    expect(decoded[:fct_period_minted]).to eq(fct_period_minted)
    # fct_max_supply is not in decoded data since it's a constant
    expect(decoded[:fct_bluebird_fork_per_period_target]).to eq(fct_initial_target_per_period)
  end
  
  it "provides correct helper function values" do
    # Deploy and set up contract with known values
    deploy_receipt = deploy_contract(
      from: depositor_address,
      contract: EVMHelpers.compile_contract("upgrades/L1Block"),
      args: []
    )
    l1_block_address = deploy_receipt.contract_address
    
    # Use specific test values for helper functions
    test_l2_block = 6_500_000
    test_fct_total_minted = 195_000_000
    test_fct_max_supply = 622_222_222
    test_fct_mint_rate = 1_234
    
    facet_block = FacetBlock.new(
      number: test_l2_block,
      sequence_number: sequence_number,
      eth_block_timestamp: eth_block_timestamp,
      eth_block_number: eth_block_number,
      eth_block_base_fee_per_gas: eth_block_base_fee_per_gas,
      eth_block_hash: Hash32.from_hex("0x" + "11" * 32),
      fct_mint_rate: test_fct_mint_rate,
      fct_total_minted: test_fct_total_minted,
      fct_period_start_block: fct_period_start_block,
      fct_period_minted: fct_period_minted,
      fct_mint_period_l1_data_gas: nil,
      fct_max_supply: nil, # Not used anymore, max_supply is a constant
      fct_bluebird_fork_per_period_target: fct_initial_target_per_period
    )
    
    calldata_bs = L1AttributesTxCalldata.build(facet_block)
    calldata_hex = calldata_bs.to_hex
    
    tx_receipt = create_and_import_block(
      facet_data: calldata_hex,
      from_address: depositor_address,
      to_address: l1_block_address,
      gas_limit: 1_000_000
    )
    expect(tx_receipt.status).to eq(1)
    
    # NOTE: targetTotalMinted and pacingDelta functions were removed from the contract
    # as they are no longer needed with the fixed supply approach
    
    # Test targetNumBlocksInHalving
    target_blocks = make_static_call(
      contract: l1_block_address,
      function_name: "targetNumBlocksInHalving"
    )
    expect(target_blocks).to eq(2_628_000)
  end

  it "handles maximum values correctly" do
    # Define maximum values for each field type
    max_uint64 = 2**64 - 1
    max_uint128 = 2**128 - 1
    max_uint256 = 2**256 - 1
    
    # Test values at maximum
    max_sequence_number = max_uint64
    max_eth_block_timestamp = max_uint64
    max_eth_block_number = max_uint64
    max_eth_block_base_fee_per_gas = max_uint256
    max_fct_mint_rate = max_uint128
    max_fct_total_minted = max_uint128
    max_fct_period_start_block = max_uint128
    max_fct_period_minted = max_uint128
    max_fct_max_supply = max_uint128
    max_fct_initial_target_per_period = max_uint128
    
    # Build FacetBlock with maximum values
    max_facet_block = FacetBlock.new(
      number: SysConfig.bluebird_fork_block_number + 1,
      sequence_number: max_sequence_number,
      eth_block_timestamp: max_eth_block_timestamp,
      eth_block_number: max_eth_block_number,
      eth_block_base_fee_per_gas: max_eth_block_base_fee_per_gas,
      eth_block_hash: Hash32.from_hex("0x" + "ff" * 32),
      fct_mint_rate: max_fct_mint_rate,
      fct_total_minted: max_fct_total_minted,
      fct_period_start_block: max_fct_period_start_block,
      fct_period_minted: max_fct_period_minted,
      fct_mint_period_l1_data_gas: nil,
      fct_max_supply: nil, # Not used anymore, max_supply is a constant
      fct_bluebird_fork_per_period_target: max_fct_initial_target_per_period
    )
    
    # Deploy contract
    deploy_receipt = deploy_contract(
      from: depositor_address,
      contract: EVMHelpers.compile_contract("upgrades/L1Block"),
      args: []
    )
    l1_block_address = deploy_receipt.contract_address
    
    # Build and send calldata
    calldata_bs = L1AttributesTxCalldata.build(max_facet_block)
    calldata_hex = calldata_bs.to_hex
    
    tx_receipt = create_and_import_block(
      facet_data: calldata_hex,
      from_address: depositor_address,
      to_address: l1_block_address,
      gas_limit: 1_000_000
    )
    expect(tx_receipt.status).to eq(1)
    
    # Decode and verify
    decoded = L1AttributesTxCalldata.decode(calldata_bs, max_facet_block.number)
    
    # Read values from contract
    seq = make_static_call(contract: l1_block_address, function_name: "sequenceNumber")
    block_time = make_static_call(contract: l1_block_address, function_name: "timestamp")
    block_num = make_static_call(contract: l1_block_address, function_name: "number")
    mint_rate = make_static_call(contract: l1_block_address, function_name: "fctMintRate")
    total_minted = make_static_call(contract: l1_block_address, function_name: "fctTotalMinted")
    period_start = make_static_call(contract: l1_block_address, function_name: "fctPeriodStartBlock")
    period_minted = make_static_call(contract: l1_block_address, function_name: "fctPeriodMinted")
    max_supply = make_static_call(contract: l1_block_address, function_name: "fctMaxSupply")
    initial_target = make_static_call(contract: l1_block_address, function_name: "fctBluebirdForkPerPeriodTarget")
    
    # Verify all values match
    expect(seq).to eq(max_sequence_number)
    expect(block_time).to eq(max_eth_block_timestamp)
    expect(block_num).to eq(max_eth_block_number)
    expect(mint_rate).to eq(max_fct_mint_rate)
    expect(total_minted).to eq(max_fct_total_minted)
    expect(period_start).to eq(max_fct_period_start_block)
    expect(period_minted).to eq(max_fct_period_minted)
    expect(max_supply).to eq(FctMintCalculator.max_supply) # Now a constant
    expect(initial_target).to eq(max_fct_initial_target_per_period)
    
    # Verify decoded values match
    expect(decoded[:sequence_number]).to eq(max_sequence_number)
    expect(decoded[:timestamp]).to eq(max_eth_block_timestamp)
    expect(decoded[:number]).to eq(max_eth_block_number)
    expect(decoded[:fct_mint_rate]).to eq(max_fct_mint_rate)
    expect(decoded[:fct_total_minted]).to eq(max_fct_total_minted)
    expect(decoded[:fct_period_start_block]).to eq(max_fct_period_start_block)
    expect(decoded[:fct_period_minted]).to eq(max_fct_period_minted)
    # fct_max_supply is not in decoded data since it's a constant
    expect(decoded[:fct_bluebird_fork_per_period_target]).to eq(max_fct_initial_target_per_period)
  end
end
