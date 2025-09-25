# EIP-712 signature verification for Facet batches
class BatchSignatureVerifier
  include SysConfig
  
  # EIP-712 domain
  DOMAIN_NAME = "FacetBatch"
  DOMAIN_VERSION = "1"
  
  # Type hash for FacetBatchData
  # struct FacetBatchData {
  #   uint8 version;
  #   uint256 chainId;
  #   uint8 role;
  #   uint64 targetL1Block;
  #   bytes[] transactions;
  #   bytes extraData;
  # }
  BATCH_DATA_TYPE_HASH = Eth::Util.keccak256(
    "FacetBatchData(uint8 version,uint256 chainId,uint8 role,uint64 targetL1Block,bytes[] transactions,bytes extraData)"
  )
  
  attr_reader :chain_id
  
  def initialize(chain_id: ChainIdManager.current_l2_chain_id)
    @chain_id = chain_id
  end
  
  # Verify a batch signature and return the signer address
  # Returns nil if signature is invalid or missing
  # batch_data_rlp: The RLP array [version, chainId, role, targetL1Block, transactions[], extraData]
  def verify(batch_data_rlp, signature)
    return nil unless signature
    
    sig_bytes = signature.is_a?(ByteString) ? signature.to_bin : signature
    return nil unless sig_bytes.length == 65
    
    # Calculate EIP-712 hash of the RLP-encoded batch data
    message_hash = eip712_hash_rlp(batch_data_rlp)
    
    # Recover signer from signature
    recover_signer(message_hash, sig_bytes)
  rescue => e
    Rails.logger.debug "Signature verification failed: #{e.message}"
    nil
  end
  
  private
  
  def domain_separator
    # EIP-712 domain separator
    @domain_separator ||= begin
      domain_type_hash = Eth::Util.keccak256(
        "EIP712Domain(string name,string version,uint256 chainId)"
      )
      
      encoded = [
        domain_type_hash,
        Eth::Util.keccak256(DOMAIN_NAME),
        Eth::Util.keccak256(DOMAIN_VERSION),
        Eth::Util.zpad_int(chain_id, 32)
      ].join
      
      Eth::Util.keccak256(encoded)
    end
  end
  
  def eip712_hash_rlp(batch_data_rlp)
    # For RLP batches, we sign the keccak256 of the RLP-encoded FacetBatchData
    # This is simpler and more standard than EIP-712 structured data
    batch_data_encoded = Eth::Rlp.encode(batch_data_rlp)
    
    # Create the message to sign: Ethereum signed message prefix + hash
    message_hash = Eth::Util.keccak256(batch_data_encoded)
    
    # Apply EIP-191 personal message signing format
    # "\x19Ethereum Signed Message:\n32" + message_hash
    prefix = "\x19Ethereum Signed Message:\n32"
    Eth::Util.keccak256(prefix + message_hash)
  end
  
  def hash_transactions_array(transactions)
    # Hash array of transactions according to EIP-712
    # Each transaction is hashed, then the array of hashes is hashed
    tx_hashes = transactions.map { |tx| Eth::Util.keccak256(tx.to_bin) }
    encoded = tx_hashes.join
    Eth::Util.keccak256(encoded)
  end
  
  def recover_signer(message_hash, sig_bytes)
    # Extract r, s, v from signature
    r = sig_bytes[0, 32]
    s = sig_bytes[32, 32]
    v = sig_bytes[64].ord
    
    # Adjust v for EIP-155
    v = v < 27 ? v + 27 : v
    
    # Create signature for recovery
    # The eth.rb gem expects r (32 bytes) + s (32 bytes) + v (variable length hex)
    v_hex = v.to_s(16).rjust(2, '0')  # Ensure at least 2 hex chars
    signature_hex = r.unpack1('H*') + s.unpack1('H*') + v_hex
    
    # Recover public key and derive address
    public_key = Eth::Signature.recover(message_hash, signature_hex)
    # public_key_to_address expects a hex string
    public_key_hex = public_key.is_a?(String) ? public_key : public_key.uncompressed.unpack1('H*')
    address = Eth::Util.public_key_to_address(public_key_hex)
    # Handle both string and Eth::Address object returns
    address = address.is_a?(String) ? address : address.to_s
    
    Address20.from_hex(address)
  end
end