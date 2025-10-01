# Signature verification for Facet batches
class BatchSignatureVerifier
  include SysConfig

  attr_reader :chain_id

  def initialize(chain_id: ChainIdManager.current_l2_chain_id)
    @chain_id = chain_id
  end

  # Verify signature for new wire format
  # signed_data: [CHAIN_ID:8][VERSION:1][ROLE:1][RLP_TX_LIST]
  # signature: 65-byte secp256k1 signature
  def verify_wire_format(signed_data, signature)
    return nil unless signature

    sig_bytes = signature.is_a?(ByteString) ? signature.to_bin : signature
    return nil unless sig_bytes.length == 65

    # Hash the signed data
    message_hash = Eth::Util.keccak256(signed_data)

    # Recover signer from signature
    recover_signer(message_hash, sig_bytes)
  rescue StandardError => e
    if signature_error?(e)
      Rails.logger.debug "Signature verification failed: #{e.message}"
      nil
    else
      raise
    end
  end

  private
  
  def recover_signer(message_hash, sig_bytes)
    # Extract r, s, v from signature
    r = sig_bytes[0, 32]
    s = sig_bytes[32, 32]
    raw_v = sig_bytes[64].ord

    # Normalise recovery id so both {0,1} and {27,28} inputs are accepted
    v_normalised = raw_v
    v_normalised -= 27 if v_normalised >= 27

    unless [0, 1].include?(v_normalised)
      error_class = defined?(Eth::Signature::SignatureError) ? Eth::Signature::SignatureError : StandardError
      raise error_class, "Invalid recovery id #{raw_v}"
    end

    v = v_normalised + 27
    
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

  def signature_error?(error)
    return true if defined?(Eth::Signature::SignatureError) && error.is_a?(Eth::Signature::SignatureError)

    if defined?(Secp256k1) && Secp256k1.const_defined?(:Error)
      return true if error.is_a?(Secp256k1.const_get(:Error))
    end

    false
  end
end
