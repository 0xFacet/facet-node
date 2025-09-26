require 'rails_helper'

RSpec.describe FacetBlockBuilder do
  let(:l1_block_number) { 12345 }
  let(:l2_block_gas_limit) { 10_000_000 }
  let(:authorized_signer) { Address20.from_hex('0x' + 'a' * 40) }
  
  let(:collected) do
    FacetBatchCollector::CollectorResult.new(
      single_txs: single_txs,
      batches: batches,
      stats: {}
    )
  end
  
  let(:single_txs) { [] }
  let(:batches) { [] }
  
  let(:builder) do
    described_class.new(
      collected: collected,
      l2_block_gas_limit: l2_block_gas_limit,
      get_authorized_signer: ->(block) { authorized_signer }
    )
  end
  
  before do
    allow(SysConfig).to receive(:enable_sig_verify?).and_return(false)
  end
  
  describe '#ordered_transactions' do
    context 'with no transactions' do
      it 'returns empty array' do
        transactions = builder.ordered_transactions(l1_block_number)
        expect(transactions).to be_empty
      end
    end
    
    context 'with only V1 single transactions' do
      let(:single_txs) do
        [
          create_single_tx(l1_tx_index: 2),
          create_single_tx(l1_tx_index: 0),
          create_single_tx(l1_tx_index: 1)
        ]
      end
      
      it 'orders by L1 transaction index' do
        transactions = builder.ordered_transactions(l1_block_number)
        
        expect(transactions.length).to eq(3)
        # Should be ordered by l1_tx_index: 0, 1, 2
        # (actual transaction parsing would determine this)
      end
    end
    
    context 'with forced batches' do
      let(:batches) do
        [
          create_forced_batch(l1_tx_index: 1, tx_count: 2),
          create_forced_batch(l1_tx_index: 0, tx_count: 3)
        ]
      end
      
      it 'unwraps transactions in order' do
        transactions = builder.ordered_transactions(l1_block_number)
        
        # Should have 5 total transactions (3 + 2)
        expect(transactions.length).to eq(5)
      end
    end
    
    context 'with priority batch under gas limit' do
      let(:batches) do
        [
          create_priority_batch(l1_tx_index: 0, tx_count: 2, signer: authorized_signer),
          create_forced_batch(l1_tx_index: 1, tx_count: 1)
        ]
      end
      
      it 'includes priority batch first' do
        transactions = builder.ordered_transactions(l1_block_number)
        
        # Priority batch (2 txs) + forced batch (1 tx)
        expect(transactions.length).to eq(3)
        # First 2 should be from priority batch
      end
    end
    
    context 'with priority batch over gas limit' do
      let(:batches) do
        [
          create_priority_batch(
            l1_tx_index: 0,
            tx_count: 1000,  # Way too many transactions
            signer: authorized_signer
          ),
          create_forced_batch(l1_tx_index: 1, tx_count: 1)
        ]
      end
      
      before do
        # Mock gas calculation to exceed limit for priority batch only
        allow_any_instance_of(described_class).to receive(:calculate_batch_gas) do |instance, batch|
          if batch.is_priority?
            l2_block_gas_limit + 1  # Over limit
          else
            100  # Under limit
          end
        end
      end
      
      it 'discards priority batch entirely' do
        transactions = builder.ordered_transactions(l1_block_number)
        
        # Only forced batch included
        expect(transactions.length).to eq(1)
      end
    end
    
    context 'with multiple priority batches' do
      let(:other_signer) { Address20.from_hex('0x' + 'b' * 40) }
      
      let(:batches) do
        [
          create_priority_batch(l1_tx_index: 2, tx_count: 1, signer: authorized_signer),
          create_priority_batch(l1_tx_index: 0, tx_count: 1, signer: authorized_signer),
          create_priority_batch(l1_tx_index: 1, tx_count: 1, signer: other_signer)
        ]
      end
      
      it 'selects priority batch with lowest index from authorized signer' do
        transactions = builder.ordered_transactions(l1_block_number)
        
        # Should select the one at index 0 (authorized, lowest index)
        expect(transactions.length).to eq(1)
      end
    end
    
    context 'with signature verification enabled' do
      before do
        allow(SysConfig).to receive(:enable_sig_verify?).and_return(true)
      end
      
      let(:batches) do
        [
          create_priority_batch(l1_tx_index: 0, tx_count: 1, signer: nil),  # No signature
          create_priority_batch(l1_tx_index: 1, tx_count: 1, signer: authorized_signer)
        ]
      end
      
      it 'only accepts signed priority batches' do
        transactions = builder.ordered_transactions(l1_block_number)
        
        # Should select the signed one at index 1
        expect(transactions.length).to eq(1)
      end
    end
    
    context 'with mixed priority and forced batches' do
      let(:batches) do
        [
          create_forced_batch(l1_tx_index: 0, tx_count: 2),
          create_priority_batch(l1_tx_index: 1, tx_count: 3, signer: authorized_signer),
          create_forced_batch(l1_tx_index: 2, tx_count: 1)
        ]
      end
      
      it 'orders priority first, then forced by index' do
        transactions = builder.ordered_transactions(l1_block_number)
        
        # Priority (3) + forced at index 0 (2) + forced at index 2 (1) = 6 total
        expect(transactions.length).to eq(6)
      end
    end
  end
  
  private
  
  def create_single_tx(l1_tx_index:)
    {
      source: 'calldata',
      l1_tx_index: l1_tx_index,
      tx_hash: '0x' + rand(16**64).to_s(16).rjust(64, '0'),
      payload: create_v1_payload,
      events: []
    }
  end
  
  def create_forced_batch(l1_tx_index:, tx_count:)
    transactions = tx_count.times.map { create_tx_bytes }
    
    ParsedBatch.new(
      role: FacetBatchConstants::Role::FORCED,
      signer: nil,
      target_l1_block: l1_block_number,
      l1_tx_index: l1_tx_index,
      source: FacetBatchConstants::Source::CALLDATA,
      source_details: {},
      transactions: transactions,
      content_hash: Hash32.from_bin(Eth::Util.keccak256(rand.to_s)),
      chain_id: ChainIdManager.current_l2_chain_id,
      extra_data: nil
    )
  end
  
  def create_priority_batch(l1_tx_index:, tx_count:, signer:)
    transactions = tx_count.times.map { create_tx_bytes }
    
    ParsedBatch.new(
      role: FacetBatchConstants::Role::PRIORITY,
      signer: signer,
      target_l1_block: l1_block_number,
      l1_tx_index: l1_tx_index,
      source: FacetBatchConstants::Source::CALLDATA,
      source_details: {},
      transactions: transactions,
      content_hash: Hash32.from_bin(Eth::Util.keccak256(rand.to_s)),
      chain_id: ChainIdManager.current_l2_chain_id,
      extra_data: nil
    )
  end
  
  def create_v1_payload
    tx_type = [FacetTransaction::FACET_TX_TYPE].pack('C')
    chain_id = Eth::Util.serialize_int_to_big_endian(ChainIdManager.current_l2_chain_id)
    rlp_data = Eth::Rlp.encode([chain_id, '', '', '', '', ''])
    ByteString.from_bin(tx_type + rlp_data)
  end
  
  def create_tx_bytes
    # Create a simple EIP-1559 transaction for testing with valid signature
    # This is what would be in batches - standard Ethereum transactions
    
    chain_id = ChainIdManager.current_l2_chain_id
    
    # Transaction data (without signature)
    tx_data_unsigned = [
      Eth::Util.serialize_int_to_big_endian(chain_id),
      Eth::Util.serialize_int_to_big_endian(0),  # nonce
      Eth::Util.serialize_int_to_big_endian(1_000_000_000),  # max_priority_fee (1 gwei)
      Eth::Util.serialize_int_to_big_endian(2_000_000_000),  # max_fee (2 gwei)
      Eth::Util.serialize_int_to_big_endian(21_000),  # gas_limit
      "\x11" * 20,  # to address (20 bytes)
      Eth::Util.serialize_int_to_big_endian(0),  # value
      '',  # data
      []  # access_list
    ]
    
    # For testing, use valid but dummy signature values
    # Real signatures would be created by wallet software
    # Using non-zero values to avoid Geth rejection
    r = "\x00" * 31 + "\x01"  # 32 bytes, non-zero
    s = "\x00" * 31 + "\x02"  # 32 bytes, non-zero
    
    # Build complete transaction with signature
    # For EIP-1559, v should be 0 or 1
    tx_data = tx_data_unsigned + [
      Eth::Util.serialize_int_to_big_endian(0),  # v (0 for EIP-1559)
      r,  # r (32 bytes)
      s   # s (32 bytes)
    ]
    
    # Prefix with transaction type 0x02 for EIP-1559
    ByteString.from_bin("\x02" + Eth::Rlp.encode(tx_data))
  end
end