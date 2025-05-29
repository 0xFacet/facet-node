require "rails_helper"

RSpec.describe "L1Block end-to-end" do
  include ActiveSupport::Testing::TimeHelpers
  include EVMTestHelper

  let(:depositor_address) { "0xdeaddeaddeaddeaddeaddeaddeaddeaddead0001" }

  # Build a synthetic FacetBlock that is post-Bluebird fork so that
  # the Ruby calldata helper will include the new FCT fields.
  let(:facet_block) do
    FacetBlock.new(
      number: SysConfig.bluebird_fork_block_number + 1,
      sequence_number: 7,
      eth_block_timestamp: 1_700_000_000,
      eth_block_number: 12_345,
      eth_block_base_fee_per_gas: 1_000_000_000,
      eth_block_hash: Hash32.from_hex("0x" + "11" * 32),
      fct_mint_rate: 1_234,
      fct_total_minted: 9_876,
      fct_period_start_block: 5,
      fct_period_minted: 321,
      fct_mint_period_l1_data_gas: nil
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

    expect(seq).to eq(decoded[:sequence_number])
    expect(block_time).to eq(decoded[:timestamp])
    expect(block_num).to eq(decoded[:number])
    expect(mint_rate).to eq(decoded[:fct_mint_rate])
    expect(total_minted).to eq(decoded[:fct_total_minted])
    expect(period_start).to eq(decoded[:fct_period_start_block])
    expect(period_minted).to eq(decoded[:fct_period_minted])
  end
end 