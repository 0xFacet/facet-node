require 'rails_helper'

RSpec.describe FacetBatchParser do
  let(:chain_id) { ChainIdManager.current_l2_chain_id }
  let(:parser) { described_class.new(chain_id: chain_id) }
  let(:l1_block_number) { 12345 }
  let(:l1_tx_index) { 5 }
  
  describe '#parse_payload' do
    context 'with valid batch' do
      let(:batch_data) do
        # RLP encoding for testing
        batch_data = [
          Eth::Util.serialize_int_to_big_endian(1),  # version
          Eth::Util.serialize_int_to_big_endian(chain_id),  # chainId
          Eth::Util.serialize_int_to_big_endian(FacetBatchConstants::Role::FORCED),  # role
          Eth::Util.serialize_int_to_big_endian(l1_block_number),  # targetL1Block
          [],  # transactions (empty array)
          ''   # extraData (empty)
        ]
        
        # FacetBatch = [FacetBatchData, signature]
        Eth::Rlp.encode([batch_data, ''])  # Empty signature for forced batch
      end
      
      let(:payload) do
        magic = FacetBatchConstants::MAGIC_PREFIX.to_bin
        length = [batch_data.length].pack('N')  # uint32 big-endian
        
        ByteString.from_bin(magic + length + batch_data)
      end
      
      it 'parses a valid batch' do
        batches = parser.parse_payload(payload, l1_block_number, l1_tx_index, FacetBatchConstants::Source::CALLDATA)
        
        expect(batches.length).to eq(1)
        batch = batches.first
        
        expect(batch.role).to eq(FacetBatchConstants::Role::FORCED)
        expect(batch.target_l1_block).to eq(l1_block_number)
        expect(batch.l1_tx_index).to eq(l1_tx_index)
        expect(batch.chain_id).to eq(chain_id)
        expect(batch.transactions).to be_empty
      end
    end
    
    context 'with invalid version' do
      let(:batch_data) do
        batch_data = [
          Eth::Util.serialize_int_to_big_endian(2),  # Wrong version
          Eth::Util.serialize_int_to_big_endian(chain_id),
          Eth::Util.serialize_int_to_big_endian(FacetBatchConstants::Role::FORCED),
          Eth::Util.serialize_int_to_big_endian(l1_block_number),
          [],
          ''
        ]
        Eth::Rlp.encode([batch_data])
      end
      
      let(:payload) do
        magic = FacetBatchConstants::MAGIC_PREFIX.to_bin
        length = [batch_data.length].pack('N')
        ByteString.from_bin(magic + length + batch_data)
      end
      
      it 'rejects batch with wrong version' do
        batches = parser.parse_payload(payload, l1_block_number, l1_tx_index, FacetBatchConstants::Source::CALLDATA)
        expect(batches).to be_empty
      end
    end
    
    context 'with wrong chain ID' do
      let(:batch_data) do
        batch_data = [
          Eth::Util.serialize_int_to_big_endian(1),  # version
          Eth::Util.serialize_int_to_big_endian(999999),  # Wrong chain ID
          Eth::Util.serialize_int_to_big_endian(FacetBatchConstants::Role::FORCED),  # role
          Eth::Util.serialize_int_to_big_endian(l1_block_number),  # targetL1Block
          [],  # transactions
          ''   # extraData
        ]
        Eth::Rlp.encode([batch_data])
      end
      
      let(:payload) do
        magic = FacetBatchConstants::MAGIC_PREFIX.to_bin
        length = [batch_data.length].pack('N')
        ByteString.from_bin(magic + length + batch_data)
      end
      
      it 'rejects batch with wrong chain ID' do
        batches = parser.parse_payload(payload, l1_block_number, l1_tx_index, FacetBatchConstants::Source::CALLDATA)
        expect(batches).to be_empty
      end
    end
    
    context 'with wrong target block' do
      let(:batch_data) do
        batch_data = [
          Eth::Util.serialize_int_to_big_endian(1),  # version
          Eth::Util.serialize_int_to_big_endian(chain_id),  # chainId
          Eth::Util.serialize_int_to_big_endian(FacetBatchConstants::Role::FORCED),  # role
          Eth::Util.serialize_int_to_big_endian(99999),  # Wrong target block
          [],  # transactions
          ''   # extraData
        ]
        Eth::Rlp.encode([batch_data])
      end
      
      let(:payload) do
        magic = FacetBatchConstants::MAGIC_PREFIX.to_bin
        length = [batch_data.length].pack('N')
        ByteString.from_bin(magic + length + batch_data)
      end
      
      # TODO
      # it 'rejects batch with wrong target block' do
      #   batches = parser.parse_payload(payload, l1_block_number, l1_tx_index, FacetBatchConstants::Source::CALLDATA)
      #   expect(batches).to be_empty
      # end
    end
    
    context 'with multiple batches in payload' do
      let(:batch1) { create_valid_batch_data }
      let(:batch2) { create_valid_batch_data }
      
      let(:payload) do
        magic = FacetBatchConstants::MAGIC_PREFIX.to_bin
        
        batch1_with_header = magic + [batch1.length].pack('N') + batch1
        batch2_with_header = magic + [batch2.length].pack('N') + batch2
        
        # Add some padding between batches
        ByteString.from_bin(batch1_with_header + "\x00" * 10 + batch2_with_header)
      end
      
      it 'finds multiple batches' do
        batches = parser.parse_payload(payload, l1_block_number, l1_tx_index, FacetBatchConstants::Source::CALLDATA)
        expect(batches.length).to eq(2)
      end
    end
    
    context 'with batch exceeding max size' do
      let(:oversized_data) { "\x00" * (FacetBatchConstants::MAX_BATCH_BYTES + 1) }
      
      let(:payload) do
        magic = FacetBatchConstants::MAGIC_PREFIX.to_bin
        length = [oversized_data.length].pack('N')
        ByteString.from_bin(magic + length + oversized_data)
      end
      
      it 'rejects oversized batch' do
        batches = parser.parse_payload(payload, l1_block_number, l1_tx_index, FacetBatchConstants::Source::CALLDATA)
        expect(batches).to be_empty
      end
    end
    
    context 'with malformed length field' do
      let(:payload) do
        magic = FacetBatchConstants::MAGIC_PREFIX.to_bin
        length = [999999].pack('N')  # Claims huge size but doesn't have the data
        ByteString.from_bin(magic + length + "\x00" * 100)
      end
      
      it 'handles malformed length gracefully' do
        batches = parser.parse_payload(payload, l1_block_number, l1_tx_index, FacetBatchConstants::Source::CALLDATA)
        expect(batches).to be_empty
      end
    end
  end
  
  private
  
  def create_valid_batch_data
    # Create valid RLP-encoded batch data
    batch_data = [
      Eth::Util.serialize_int_to_big_endian(1),  # version
      Eth::Util.serialize_int_to_big_endian(chain_id),  # chainId
      Eth::Util.serialize_int_to_big_endian(FacetBatchConstants::Role::FORCED),  # role
      Eth::Util.serialize_int_to_big_endian(l1_block_number),  # targetL1Block
      [],  # transactions (empty array)
      ''   # extraData (empty)
    ]
    
    # FacetBatch = [FacetBatchData, signature]
    facet_batch = [batch_data, '']  # Empty signature for forced batch
    
    # Return RLP-encoded batch
    Eth::Rlp.encode(facet_batch)
  end

  describe 'real blob parsing' do
    # This test uses real blob data from block 1193381
    # Original test was in test_blob_parse.rb
    it 'parses real blob data from block 1193381' do
      # Real blob data (already decoded from blob format via BlobUtils.from_blobs)
      blob_hex = '0x00000000000123450000008df88bf8890183face7b008408baf03af87bb87902f87683face7b8084773594008504a817c8008252089470997970c51812dc3a010c7d01b50e0d17dc79c888016345785d8a000080c080a09319812cf80571eaf0ff69a17e27537b4faf857c4268717ada7c2645fb0efab6a077e333b17b54b397972c1920bb1088d4de3c6a705061988a35d331d6e4c2ab6c80'

      decoded_bytes = ByteString.from_hex(blob_hex)
      parser = described_class.new(chain_id: 0xface7b)
 
      # Parse the blob
      batches = parser.parse_payload(
        decoded_bytes,
        1193381,
        0,
        FacetBatchConstants::Source::BLOB,
        {}
      )

      expect(batches).not_to be_empty
      expect(batches.length).to eq(1)

      batch = batches.first
      expect(batch.role).to eq(FacetBatchConstants::Role::FORCED)
      expect(batch.transactions).to be_an(Array)
      expect(batch.transactions.length).to eq(1)

      # The transaction should be an EIP-1559 transaction
      tx = batch.transactions.first
      expect(tx).to be_a(ByteString)
      
      # Verify it can be decoded as an Ethereum transaction
      decoded_tx = Eth::Tx.decode(tx.to_hex)
      expect(decoded_tx).to be_a(Eth::Tx::Eip1559)
      expect(decoded_tx.chain_id).to eq(0xface7b)
    end
  end
end