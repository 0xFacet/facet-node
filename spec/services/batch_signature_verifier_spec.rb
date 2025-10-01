require 'rails_helper'

RSpec.describe BatchSignatureVerifier do
  let(:chain_id) { ChainIdManager.current_l2_chain_id }
  let(:verifier) { described_class.new(chain_id: chain_id) }
  let(:key) { Eth::Key.new }

  def build_signed_data(role: FacetBatchConstants::Role::PRIORITY)
    tx_list = Eth::Rlp.encode([])
    [
      [chain_id].pack('Q>'),
      [FacetBatchConstants::VERSION].pack('C'),
      [role].pack('C'),
      tx_list
    ].join
  end

  def build_signature(message_hash)
    signature_hex = key.sign(message_hash).sub(/^0x/, '')
    [signature_hex].pack('H*')
  end

  describe '#verify_wire_format' do
    it 'accepts signatures with legacy v values (27/28)' do
      signed_data = build_signed_data
      message_hash = Eth::Util.keccak256(signed_data)
      signature = build_signature(message_hash)

      signer = verifier.verify_wire_format(signed_data, signature)

      expect(signer.to_hex.downcase).to eq(key.address.to_s.downcase)
    end

    it 'accepts signatures with normalised v values (0/1)' do
      signed_data = build_signed_data
      message_hash = Eth::Util.keccak256(signed_data)
      signature = build_signature(message_hash)

      normalised_signature = signature.dup
      normalised_signature.setbyte(64, normalised_signature.getbyte(64) - 27)

      signer = verifier.verify_wire_format(signed_data, normalised_signature)

      expect(signer.to_hex.downcase).to eq(key.address.to_s.downcase)
    end

    it 'returns nil for signatures with invalid recovery ids' do
      signed_data = build_signed_data
      message_hash = Eth::Util.keccak256(signed_data)
      signature = build_signature(message_hash)

      invalid_signature = signature.dup
      invalid_signature.setbyte(64, 5)

      signer = verifier.verify_wire_format(signed_data, invalid_signature)

      expect(signer).to be_nil
    end
  end
end
