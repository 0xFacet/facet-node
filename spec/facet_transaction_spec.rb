# spec/models/facet_transaction_spec.rb
require 'rails_helper'

RSpec.describe FacetTransaction do
  describe '.deserialize_rlp_int' do
    context 'with valid RLP integers' do
      it 'deserializes empty string to zero' do
        expect(FacetTransaction.deserialize_rlp_int(''.b)).to eq(0)
      end

      it 'deserializes valid non-zero integers' do
        expect(FacetTransaction.deserialize_rlp_int("\x01".b)).to eq(1)
        expect(FacetTransaction.deserialize_rlp_int("\xff".b)).to eq(255)
        expect(FacetTransaction.deserialize_rlp_int("\x0f".b)).to eq(15)
      end

      it 'handles large numbers' do
        expect(FacetTransaction.deserialize_rlp_int("\xff\xff\xff\xff".b)).to eq(4294967295)
      end
    end

    context 'with invalid RLP integers' do
      it 'rejects integers with leading zeros' do
        expect {
          FacetTransaction.deserialize_rlp_int("\x00".b)
        }.to raise_error(FacetTransaction::InvalidRlpInt)

        expect {
          FacetTransaction.deserialize_rlp_int("\x00\x01".b)
        }.to raise_error(FacetTransaction::InvalidRlpInt)
      end
    end
  end

  describe '.from_payload' do
    let(:contract_initiated) { false }
    let(:from_address) { Address20.from_hex("0x" + "2" * 40) }
    let(:tx_hash) { Hash32.from_hex("0x" + "3" * 64) }
    
    def encode_tx(params)
      # Default valid parameters
      defaults = {
        chain_id: ChainIdManager.current_l2_chain_id,
        to: Address20.from_hex("0x" + "5" * 40),
        value: 1000,
        max_gas_fee: 1_000_000,
        gas_limit: 1_000_000,
        data: ByteString.from_hex("0x")
      }
      
      params = defaults.merge(params)
      
      # RLP encode the transaction
      rlp_encoded = Eth::Rlp.encode([
        Eth::Util.serialize_int_to_big_endian(params[:chain_id]),
        params[:to].to_bin,
        Eth::Util.serialize_int_to_big_endian(params[:value]),
        Eth::Util.serialize_int_to_big_endian(params[:max_gas_fee]),
        Eth::Util.serialize_int_to_big_endian(params[:gas_limit]),
        params[:data].to_bin
      ])
      
      tx_type = Eth::Util.serialize_int_to_big_endian(FacetTransaction::FACET_TX_TYPE)
      
      ByteString.from_bin("#{tx_type}#{rlp_encoded}").to_hex
    end

    context 'with valid transaction' do
      it 'decodes a basic transaction' do
        input = encode_tx({})
        tx = FacetTransaction.from_payload(
          contract_initiated: contract_initiated,
          from_address: from_address,
          eth_transaction_input: ByteString.from_hex(input),
          tx_hash: tx_hash,
        )
        
        expect(tx).to be_a(FacetTransaction)
        expect(tx.chain_id).to eq(ChainIdManager.current_l2_chain_id)
        expect(tx.from_address).to eq(from_address)
        expect(tx.contract_initiated).to eq(contract_initiated)
        expect(tx.eth_transaction_hash).to eq(tx_hash)
      end
    end

    context 'with invalid transaction' do
      it 'returns nil for invalid transaction type' do
        input = "0x00" + encode_tx({}).slice(4..)
        
        tx = FacetTransaction.from_payload(
          contract_initiated: contract_initiated,
          from_address: from_address,
          eth_transaction_input: ByteString.from_hex(input),
          tx_hash: tx_hash,
        )
        
        expect(tx).to be_nil
      end

      it 'returns nil for invalid RLP integers' do
        # Create transaction with leading zeros in value
        input = encode_tx({})
        modified_input = input.sub(/0x46[0-9a-f]*/) { |match|
          # Insert leading zero in the value field
          "\x46" + Eth::Rlp.encode([
            Eth::Util.serialize_int_to_big_endian(ChainIdManager.current_l2_chain_id),
            Eth::Util.hex_to_bin("0x" + "5" * 40),
            "\x00\x01",  # Value with leading zero
            Eth::Util.serialize_int_to_big_endian(1_000_000),
            Eth::Util.serialize_int_to_big_endian(1_000_000),
            ""
          ])
        }
        tx = FacetTransaction.from_payload(
          contract_initiated: contract_initiated,
          from_address: from_address,
          eth_transaction_input: ByteString.from_bin(modified_input),
          tx_hash: tx_hash,
        )
        
        expect(tx).to be_nil
      end
    end
  end

  # ------------------------------------------------------------------
  describe '#l1_data_gas_used' do
    let(:input_bytes) { "\x00\x11".b } # 1 zero, 1 non-zero
    let(:byte_string) { instance_double('ByteString', to_bin: input_bytes) }
    let(:eth_tx)      { instance_double('EthTransaction', input: byte_string) }

    context 'post-Bluebird pricing (10/40 gas)' do
      let(:tx) do
        described_class.new(contract_initiated: false).tap do |t|
          allow(t).to receive(:eth_transaction).and_return(eth_tx)
        end
      end
      let(:block_num) { SysConfig.bluebird_fork_block_number + 1 }

      before { allow(SysConfig).to receive(:is_bluebird?).with(block_num).and_return(true) }

      it 'correctly computes gas for a real calldata example' do
        hex = "46f90126830face794f29e6e319ac4ce8c100cfc02b1702eb3d275029e808303126bb9010438ed1739000000000000000000000000000000000000000000000014998f32ac7870000000000000000000000000000000000000000000000000000000dee03db22bdb9f00000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000c5631ea332d124db0d4b23ae725cd62302c762020000000000000000000000000000000000000000000000000de0b6b3a7640000000000000000000000000000000000000000000000000000000000000000000200000000000000000000000055ab0390a89fed8992e3affbf61d102490735e240000000000000000000000001673540243e793b0e77c038d4a88448eff524dce80"
        byte_string = ByteString.from_hex("0x" + hex)
        tx = described_class.new(contract_initiated: false, eth_transaction_input: byte_string)
        block_num = SysConfig.bluebird_fork_block_number + 1
        allow(SysConfig).to receive(:is_bluebird?).with(block_num).and_return(true)
        expect(tx.l1_data_gas_used(block_num)).to eq(6700)
      end
    end

    context 'contract-initiated transactions' do
      let(:input_bytes) { "\x00\x11".b }
      let(:byte_string) { ByteString.from_bin(input_bytes) }
      let(:tx) { described_class.new(contract_initiated: true, eth_transaction_input: byte_string) }
      let(:block_num) { SysConfig.bluebird_fork_block_number + 1 }

      it 'uses legacy 8 gas per byte regardless of fork' do
        expect(tx.l1_data_gas_used(block_num)).to eq(16) # 2 bytes * 8
      end
    end

    it 'correctly computes gas for a pre-Bluebird calldata example' do
      hex = "646174613a6170706c69636174696f6e2f766e642e66616365742e74782b6a736f6e3b72756c653d65736970362c7b226f70223a2263616c6c222c2264617461223a7b22746f223a22307835356162303339306138396665643839393265336166666266363164313032343930373335653234222c2266756e6374696f6e223a227472616e73666572222c2261726773223a7b22746f223a22307839463732343232423734463832323343424263314230303838374638363330656332333262613539222c22616d6f756e74223a2235353539303630303132323930383231303539303036227d7d7d"
      byte_string = ByteString.from_hex("0x" + hex)
      tx = described_class.new(contract_initiated: false, eth_transaction_input: byte_string)
      block_num = SysConfig.bluebird_fork_block_number - 1
      allow(SysConfig).to receive(:is_bluebird?).with(block_num).and_return(false)
      expect(tx.l1_data_gas_used(block_num)).to eq(3728)
    end
  end
end
