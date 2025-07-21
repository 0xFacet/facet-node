class FacetTransaction
  module Special
    # Builds the L1 attributes system transaction for the supplied FacetBlock.
    def l1_attributes_tx_from_blocks(facet_block)
      calldata = L1AttributesTxCalldata.build(facet_block)

      tx = new
      tx.chain_id = ChainIdManager.current_l2_chain_id
      tx.to_address = L1_INFO_ADDRESS
      tx.value = 0
      tx.mint = 0
      tx.gas_limit = 1_000_000
      tx.input = calldata
      tx.from_address = SYSTEM_ADDRESS

      tx.facet_block = facet_block

      payload = [
        facet_block.eth_block_hash.to_bin,
        Eth::Util.zpad_int(facet_block.sequence_number, 32)
      ].join

      tx.source_hash = FacetTransaction.compute_source_hash(
        ByteString.from_bin(payload),
        L1_INFO_DEPOSIT_SOURCE_DOMAIN
      )

      tx
    end

    # Builds a v1 ➜ v2 migration transaction for the supplied FacetBlock.
    def v1_to_v2_migration_tx_from_block(facet_block, batch_number:)
      unless facet_block.number == 1
        raise "Invalid block number #{facet_block.number}!"
      end

      function_selector = ByteString.from_bin(Eth::Util.keccak256('executeMigration()').first(4))
      upgrade_intent = "emit events required to complete v1 to v2 migration batch ##{batch_number}"

      tx = new
      tx.chain_id = ChainIdManager.current_l2_chain_id
      tx.to_address = MIGRATION_MANAGER_ADDRESS
      tx.value = 0
      tx.mint = 0
      tx.gas_limit = 10_000_000
      tx.input = function_selector
      tx.from_address = SYSTEM_ADDRESS

      tx.facet_block = facet_block

      tx.source_hash = FacetTransaction.compute_source_hash(
        ByteString.from_bin(Eth::Util.keccak256(upgrade_intent)),
        L1_INFO_DEPOSIT_SOURCE_DOMAIN
      )

      tx
    end

    # Builds a deployment transaction for the new L1Block implementation used at the Bluebird fork.
    def l1_block_implementation_deployment_tx(block)
      filename = Rails.root.join('contracts/src/upgrades/L1Block.sol')
      compiled = SolidityCompiler.compile(filename)
      bytecode = compiled['L1Block']['bytecode']

      upgrade_intent = 'deploy new L1Block implementation for Bluebird upgrade'

      tx = new
      tx.chain_id = ChainIdManager.current_l2_chain_id
      tx.to_address = nil # Contract creation
      tx.value = 0
      tx.mint = 0
      tx.gas_limit = 10_000_000
      tx.input = ByteString.from_hex('0x' + bytecode)
      tx.from_address = SYSTEM_ADDRESS

      tx.facet_block = block

      tx.source_hash = FacetTransaction.compute_source_hash(
        ByteString.from_bin(Eth::Util.keccak256(upgrade_intent)),
        L1_INFO_DEPOSIT_SOURCE_DOMAIN
      )

      tx
    end

    # Builds a proxy-upgrade transaction that points the L1Block proxy at the newly deployed implementation.
    def l1_block_proxy_upgrade_tx(block, deployment_nonce)
      rlp_encoded = Eth::Rlp.encode([
        SYSTEM_ADDRESS.to_bin,
        deployment_nonce
      ])

      implementation_address_bytes_20 = Eth::Util.keccak256(rlp_encoded).last(20)
      implementation_address_bytes_32 = Hash32.from_bin(implementation_address_bytes_20.rjust(32, "\x00"))
      implementation_address_hex = implementation_address_bytes_32.to_hex

      # prepare calldata for upgrade(address,address)
      function_selector = ByteString.from_bin(Eth::Util.keccak256('upgrade(address,address)').first(4))
      proxy_address_bytes_32 = Hash32.from_bin(L1_INFO_ADDRESS.to_bin.rjust(32, "\x00"))
      upgrade_data = ByteString.from_bin(
        function_selector.to_bin +
        proxy_address_bytes_32.to_bin +
        implementation_address_bytes_32.to_bin
      )

      upgrade_intent = "upgrade L1Block proxy to Bluebird implementation at #{implementation_address_hex}"

      tx = new
      tx.chain_id = ChainIdManager.current_l2_chain_id
      tx.to_address = PROXY_ADMIN_ADDRESS
      tx.value = 0
      tx.mint = 0
      tx.gas_limit = 10_000_000
      tx.input = upgrade_data
      tx.from_address = SYSTEM_ADDRESS

      tx.facet_block = block

      tx.source_hash = FacetTransaction.compute_source_hash(
        ByteString.from_bin(Eth::Util.keccak256(upgrade_intent)),
        L1_INFO_DEPOSIT_SOURCE_DOMAIN
      )
      
      tx
    end
  end
end

# Expose the helpers as class-methods on FacetTransaction.
FacetTransaction.extend(FacetTransaction::Special)
