require 'rails_helper'

RSpec.describe EthBlockImporter do
  include FacetTransactionHelper

  let(:facet_payload) do
    generate_facet_tx_payload(
      input: "0x1234",
      to: "0x" + "1" * 40,
      gas_limit: 1_000_000
    )
  end
  
  describe '#import_next_block' do
    it 'correctly imports a valid Facet transaction' do
      combined = import_eth_tx(
        input: facet_payload,
        expect_error: false
      )
      
      expect(combined.to).to eq("0x" + "1" * 40)
      
      facet_block = FacetBlock.from_rpc_result(combined.l2_block)
      expect_calldata_mint_to_be(facet_block, facet_payload, combined.mint)
    end

    it 'handles an invalid Facet transaction with zero gas limit' do
      invalid_payload = generate_facet_tx_payload(
        input: "0x1234",
        to: "0x" + "1" * 40,
        gas_limit: 0
      )

      import_eth_tx(
        input: invalid_payload,
        expect_error: true
      )
    end

    it 'correctly processes an event-based Facet transaction' do
      contract_from = Address20.from_hex("0x" + "3" * 40)
      aliased_contract_from = AddressAliasHelper.apply_l1_to_l2_alias(contract_from)
      
      events = [
        generate_event_log(facet_payload, contract_from.to_hex, 0)
      ]
      
      combined = import_eth_tx(
        input: "0x1234",
        events: events
      )
      
      expect(combined.from).to eq(aliased_contract_from.to_hex)
    end
    
    it "won't import more than one event-based Facet transaction" do
      contract_from = "0x" + "3" * 40
      events = [
        generate_event_log(facet_payload, contract_from, 0),
        generate_event_log(facet_payload, contract_from, 1)
      ]
      
      combined_receipt = import_eth_tx(input: "0x1234", events: events)
      expect(combined_receipt.l2_block['transactions'].count).to eq(2)
    end
    
    it "won't import a removed event" do
      contract_from = "0x" + "3" * 40
      events = [
        generate_event_log(facet_payload, contract_from, 0, true),
      ]
      
      import_eth_tx(
        input: "0x1234",
        events: events,
        expect_no_tx: true
      )
    end
    
    it "won't import malformed RLP" do
      import_eth_tx(
        input: "0x1234",
        expect_no_tx: true
      )
      
      chain_id = ChainIdManager.current_l2_chain_id
      value = 0
      max_gas_fee = 1_000_000_000
      input = "0x1234"
      to = "0x" + "1" * 40
      gas_limit = 1_000_000
  
      rlp_encoded = Eth::Rlp.encode([
        Eth::Util.serialize_int_to_big_endian(chain_id),
        Eth::Util.hex_to_bin(to.to_s),
        Eth::Util.serialize_int_to_big_endian(value),
        Eth::Util.serialize_int_to_big_endian(max_gas_fee),
        Eth::Util.serialize_int_to_big_endian(gas_limit),
        Eth::Util.hex_to_bin(input),
        Eth::Util.hex_to_bin(input),
        Eth::Util.hex_to_bin(input)
      ])
  
      payload = "0x#{FacetTransaction::FACET_TX_TYPE.to_s(16).rjust(2, '0')}#{rlp_encoded.unpack1('H*')}"
      
      import_eth_tx(
        input: payload,
        expect_no_tx: true
      )
      
      bad_to = generate_facet_tx_payload(
        input: "0x1234",
        to: "0x1234",
        gas_limit: 1_000_000
      )
      
      import_eth_tx(
        input: bad_to,
        expect_no_tx: true
      )
    end
  end
end
