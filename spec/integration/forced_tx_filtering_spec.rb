require 'rails_helper'

RSpec.describe 'Forced Transaction Filtering' do
  include FacetTransactionHelper

  before do
    allow(SysConfig).to receive(:facet_batch_v2_enabled?).and_return(true)
    # Silence blob fetching in tests to avoid noisy warnings
    allow_any_instance_of(BlobProvider).to receive(:list_carriers).and_return([])
    allow_any_instance_of(BlobProvider).to receive(:get_blob).and_return(nil)
  end

  it 'filters invalid forced txs (pre-flight) and still builds the block' do
    importer = ImporterSingleton.instance
    current_max_eth_block = importer.current_max_eth_block

    # Use a deterministic key for a funded account
    funded_priv = '0x0000000000000000000000000000000000000000000000000000000000000003'
    funded_addr = Eth::Key.new(priv: funded_priv).address.to_s

    # 1) Fund the account with a Facet V1 single (calldata-based mint)
    funding_data = '0x' + 'ff' * 5000
    funding_payload = generate_facet_tx_payload(
      input: funding_data,
      to: '0x' + 'a' * 40,
      gas_limit: 10_000_000,
      value: 0
    )

    funding_receipts = import_eth_txs([
      {
        input: funding_payload,
        from_address: funded_addr,
        to_address: EthTransaction::FACET_INBOX_ADDRESS.to_hex
      }
    ])
    expect(funding_receipts.first).to be_present
    expect(funding_receipts.first.status).to eq(1)

    # 2) Build one valid EIP-1559 tx from the funded account
    valid_tx = create_eip1559_transaction(
      private_key: funded_priv,
      to: '0x' + 'c' * 40,
      value: 0,
      gas_limit: 21_000
    )

    # 3) Build one invalid EIP-1559 tx (insufficient funds) from a fresh account
    unfunded_priv = '0x00000000000000000000000000000000000000000000000000000000000000aa'
    unfunded_addr = Eth::Key.new(priv: unfunded_priv).address.to_s
    invalid_tx = create_eip1559_transaction(
      private_key: unfunded_priv,
      to: '0x' + 'd' * 40,
      value: 0,
      gas_limit: 21_000
    )

    # 4) Create a FORCED batch with both transactions (invalid first exercises filtering)
    target_block = current_max_eth_block.number + 2
    batch_payload = create_forced_batch_payload(
      transactions: [invalid_tx, valid_tx],
      target_l1_block: target_block
    )

    # 5) Import the L1 block that carries the forced batch
    import_eth_txs([
      {
        input: batch_payload.to_hex,
        from_address: '0x' + '1' * 40,
        to_address: '0x' + '2' * 40
      }
    ])

    # 6) Verify L2 block includes only the valid EIP-1559 tx (plus system tx)
    latest_l2_block = EthRpcClient.l2.get_block('latest', true)
    txs = latest_l2_block['transactions']

    # Count EIP-1559 transactions
    eip1559_count = txs.count { |t| t['type'].to_i(16) == 0x02 }
    expect(eip1559_count).to eq(1)

    # Ensure the unfunded sender is not present, and the funded sender is present
    froms = txs.map { |t| (t['from'] || '').downcase }
    expect(froms).to include(funded_addr.downcase)
    expect(froms).not_to include(unfunded_addr.downcase)
  end

  # Helpers (scoped to this spec)
  def create_eip1559_transaction(private_key:, to:, value:, gas_limit:, nonce: nil)
    chain_id = ChainIdManager.current_l2_chain_id
    key = Eth::Key.new(priv: private_key)

    if nonce.nil?
      nonce = EthRpcClient.l2.call('eth_getTransactionCount', [key.address.to_s, 'latest']).to_i(16)
    end

    tx = Eth::Tx::Eip1559.new(
      chain_id: chain_id,
      nonce: nonce,
      priority_fee: 1 * Eth::Unit::GWEI,
      max_gas_fee: 2 * Eth::Unit::GWEI,
      gas_limit: gas_limit,
      to: to,
      value: value,
      data: ''
    )
    tx.sign(key)
    hex = tx.hex
    hex = '0x' + hex unless hex.start_with?('0x')
    ByteString.from_hex(hex)
  end

  def create_forced_batch_payload(transactions:, target_l1_block:)
    chain_id = ChainIdManager.current_l2_chain_id

    # Create RLP-encoded transaction list
    rlp_tx_list = Eth::Rlp.encode(transactions.map(&:to_bin))

    # Build wire format: [MAGIC:#{FacetBatchConstants::MAGIC_SIZE}][CHAIN_ID:8][VERSION:1][ROLE:1][LENGTH:4][RLP_TX_LIST]
    payload = FacetBatchConstants::MAGIC_PREFIX.to_bin
    payload += [chain_id].pack('Q>')  # uint64 big-endian
    payload += [FacetBatchConstants::VERSION].pack('C')
    payload += [FacetBatchConstants::Role::PERMISSIONLESS].pack('C')
    payload += [rlp_tx_list.length].pack('N')
    payload += rlp_tx_list

    ByteString.from_bin(payload)
  end
end
