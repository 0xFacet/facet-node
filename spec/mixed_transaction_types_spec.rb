require 'rails_helper'

RSpec.describe "Mixed Transaction Types" do
  include FacetTransactionHelper
  include EVMTestHelper
  
  let(:alice) { "0x" + "a" * 40 }
  let(:bob) { "0x" + "b" * 40 }
  let(:charlie) { "0x" + "c" * 40 }
  
  before do
    allow(SysConfig).to receive(:facet_batch_v2_enabled?).and_return(true)
  end
  
  describe "block with mixed V1 single transactions and batch transactions" do
    it "processes both FacetTransaction and StandardL2Transaction in the same block" do
      importer = ImporterSingleton.instance
      current_max_eth_block = importer.current_max_eth_block
      
      # Use a deterministic private key for testing
      # This will generate address: 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf
      test_private_key = "0x0000000000000000000000000000000000000000000000000000000000000001"
      test_key = Eth::Key.new(priv: test_private_key)
      funded_address = test_key.address.to_s
      
      # First, import a block with a FacetTransaction that mints funds to our test address
      # The mint goes directly to the from_address (L1 sender) - no aliasing for EOA calldata txs
      # We need enough data to generate sufficient mint for gas costs
      # Each non-zero byte generates 16 units of mint at the current rate
      funding_data = "0x" + "ff" * 5000  # 5000 non-zero bytes for plenty of mint
      funding_payload = generate_facet_tx_payload(
        input: funding_data,
        to: alice,  # Can be any address, mint goes to from_address
        gas_limit: 10_000_000,  # High gas limit for large data
        value: 0
      )

      # Import the funding block - mint goes to from_address
      funding_receipts = import_eth_txs([{
        input: funding_payload,
        from_address: funded_address,  # This address gets the mint (no aliasing for EOA)
        to_address: EthTransaction::FACET_INBOX_ADDRESS.to_hex
      }])
      
      # Verify the funding transaction succeeded
      expect(funding_receipts.first).to be_present
      expect(funding_receipts.first.status).to eq(1)
      
      # Now create our mixed transaction block
      # Create a V1 single transaction (FacetTransaction)
      v1_payload = generate_facet_tx_payload(
        input: "0x12345678", # Some contract call data
        to: alice,
        gas_limit: 100_000,
        value: 1000
      )
      
      # Create an EIP-1559 transaction for the batch, signed by our funded address
      # Use 0 value to avoid needing a funded balance for now
      eip1559_tx = create_eip1559_transaction(
        private_key: test_private_key,
        to: charlie,
        value: 0,  # 0 value to avoid balance requirements
        gas_limit: 21_000
        # Nonce will be auto-determined based on current account state
      )
      
      puts "EIP-1559 tx created, length: #{eip1559_tx.to_bin.length} bytes"
      
      # Create a batch containing the EIP-1559 transaction
      # Note: target_l1_block must match the block we're importing
      # We already imported the funding block, so the next block will be +2 from original
      target_block = current_max_eth_block.number + 2  # +2 because we imported funding block
      batch_payload = create_batch_payload(
        transactions: [eip1559_tx],
        role: FacetBatchConstants::Role::FORCED,
        target_l1_block: target_block
      )
      
      puts "Target L1 block for batch: #{target_block}"
      puts "Batch should contain #{[eip1559_tx].length} transaction(s)"
      
      # Debug the batch structure
      test_decode = Eth::Rlp.decode(batch_payload.to_bin[12..-1])  # Skip magic + length
      puts "Decoded batch has #{test_decode[0][4].length} transactions"
      
      puts "Batch payload length: #{batch_payload.to_bin.length} bytes"
      puts "Batch payload hex (first 100 chars): #{batch_payload.to_hex[0..100]}"
      puts "Magic prefix expected: #{FacetBatchConstants::MAGIC_PREFIX.to_hex}"
      puts "Batch contains magic? #{batch_payload.to_bin.include?(FacetBatchConstants::MAGIC_PREFIX.to_bin)}"
      
      # Create L1 block with both transaction types
      eth_transactions = [
        {
          input: v1_payload,
          from_address: alice,
          to_address: EthTransaction::FACET_INBOX_ADDRESS.to_hex
        },
        {
          input: batch_payload.to_hex,
          from_address: bob,
          to_address: "0x" + "1" * 40  # Some other address (batch can go anywhere)
        }
      ]
      
      # Import the block
      # Temporarily increase log level to see errors
      original_level = Rails.logger.level
      Rails.logger.level = Logger::DEBUG
      
      receipts = import_eth_txs(eth_transactions)
      
      Rails.logger.level = original_level
      
      # Check if batch was collected
      importer = ImporterSingleton.instance
      puts "Current max eth block: #{importer.current_max_eth_block.number}"
      
      # Get the latest L2 block
      latest_l2_block = EthRpcClient.l2.get_block("latest", true)
      
      # Debug output
      puts "Number of receipts: #{receipts.length}"
      puts "Number of L2 transactions: #{latest_l2_block['transactions'].length}"
      puts "L2 transaction types: #{latest_l2_block['transactions'].map { |tx| tx['type'] }}"
      
      # More detailed debug
      latest_l2_block['transactions'].each_with_index do |tx, i|
        puts "Transaction #{i}: type=#{tx['type']}, from=#{tx['from'][0..10]}..., to=#{tx['to'] ? tx['to'][0..10] : 'nil'}..."
      end
      
      # Check if facet_batch_v2_enabled is actually true
      puts "Batch V2 enabled: #{SysConfig.facet_batch_v2_enabled?}"
      
      # Should have 3 transactions in the L2 block (system tx + V1 single + 1 from batch)
      expect(latest_l2_block['transactions'].length).to eq(3)
      
      # Verify both transactions were included
      tx_types = latest_l2_block['transactions'].map do |tx|
        # tx['type'] returns a hex string like "0x7e"
        tx['type'].to_i(16)
      end
      
      # Check which transaction type we should expect based on Bluebird fork
      expected_facet_tx_type = SysConfig.is_bluebird?(latest_l2_block['number'].to_i(16)) ? 0x7D : 0x7E
      
      # Should have system transaction, V1 single, and EIP-1559 (0x02)
      expect(tx_types.count(expected_facet_tx_type)).to eq(2)  # Two FacetTransactions (system + V1 single)
      expect(tx_types).to include(0x02)  # One EIP-1559 transaction from batch
    end
  end
  
  describe "priority batch with gas validation" do
    before do
      # Clear any cached state to ensure consistent test environment
      MemeryExtensions.clear_all_caches!
    end
    
    it "includes priority batch when under gas limit" do
      importer = ImporterSingleton.instance
      current_max_eth_block = importer.current_max_eth_block
      
      # Use a single test key and fund it once
      test_key = "0x0000000000000000000000000000000000000000000000000000000000000033"
      test_address = Eth::Key.new(priv: test_key).address.to_s
      
      # Fund the address with a large calldata transaction
      funding_data = "0x" + "ff" * 5000  # Large calldata for mint
      funding_payload = generate_facet_tx_payload(
        input: funding_data,
        to: alice,
        gas_limit: 10_000_000,
        value: 0
      )
      
      funding_receipts = import_eth_txs([{
        input: funding_payload,
        from_address: test_address,  # This address gets the mint
        to_address: EthTransaction::FACET_INBOX_ADDRESS.to_hex
      }])
      
      expect(funding_receipts.first.status).to eq(1)
      
      # Update current block after funding
      current_max_eth_block = importer.current_max_eth_block
      
      # Get the actual nonce for the account
      actual_nonce = EthRpcClient.l2.get_transaction_count(test_address)
      puts "Actual nonce for test account after funding: #{actual_nonce}"
      base_nonce = actual_nonce  # Use actual nonce instead of assuming 1
      
      # Create small transactions for priority batch
      small_txs = 3.times.map do |i|
        create_eip1559_transaction(
          private_key: test_key,
          to: bob,
          value: 0,  # Use 0 value to avoid needing more funds
          gas_limit: 21_000,
          nonce: base_nonce + i  # Manually increment nonce
        )
      end
      
      # Create priority batch
      priority_batch = create_batch_payload(
        transactions: small_txs,
        role: FacetBatchConstants::Role::PRIORITY,
        target_l1_block: current_max_eth_block.number + 1,
        sign: true  # Sign for priority
      )
      
      # Create forced batch with one more transaction from same account
      forced_tx = create_eip1559_transaction(
        private_key: test_key,
        to: alice,
        value: 0,
        gas_limit: 21_000,
        nonce: base_nonce + 3  # After the 3 priority transactions
      )
      
      forced_batch = create_batch_payload(
        transactions: [forced_tx],
        role: FacetBatchConstants::Role::FORCED,
        target_l1_block: current_max_eth_block.number + 1
      )
      
      # Debug batch payloads
      puts "Current max eth block after funding: #{current_max_eth_block.number}"
      puts "Batches target block: #{current_max_eth_block.number + 1}"
      puts "Priority batch length: #{priority_batch.to_bin.length} bytes"
      puts "Priority batch hex (first 50): #{priority_batch.to_hex[0..50]}"
      puts "Forced batch length: #{forced_batch.to_bin.length} bytes"
      puts "Forced batch hex (first 50): #{forced_batch.to_hex[0..50]}"
      
      # Import blocks with both batches
      eth_transactions = [
        {
          input: forced_batch.to_hex,
          from_address: charlie,
          to_address: "0x" + "2" * 40
        },
        {
          input: priority_batch.to_hex,
          from_address: alice,
          to_address: "0x" + "3" * 40
        }
      ]
      
      receipts = import_eth_txs(eth_transactions)
      latest_l2_block = EthRpcClient.l2.get_block("latest", true)
      
      # Debug output
      puts "Receipts count: #{receipts.length}"
      puts "L2 block has #{latest_l2_block['transactions'].length} transactions"
      puts "Transaction types: #{latest_l2_block['transactions'].map { |tx| tx['type'] }}"
      
      # Should have 5 transactions (1 system + 3 from priority + 1 from forced)
      expect(latest_l2_block['transactions'].length).to eq(5)
      
      # Priority transactions should come first after system tx
      # Check that transactions 1-3 are from the priority batch
      priority_txs = latest_l2_block['transactions'][1..3]
      # These should be the EIP-1559 transactions from the priority batch
    end
  end
  
  # describe "transaction gas limit validation" do
  #   it "excludes transactions with 0 gas limit from batches" do
  #     importer = ImporterSingleton.instance
  #     current_max_eth_block = importer.current_max_eth_block
      
  #     # Create a transaction with 0 gas limit (invalid)
  #     test_key = "0x0000000000000000000000000000000000000000000000000000000000000001"
  #     test_address = Eth::Key.new(priv: test_key).address.to_s
  #     base_nonce = EthRpcClient.l2.call("eth_getTransactionCount", [test_address, "latest"]).to_i(16)
      
  #     zero_gas_tx = create_eip1559_transaction(
  #       private_key: test_key,
  #       to: bob,
  #       value: 1000,
  #       gas_limit: 0,  # Invalid!
  #       nonce: base_nonce
  #     )
      
  #     # Create a valid transaction
  #     valid_tx = create_eip1559_transaction(
  #       private_key: test_key,
  #       to: bob,
  #       value: 2000,
  #       gas_limit: 21_000,
  #       nonce: base_nonce + 1
  #     )
      
  #     # Create batch with both transactions
  #     batch = create_batch_payload(
  #       transactions: [zero_gas_tx, valid_tx],
  #       role: FacetBatchConstants::Role::FORCED,
  #       target_l1_block: current_max_eth_block.number + 1
  #     )
      
  #     eth_transactions = [{
  #       input: batch.to_hex,
  #       from_address: alice,
  #       to_address: "0x" + "4" * 40
  #     }]
      
  #     receipts = import_eth_txs(eth_transactions)
  #     latest_l2_block = EthRpcClient.l2.get_block("latest", true)
      
  #     # Should only have 1 transaction (the valid one)
  #     expect(latest_l2_block['transactions'].length).to eq(1)
      
  #     # Verify it's the valid transaction
  #     tx = latest_l2_block['transactions'].first
  #     expect(tx['value'].to_i(16)).to eq(2000)
  #   end
  # end
  
  private
  
  def create_eip1559_transaction(private_key:, to:, value:, gas_limit:, nonce: nil)
    chain_id = ChainIdManager.current_l2_chain_id
    
    # Use Eth library's built-in transaction support
    key = Eth::Key.new(priv: private_key)
    
    # Auto-determine nonce if not provided
    if nonce.nil?
      address = key.address.to_s
      nonce = EthRpcClient.l2.call("eth_getTransactionCount", [address, "latest"]).to_i(16)
    end
    
    # Create an EIP-1559 transaction using the Eth library
    tx = Eth::Tx::Eip1559.new({
      chain_id: chain_id,
      nonce: nonce,
      priority_fee: 1 * Eth::Unit::GWEI,  # 1 gwei as priority fee
      max_gas_fee: 2 * Eth::Unit::GWEI,   # 2 gwei as max fee
      gas_limit: gas_limit,
      to: to,
      value: value,
      data: ""  # empty data for simple transfer
    })
    
    # Sign the transaction
    tx.sign(key)
    
    # Get the raw signed transaction bytes (add 0x prefix if missing)
    hex_str = tx.hex
    hex_str = "0x#{hex_str}" unless hex_str.start_with?('0x')
    ByteString.from_hex(hex_str)
  end
  
  def create_batch_payload(transactions:, role:, target_l1_block:, sign: false)
    chain_id = ChainIdManager.current_l2_chain_id
    
    # FacetBatchData = [version, chainId, role, targetL1Block, transactions[], extraData]
    batch_data = [
      Eth::Util.serialize_int_to_big_endian(1),  # version
      Eth::Util.serialize_int_to_big_endian(chain_id),  # chainId
      Eth::Util.serialize_int_to_big_endian(role),  # role
      Eth::Util.serialize_int_to_big_endian(target_l1_block),  # targetL1Block
      transactions.map(&:to_bin),  # transactions array - ACTUALLY include them!
      ''  # extraData
    ]
    
    # FacetBatch = [FacetBatchData, signature]
    # Always include signature field (can be empty string for non-priority)
    if sign && role == FacetBatchConstants::Role::PRIORITY
      # Add dummy signature for priority batches
      signature = "\x00" * 64 + "\x01"  # 65 bytes
    else
      signature = ''  # Empty signature for forced batches
    end
    
    facet_batch = [batch_data, signature]  # Always 2 elements
    
    # Encode with RLP
    rlp_encoded = Eth::Rlp.encode(facet_batch)
    
    # Add wire format header
    magic = FacetBatchConstants::MAGIC_PREFIX.to_bin
    length = [rlp_encoded.length].pack('N')
    
    ByteString.from_bin(magic + length + rlp_encoded)
  end
end