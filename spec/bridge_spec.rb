require 'rails_helper'

RSpec.describe "Bridge contracts" do
  include ActiveSupport::Testing::TimeHelpers

  let(:from_address) { "0xc2172a6315c1d7f6855768f843c420ebb36eda97".downcase }
  let(:token_a) { "0x1000000000000000000000000000000000000000" }
  let(:token_b) { "0x2000000000000000000000000000000000000000" }
  let(:trusted_smart_contract) { "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }

  
  it 'bridges' do
    bridge_deploy_receipt = deploy_contract_with_proxy(
      implementation: 'legacy/EtherBridgeV064',
      from: from_address,
      gas_limit: 5_000_000,
      args: [
        "Bridge Tester",
        "BT",
        trusted_smart_contract
      ]
    )

    bridge_in_receipt = trigger_contract_interaction_and_expect_success(
      from: trusted_smart_contract,
      payload: {
        to: bridge_deploy_receipt.contract_address,
        data: {
          function: "bridgeIn",
          args: [from_address, 500]
        }
      }
    )
    
    bridge_out_receipt = trigger_contract_interaction_and_expect_success(
      from: from_address,
      payload: {
        to: bridge_deploy_receipt.contract_address,
        data: {
          function: "bridgeOut",
          args: [100]
        }
      }
    )
    
    withdrawalId = bridge_out_receipt.decoded_logs.
      detect{|i| i['event'] == 'InitiateWithdrawal'}['data']['withdrawalId']
    
    trigger_contract_interaction_and_expect_success(
      from: trusted_smart_contract,
      payload: {
        to: bridge_deploy_receipt.contract_address,
        data: {
          function: "markWithdrawalComplete",
          args: [from_address, withdrawalId]
        }
      }
    )
    
  end

end
