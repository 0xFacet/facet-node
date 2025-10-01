require 'rails_helper'

RSpec.describe StandardL2Transaction do
  describe 'signature recovery' do
    let(:private_key) { Eth::Key.new }
    let(:from_address) { private_key.address.to_s }
    let(:to_address) { "0x70997970c51812dc003a010c7d01b50e0d17dc79" }
    let(:chain_id) { 0xface7b }
    
    describe '.recover_address_eip1559' do
      it 'recovers the correct address from EIP-1559 transaction' do
        # Create transaction data
        tx_data = [
          chain_id,                    # chainId
          1,                           # nonce  
          100000,                      # maxPriorityFeePerGas
          200000,                      # maxFeePerGas
          21000,                       # gasLimit
          to_address,                  # to
          1000000,                     # value
          "",                          # data
          []                           # accessList
        ]
        
        # Create signing hash (EIP-1559 uses type 2)
        encoded = "\x02" + Eth::Rlp.encode(tx_data)
        signing_hash = Eth::Util.keccak256(encoded)
        
        # Sign with private key (returns hex string with r, s, v)
        signature_hex = private_key.sign(signing_hash)
        # The signature is hex encoded: remove 0x prefix if present
        signature_hex = signature_hex.sub(/^0x/, '')
        
        # Extract r, s, v from hex signature
        r_hex = signature_hex[0...64]
        s_hex = signature_hex[64...128]
        v_hex = signature_hex[128..]
        
        # Convert to binary for our method
        r = [r_hex].pack('H*')
        s = [s_hex].pack('H*')
        v_raw = v_hex.to_i(16)
        
        # For EIP-1559, v should be 0 or 1
        # The signature has v=27 or v=28 from legacy format, convert to 0 or 1
        v = v_raw - 27
        
        # Recover address using our method
        decoded = tx_data
        recovered = StandardL2Transaction.recover_address_eip1559(decoded, v, r, s, chain_id)
        
        expect(recovered.to_hex.downcase).to eq(from_address.downcase)
      end
      
      it 'handles v values of 0 and 1 correctly' do
        tx_data = [chain_id, 1, 100000, 200000, 21000, to_address, 1000000, "", []]
        encoded = "\x02" + Eth::Rlp.encode(tx_data)
        signing_hash = Eth::Util.keccak256(encoded)
        
        # Test with v = 0
        signature_hex = private_key.sign(signing_hash)
        signature_hex = signature_hex.sub(/^0x/, '')
        r_hex = signature_hex[0...64]
        s_hex = signature_hex[64...128]
        r = [r_hex].pack('H*')
        s = [s_hex].pack('H*')
        
        recovered_v0 = StandardL2Transaction.recover_address_eip1559(tx_data, 0, r, s, chain_id)
        recovered_v1 = StandardL2Transaction.recover_address_eip1559(tx_data, 1, r, s, chain_id)
        
        # One of them should match the correct address
        addresses = [recovered_v0.to_hex.downcase, recovered_v1.to_hex.downcase]
        expect(addresses).to include(from_address.downcase)
      end
      
      it 'returns null address on recovery failure' do
        # Invalid signature data
        invalid_r = "\x00" * 32
        invalid_s = "\x00" * 32
        tx_data = [chain_id, 1, 100000, 200000, 21000, to_address, 1000000, "", []]
        
        expect { StandardL2Transaction.recover_address_eip1559(tx_data, 0, invalid_r, invalid_s, chain_id) }.to raise_error(StandardL2Transaction::DecodeError)
      end
    end
    
    describe '.recover_address_eip2930' do
      it 'recovers the correct address from EIP-2930 transaction' do
        # Create transaction data  
        tx_data = [
          chain_id,                    # chainId
          1,                           # nonce
          100000,                      # gasPrice
          21000,                       # gasLimit
          to_address,                  # to
          1000000,                     # value
          "",                          # data
          []                           # accessList
        ]
        
        # Create signing hash (EIP-2930 uses type 1)
        encoded = "\x01" + Eth::Rlp.encode(tx_data)
        signing_hash = Eth::Util.keccak256(encoded)
        
        # Sign with private key (returns hex string with r, s, v)
        signature_hex = private_key.sign(signing_hash)
        # The signature is hex encoded: remove 0x prefix if present
        signature_hex = signature_hex.sub(/^0x/, '')
        
        # Extract r, s, v from hex signature
        r_hex = signature_hex[0...64]
        s_hex = signature_hex[64...128]
        v_hex = signature_hex[128..]
        
        # Convert to binary for our method
        r = [r_hex].pack('H*')
        s = [s_hex].pack('H*')
        v = v_hex.to_i(16)
        
        # Recover address using our method
        recovered = StandardL2Transaction.recover_address_eip2930(tx_data, v, r, s, chain_id)
        
        expect(recovered.to_hex.downcase).to eq(from_address.downcase)
      end
    end
    
    describe '.recover_address_legacy' do
      it 'recovers the correct address from legacy transaction with EIP-155' do
        # For EIP-155, we need to differentiate between:
        # 1. The transaction data used for signing (includes chain_id, empty r, empty s)
        # 2. The transaction data stored/transmitted (just the basic fields)
        
        # Basic transaction data (what gets stored)
        tx_data_basic = [
          1,                           # nonce
          100000,                      # gasPrice
          21000,                       # gasLimit
          to_address,                  # to
          1000000,                     # value
          ""                           # data
        ]
        
        # For EIP-155 signing, append chain_id and empty r,s
        tx_data_for_signing = tx_data_basic + [chain_id, "", ""]
        
        # Create signing hash with EIP-155 fields
        encoded = Eth::Rlp.encode(tx_data_for_signing)
        signing_hash = Eth::Util.keccak256(encoded)
        
        # Sign with private key with chain_id for EIP-155
        signature_hex = private_key.sign(signing_hash, chain_id)
        signature_hex = signature_hex.sub(/^0x/, '')
        
        # Extract r, s, v from hex signature
        r_hex = signature_hex[0...64]
        s_hex = signature_hex[64...128]
        v_hex = signature_hex[128..]
        
        # Convert to binary for our method
        r = [r_hex].pack('H*')
        s = [s_hex].pack('H*')
        v = v_hex.to_i(16)  # This will be 2*chain_id + 35 + recovery_id
        
        # Our recovery method needs to handle EIP-155 internally
        # It should reconstruct the signing data with chain_id when v >= 35
        recovered = StandardL2Transaction.recover_address_legacy(tx_data_basic, v, r, s)
        
        expect(recovered.to_hex.downcase).to eq(from_address.downcase)
      end
      
      it 'recovers the correct address from pre-EIP-155 legacy transaction' do
        # Create transaction data without EIP-155
        tx_data = [
          1,                           # nonce
          100000,                      # gasPrice
          21000,                       # gasLimit
          to_address,                  # to
          1000000,                     # value
          ""                           # data
        ]
        
        # Create signing hash
        encoded = Eth::Rlp.encode(tx_data)
        signing_hash = Eth::Util.keccak256(encoded)
        
        # Sign with private key (returns hex string with r, s, v)
        signature_hex = private_key.sign(signing_hash)
        signature_hex = signature_hex.sub(/^0x/, '')
        
        # Extract r, s, v from hex signature
        r_hex = signature_hex[0...64]
        s_hex = signature_hex[64...128]
        v_hex = signature_hex[128..]
        
        # Convert to binary for our method
        r = [r_hex].pack('H*')
        s = [s_hex].pack('H*')
        v = v_hex.to_i(16)  # v is already 27 or 28 for legacy
        
        # Recover address using our method
        recovered = StandardL2Transaction.recover_address_legacy(tx_data, v, r, s)
        
        expect(recovered.to_hex.downcase).to eq(from_address.downcase)
      end
    end
    
    describe 'integration with Eth::Signature module' do
      it 'uses Eth::Signature.recover instead of instantiating Eth::Signature' do
        # This test verifies we're using the module method, not trying to instantiate
        expect(Eth::Signature).to respond_to(:recover)
        expect { Eth::Signature.new }.to raise_error(NoMethodError)
      end
      
      it 'passes correct parameters to Eth::Signature.recover' do
        tx_data = [chain_id, 1, 100000, 200000, 21000, to_address, 1000000, "", []]
        encoded = "\x02" + Eth::Rlp.encode(tx_data)
        signing_hash = Eth::Util.keccak256(encoded)
        
        signature_hex = private_key.sign(signing_hash)
        signature_hex = signature_hex.sub(/^0x/, '')
        r = [signature_hex[0...64]].pack('H*')
        s = [signature_hex[64...128]].pack('H*')
        v = signature_hex[128..].to_i(16) - 27  # Convert to 0 or 1 for EIP-1559
        
        # Mock to verify correct parameters
        # Our implementation passes a hex string for signature
        expected_signature = r.unpack1('H*') + s.unpack1('H*') + v.to_s(16).rjust(2, '0')
        expect(Eth::Signature).to receive(:recover).with(
          signing_hash,
          expected_signature,
          chain_id
        ).and_call_original
        
        StandardL2Transaction.recover_address_eip1559(tx_data, v, r, s, chain_id)
      end
    end
  end
end