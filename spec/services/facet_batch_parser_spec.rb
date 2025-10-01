require 'rails_helper'

RSpec.describe FacetBatchParser do
  let(:chain_id) { ChainIdManager.current_l2_chain_id }
  let(:parser) { described_class.new(chain_id: chain_id) }
  let(:l1_block_number) { 12345 }
  let(:l1_tx_index) { 5 }
  
  describe '#parse_payload' do
    context 'with valid permissionless batch' do
      let(:rlp_tx_list) do
        # Empty transaction list for testing
        Eth::Rlp.encode([])
      end

      let(:payload) do
        # Construct wire format: [MAGIC:8][CHAIN_ID:8][VERSION:1][ROLE:1][LENGTH:4][RLP_TX_LIST]
        magic = FacetBatchConstants::MAGIC_PREFIX.to_bin
        chain_id_bytes = [chain_id].pack('Q>')  # uint64 big-endian
        version_byte = [FacetBatchConstants::VERSION].pack('C')  # uint8
        role_byte = [FacetBatchConstants::Role::PERMISSIONLESS].pack('C')  # uint8
        length_bytes = [rlp_tx_list.length].pack('N')  # uint32 big-endian

        ByteString.from_bin(magic + chain_id_bytes + version_byte + role_byte + length_bytes + rlp_tx_list)
      end

      it 'parses a valid batch' do
        batches = parser.parse_payload(payload, l1_tx_index, FacetBatchConstants::Source::CALLDATA)

        expect(batches.length).to eq(1)
        batch = batches.first

        expect(batch.role).to eq(FacetBatchConstants::Role::PERMISSIONLESS)
        expect(batch.l1_tx_index).to eq(l1_tx_index)
        expect(batch.chain_id).to eq(chain_id)
        expect(batch.transactions).to be_empty
        expect(batch.signer).to be_nil
      end
    end
    
    context 'with invalid version' do
      let(:rlp_tx_list) do
        Eth::Rlp.encode([])
      end

      let(:payload) do
        magic = FacetBatchConstants::MAGIC_PREFIX.to_bin
        chain_id_bytes = [chain_id].pack('Q>')
        version_byte = [2].pack('C')  # Wrong version
        role_byte = [FacetBatchConstants::Role::PERMISSIONLESS].pack('C')
        length_bytes = [rlp_tx_list.length].pack('N')

        ByteString.from_bin(magic + chain_id_bytes + version_byte + role_byte + length_bytes + rlp_tx_list)
      end

      it 'rejects batch with wrong version' do
        batches = parser.parse_payload(payload, l1_tx_index, FacetBatchConstants::Source::CALLDATA)
        expect(batches).to be_empty
      end
    end
    
    context 'with wrong chain ID' do
      let(:rlp_tx_list) do
        Eth::Rlp.encode([])
      end

      let(:payload) do
        magic = FacetBatchConstants::MAGIC_PREFIX.to_bin
        chain_id_bytes = [999999].pack('Q>')  # Wrong chain ID
        version_byte = [FacetBatchConstants::VERSION].pack('C')
        role_byte = [FacetBatchConstants::Role::PERMISSIONLESS].pack('C')
        length_bytes = [rlp_tx_list.length].pack('N')

        ByteString.from_bin(magic + chain_id_bytes + version_byte + role_byte + length_bytes + rlp_tx_list)
      end

      it 'skips batch with wrong chain ID without parsing RLP' do
        batches = parser.parse_payload(payload, l1_tx_index, FacetBatchConstants::Source::CALLDATA)
        expect(batches).to be_empty
      end
    end
    
    context 'with multiple batches in payload' do
      let(:rlp_tx_list) { Eth::Rlp.encode([]) }

      let(:batch1) do
        create_valid_wire_batch(chain_id, FacetBatchConstants::Role::PERMISSIONLESS, rlp_tx_list)
      end

      let(:batch2) do
        create_valid_wire_batch(chain_id, FacetBatchConstants::Role::PERMISSIONLESS, rlp_tx_list)
      end

      let(:payload) do
        # Add some padding between batches
        ByteString.from_bin(batch1 + "\x00" * 10 + batch2)
      end

      it 'finds multiple batches' do
        batches = parser.parse_payload(payload, l1_tx_index, FacetBatchConstants::Source::CALLDATA)
        expect(batches.length).to eq(2)
      end
    end
    
    context 'with batch exceeding max size' do
      let(:oversized_rlp) { Eth::Rlp.encode(["\x00" * (FacetBatchConstants::MAX_BATCH_BYTES + 1)]) }

      let(:payload) do
        magic = FacetBatchConstants::MAGIC_PREFIX.to_bin
        chain_id_bytes = [chain_id].pack('Q>')
        version_byte = [FacetBatchConstants::VERSION].pack('C')
        role_byte = [FacetBatchConstants::Role::PERMISSIONLESS].pack('C')
        length_bytes = [oversized_rlp.length].pack('N')

        ByteString.from_bin(magic + chain_id_bytes + version_byte + role_byte + length_bytes + oversized_rlp)
      end

      it 'rejects oversized batch' do
        batches = parser.parse_payload(payload, l1_tx_index, FacetBatchConstants::Source::CALLDATA)
        expect(batches).to be_empty
      end
    end

    context 'with nested transaction entry' do
      let(:malformed_rlp) { Eth::Rlp.encode([["nested"]]) }

      let(:payload) do
        magic = FacetBatchConstants::MAGIC_PREFIX.to_bin
        chain_id_bytes = [chain_id].pack('Q>')
        version_byte = [FacetBatchConstants::VERSION].pack('C')
        role_byte = [FacetBatchConstants::Role::PERMISSIONLESS].pack('C')
        length_bytes = [malformed_rlp.length].pack('N')

        ByteString.from_bin(magic + chain_id_bytes + version_byte + role_byte + length_bytes + malformed_rlp)
      end

      it 'rejects transaction lists with non byte-string entries' do
        batches = parser.parse_payload(payload, l1_tx_index, FacetBatchConstants::Source::CALLDATA)
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
        batches = parser.parse_payload(payload, l1_tx_index, FacetBatchConstants::Source::CALLDATA)
        expect(batches).to be_empty
      end
    end
  end
  
  private
  
  def create_valid_wire_batch(chain_id, role, rlp_tx_list, signature = nil)
    # Create valid wire format batch
    magic = FacetBatchConstants::MAGIC_PREFIX.to_bin
    chain_id_bytes = [chain_id].pack('Q>')  # uint64 big-endian
    version_byte = [FacetBatchConstants::VERSION].pack('C')  # uint8
    role_byte = [role].pack('C')  # uint8
    length_bytes = [rlp_tx_list.length].pack('N')  # uint32 big-endian

    batch = magic + chain_id_bytes + version_byte + role_byte + length_bytes + rlp_tx_list

    # Add signature for priority batches
    if role == FacetBatchConstants::Role::PRIORITY && signature
      batch += signature
    end

    batch
  end

  describe 'real blob parsing' do
    it 'parses batch with real transaction in new format' do
      # Create a real EIP-1559 transaction (from the old format test)
      # This is the same transaction that was in the old blob, now in new format
      tx_hex = '0x02f87683face7b8084773594008504a817c8008252089470997970c51812dc3a010c7d01b50e0d17dc79c888016345785d8a000080c080a09319812cf80571eaf0ff69a17e27537b4faf857c4268717ada7c2645fb0efab6a077e333b17b54b397972c1920bb1088d4de3c6a705061988a35d331d6e4c2ab60'

      # Create RLP-encoded transaction list
      tx_bytes = ByteString.from_hex(tx_hex).to_bin
      rlp_tx_list = Eth::Rlp.encode([tx_bytes])

      # Build wire format batch for chain_id 0xface7b (16436859)
      chain_id = 0xface7b

      # Construct wire format: [MAGIC:8][CHAIN_ID:8][VERSION:1][ROLE:1][LENGTH:4][RLP_TX_LIST]
      magic = FacetBatchConstants::MAGIC_PREFIX.to_bin
      chain_id_bytes = [chain_id].pack('Q>')  # uint64 big-endian
      version_byte = [FacetBatchConstants::VERSION].pack('C')
      role_byte = [FacetBatchConstants::Role::PERMISSIONLESS].pack('C')
      length_bytes = [rlp_tx_list.length].pack('N')  # uint32 big-endian

      wire_batch = magic + chain_id_bytes + version_byte + role_byte + length_bytes + rlp_tx_list

      parser = described_class.new(chain_id: chain_id)

      # Parse the batch
      batches = parser.parse_payload(
        ByteString.from_bin(wire_batch),
        0,
        FacetBatchConstants::Source::BLOB,
        {}
      )

      expect(batches).not_to be_empty
      expect(batches.length).to eq(1)

      batch = batches.first
      expect(batch.role).to eq(FacetBatchConstants::Role::PERMISSIONLESS)
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

    it 'parses priority batch with signature' do
      # Create a simple transaction
      tx_hex = '0x02f87683face7b8084773594008504a817c8008252089470997970c51812dc3a010c7d01b50e0d17dc79c888016345785d8a000080c080a09319812cf80571eaf0ff69a17e27537b4faf857c4268717ada7c2645fb0efab6a077e333b17b54b397972c1920bb1088d4de3c6a705061988a35d331d6e4c2ab60'

      # Create RLP-encoded transaction list
      tx_bytes = ByteString.from_hex(tx_hex).to_bin
      rlp_tx_list = Eth::Rlp.encode([tx_bytes])

      chain_id = 0xface7b

      # Construct wire format for priority batch: [MAGIC:8][CHAIN_ID:8][VERSION:1][ROLE:1][LENGTH:4][RLP_TX_LIST][SIGNATURE:65]
      magic = FacetBatchConstants::MAGIC_PREFIX.to_bin
      chain_id_bytes = [chain_id].pack('Q>')
      version_byte = [FacetBatchConstants::VERSION].pack('C')
      role_byte = [FacetBatchConstants::Role::PRIORITY].pack('C')
      length_bytes = [rlp_tx_list.length].pack('N')

      # Create a dummy 65-byte signature (r: 32, s: 32, v: 1)
      signature = "\x00" * 32 + "\x00" * 32 + "\x1b"  # v=27 (0x1b)

      wire_batch = magic + chain_id_bytes + version_byte + role_byte + length_bytes + rlp_tx_list + signature

      parser = described_class.new(chain_id: chain_id)

      # Disable signature verification for this test
      allow(SysConfig).to receive(:enable_sig_verify?).and_return(false)

      # Parse the batch
      batches = parser.parse_payload(
        ByteString.from_bin(wire_batch),
        0,
        FacetBatchConstants::Source::BLOB,
        {}
      )

      expect(batches).not_to be_empty
      expect(batches.length).to eq(1)

      batch = batches.first
      expect(batch.role).to eq(FacetBatchConstants::Role::PRIORITY)
      expect(batch.transactions.length).to eq(1)
      expect(batch.signer).to be_nil  # Since we disabled verification
    end
  end
end
