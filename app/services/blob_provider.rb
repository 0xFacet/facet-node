# Fetches blob data from Ethereum beacon nodes
class BlobProvider
  attr_reader :beacon_client, :ethereum_client
  
  def initialize(beacon_client: nil, ethereum_client: nil)
    @beacon_client = beacon_client || EthereumBeaconNodeClient.l1
    @ethereum_client = ethereum_client || EthRpcClient.l1
    
    # Validate we have beacon node configured
    if ENV['ETHEREUM_BEACON_NODE_API_BASE_URL'].blank?
      raise "ETHEREUM_BEACON_NODE_API_BASE_URL must be set for blob support"
    end
  end
  
  # List all blob carriers in a block
  # Returns array of hashes with tx_hash, tx_index, and versioned_hashes
  def list_carriers(block_number, block_data: nil)
    # Use provided block data or fetch if not provided
    block = block_data || ethereum_client.get_block(block_number, true)
    return [] unless block && block['transactions']

    carriers = []
    block['transactions'].each do |tx|
      # Blob versioned hashes are in the transaction itself (type 3 transactions)
      next unless tx['blobVersionedHashes'] && !tx['blobVersionedHashes'].empty?
      
      carriers << {
        tx_hash: tx['hash'],
        tx_index: tx['transactionIndex'].to_i(16),
        versioned_hashes: tx['blobVersionedHashes']
      }
    end
    
    carriers
  end
  
  # Fetch blob data by versioned hash
  # Returns ByteString or nil if not found
  def get_blob(versioned_hash, block_number:, block_data: nil)
    # Fetch raw blob from beacon node
    raw_blob = fetch_blob_from_beacon(versioned_hash, block_number: block_number, block_data: block_data)
    return nil unless raw_blob

    # Decode from EIP-4844 blob format to get actual data
    decoded_data = BlobUtils.from_blobs(blobs: [raw_blob.to_hex])

    # Return as ByteString
    ByteString.from_hex(decoded_data)
  end

  private

  def fetch_blob_from_beacon(versioned_hash, block_number:, block_data: nil)
    # We must have a block number for deterministic blob fetching
    raise ArgumentError, "block_number is required for blob fetching" unless block_number

    # Use provided block data or fetch if not provided
    block = block_data || ethereum_client.get_block(block_number, false)
    
    # Get blob sidecars for this block's slot
    begin
      sidecars = beacon_client.get_blob_sidecars_for_execution_block(block)
      Rails.logger.debug "Block #{block_number}: Found #{sidecars&.size || 0} sidecars"
      return nil unless sidecars && !sidecars.empty?
      
      # Find the sidecar with matching versioned hash
      # Sidecars don't have versioned_hash field - must compute from KZG commitment
      sidecar = sidecars.find do |s|
        kzg = s['kzg_commitment'] || s['kzgCommitment']
        kzg && compute_versioned_hash(kzg) == versioned_hash
      end
      
      if sidecar
        # Extract the blob data
        blob_data = sidecar['blob']
        
        # Most beacon nodes return 0x-hex, but support base64 fallback
        if blob_data.start_with?('0x')
          # Already hex, return as ByteString
          return ByteString.from_hex(blob_data)
        else
          # Assume base64
          blob_bytes = Base64.decode64(blob_data)
          return ByteString.from_bin(blob_bytes)
        end
      end
    end
    
    Rails.logger.warn "Blob not found for versioned hash #{versioned_hash}"
    nil
  end
  
  def compute_versioned_hash(kzg_commitment)
    # EIP-4844 versioned hash: 0x01 || sha256(commitment)[1:]
    # Drop first byte of SHA256, prepend 0x01
    commitment_bytes = if kzg_commitment.start_with?('0x')
      [kzg_commitment[2..-1]].pack('H*')
    else
      Base64.decode64(kzg_commitment)
    end
    
    hash = Digest::SHA256.digest(commitment_bytes)
    # Drop first byte, take remaining 31 bytes
    "0x01" + hash[1..31].unpack1('H*')
  end
end