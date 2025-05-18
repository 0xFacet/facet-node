require 'rails_helper'

RSpec.describe 'Reorg followed by duplicate-timestamp rejection', slow: true do
  # ------------------------------------------------------------------
  # Helper to temporarily patch EthBlockImporter to use the OLD
  # prune-and-return reorg logic, so we can prove that the spec fails
  # against the legacy implementation.
  # ------------------------------------------------------------------
  def with_legacy_reorg_logic
    klass = EthBlockImporter

    # Capture the original method to restore later
    original_method = klass.instance_method(:import_blocks)

    klass.class_eval do
      define_method(:import_blocks) do |block_numbers|
        begin
          original_method.bind_call(self, block_numbers)
        rescue EthBlockImporter::ReorgDetectedError => e
          parent_eth_block = eth_block_cache[block_numbers.first - 1]

          # OLD behaviour: prune caches and return silently
          if parent_eth_block
            eth_block_cache.delete_if { |n, _| n >= parent_eth_block.number }
            facet_block_cache.delete_if { |_, fb| fb.eth_block_number >= parent_eth_block.number }
          end
          logger.info 'Legacy prune-and-return executed'
          nil
        end
      end
    end

    yield
  ensure
    # restore original method
    klass.class_eval { define_method(:import_blocks, original_method) }
  end

  def build_block(number:, hash:, parent_hash:, timestamp:, parent_beacon_root: nil)
    blk = {
      'number' => "0x#{number.to_s(16)}",
      'hash' => hash,
      'parentHash' => parent_hash,
      'baseFeePerGas' => '0x1',
      'mixHash' => '0x' + '11' * 32,
      'timestamp' => "0x#{timestamp.to_s(16)}",
      'gasLimit' => '0x1',
      'gasUsed' => '0x0',
      'transactions' => [],
      'blobGasUsed' => '0x0',
      'blobGasPrice' => '0x0'
    }
    blk['parentBeaconBlockRoot'] = parent_beacon_root if parent_beacon_root
    blk
  end

  before do
    allow(EthTransaction).to receive(:facet_txs_from_rpc_results).and_return([])
  end

  def run_scenario(expect_success:)
    # ------------------------------------------------------------------
    # 0. Establish initial head (genesis) in caches
    # ------------------------------------------------------------------
    latest_l2 = GethDriver.client.call('eth_getBlockByNumber', ['latest', false])
    base_ts = latest_l2['timestamp'].to_i(16)
    head_facet = FacetBlock.from_rpc_result(latest_l2)
    head_facet.assign_attributes(
      sequence_number: 0,
      gas_used: 0,
      base_fee_per_gas: 1,
      eth_block_timestamp: base_ts,
      eth_block_number: 0,
      eth_block_hash: Hash32.from_hex(latest_l2['hash']),
      eth_block_base_fee_per_gas: 1,
      fct_mint_rate: 0,
      fct_mint_period_l1_data_gas: 0
    )

    importer = EthBlockImporter.send(:allocate)
    importer.instance_variable_set(:@l1_rpc_results, {})
    importer.instance_variable_set(:@facet_block_cache, { 0 => head_facet })

    hash0 = latest_l2['hash']
    zero_root = '0x' + '00' * 32
    eth_genesis = EthBlock.from_rpc_result(build_block(number: 0, hash: hash0, parent_hash: '0x' + '00' * 32, timestamp: base_ts, parent_beacon_root: zero_root))
    importer.instance_variable_set(:@eth_block_cache, { 0 => eth_genesis })
    importer.instance_variable_set(:@ethereum_client, double('EthRpcClient'))
    importer.instance_variable_set(:@geth_driver, GethDriver)
    allow(importer).to receive(:logger).and_return(double('Logger', info: nil))
    allow(importer).to receive(:current_block_number).and_return(2)

    # ------------------------------------------------------------------
    # 1. Import L1 block 1a (gap of 36s) – creates filler blocks
    # ------------------------------------------------------------------
    hash1a = '0x' + 'aa' * 32
    block_1a = build_block(number: 1, hash: hash1a, parent_hash: hash0, timestamp: base_ts + 36, parent_beacon_root: zero_root)
    importer.instance_variable_get(:@l1_rpc_results)[1] = {
      'block' => double('Promise', value!: block_1a),
      'receipts' => double('Promise', value!: [])
    }.with_indifferent_access

    facet_blocks_1, = importer.import_blocks([1])

    # Find the last filler block (should have eth_block_number 0)
    fillers = facet_blocks_1.select { |fb| fb.sequence_number.to_i > 0 }
    expect(fillers.size).to be >= 2
    filler_last = fillers.last
    expect(filler_last.timestamp).to eq(base_ts + 24)

    # ------------------------------------------------------------------
    # 2. Import L1 block 2b whose parentHash points to *new* hash1b -> triggers reorg
    # ------------------------------------------------------------------
    hash1b = '0x' + 'bb' * 32
    hash2b = '0x' + 'cc' * 32

    # block 2b refers to hash1b (unknown to cache) so reorg detected
    block_2b = build_block(number: 2, hash: hash2b, parent_hash: hash1b, timestamp: base_ts + 24, parent_beacon_root: zero_root)

    importer.instance_variable_get(:@l1_rpc_results)[2] = {
      'block' => double('Promise', value!: block_2b),
      'receipts' => double('Promise', value!: [])
    }.with_indifferent_access

    if expect_success
      expect {
        importer.import_blocks([2])
      }.to raise_error(EthBlockImporter::ReorgDetectedError)
    else
      importer.import_blocks([2])
    end

    head_after_reorg = importer.current_facet_head_block

    if expect_success
      # Rebuild importer to simulate scheduler behaviour after reorg
      mock_l1 = instance_double(EthRpcClient)
      genesis_hash = '0x' + '11' * 32
      genesis_block = {
        'number' => '0x0',
        'hash' => genesis_hash,
        'baseFeePerGas' => '0x1',
        'parentBeaconBlockRoot' => zero_root,
        'mixHash' => genesis_hash,
        'parentHash' => '0x' + '00' * 32,
        'timestamp' => "0x#{base_ts.to_s(16)}"
      }

      allow(mock_l1).to receive(:get_block_number).and_return(0)
      allow(mock_l1).to receive(:get_block).and_return(genesis_block)
      allow(mock_l1).to receive(:get_transaction_receipts).and_return([])

      allow(EthRpcClient).to receive(:new).and_return(mock_l1)
      allow(EthRpcClient).to receive(:l1).and_return(mock_l1)

      importer = EthBlockImporter.new
      head_after_reorg = importer.current_facet_head_block
    end

    # ------------------------------------------------------------------
    # 3. Attempt to propose new L2 block for 2b – duplicate timestamp behaviour
    # ------------------------------------------------------------------
    eth_block_2b = EthBlock.from_rpc_result(block_2b)
    new_facet_block = FacetBlock.from_eth_block(eth_block_2b)

    if expect_success
      produced_blocks = nil
      expect {
        produced_blocks = GethDriver.propose_block(
          transactions: [],
          new_facet_block: new_facet_block,
          head_block: head_after_reorg,
          safe_block: head_after_reorg,
          finalized_block: head_after_reorg
        )
      }.not_to raise_error

      final_block = produced_blocks.last
      expect(final_block.timestamp).to be > head_after_reorg.timestamp
    else
      # use last filler as head since prune logic left it in cache
      head_after_reorg = filler_last
      
      GethDriver.propose_block(
        transactions: [],
        new_facet_block: new_facet_block,
        head_block: head_after_reorg,
        safe_block: head_after_reorg,
        finalized_block: head_after_reorg
      )
    end

    head_after_reorg
  end

  it 'hits geth duplicate-timestamp error after a reorg that invalidates filler blocks' do
    run_scenario(expect_success: true)
  end

  context 'legacy behaviour (for regression proof)' do
    it 'fails with duplicate timestamp when old prune logic is used' do
      with_legacy_reorg_logic do
        expect { run_scenario(expect_success: false) }.to raise_error(GethClient::ClientError)
      end
    end
  end
end 