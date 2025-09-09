# EIP-4844 Blob helpers (parity with viem)
# - to_blobs: transforms arbitrary data (hex or bytes) into 4844 blobs.
# - from_blobs: reconstructs original data from blobs (hex in => hex out, bytes in => bytes out).

module BlobUtils
  # Parameters from the EIP-4844 spec (match viem/src/constants/blob.ts)
  BLOBS_PER_TRANSACTION = 6
  BYTES_PER_FIELD_ELEMENT = 32
  FIELD_ELEMENTS_PER_BLOB = 4096
  BYTES_PER_BLOB = BYTES_PER_FIELD_ELEMENT * FIELD_ELEMENTS_PER_BLOB
  MAX_BYTES_PER_TRANSACTION = BYTES_PER_BLOB * BLOBS_PER_TRANSACTION - 1 - (1 * FIELD_ELEMENTS_PER_BLOB * BLOBS_PER_TRANSACTION)

  class BlobSizeTooLargeError < StandardError; end
  class EmptyBlobError < StandardError; end

  # Transform arbitrary data (hex string starting with 0x or a raw byte String) into blobs.
  # Returns an array of hex strings (each starting with 0x) representing blobs.
  def self.to_blobs(data:)
    # Normalize input to raw bytes
    bytes =
      if data.is_a?(String) && data.match?(/\A0x/i)
        hex = data.sub(/\A0x/i, '')
        raise EmptyBlobError if hex.empty?
        [hex].pack('H*')
      elsif data.is_a?(String)
        data.b
      else
        # Fall back to String conversion
        data.to_s.b
      end

    raise EmptyBlobError if bytes.bytesize == 0
    raise BlobSizeTooLargeError if bytes.bytesize > MAX_BYTES_PER_TRANSACTION

    blobs = []
    position = 0
    active = true

    while active
      blob = []
      size = 0

      while size < FIELD_ELEMENTS_PER_BLOB
        segment = bytes.byteslice(position, BYTES_PER_FIELD_ELEMENT - 1) # 31-byte segment

        # Leading zero so field element does not overflow BLS modulus
        blob << 0x00
        blob.concat(segment ? segment.bytes : [])

        # If segment is underfilled (<31), append terminator and finish
        if segment.nil? || segment.bytesize < (BYTES_PER_FIELD_ELEMENT - 1)
          blob << 0x80
          active = false
          break
        end

        size += 1
        position += (BYTES_PER_FIELD_ELEMENT - 1)
      end

      # Right-pad blob with zeros
      if blob.length < BYTES_PER_BLOB
        blob.fill(0x00, blob.length...BYTES_PER_BLOB)
      end

      blobs << ("0x" + blob.pack('C*').unpack1('H*'))
    end

    blobs
  end

  # Transform blobs (array of hex strings with 0x prefix or byte Strings) back into original data.
  # If input blobs are hex strings, returns a hex string (0x...)
  # If input blobs are bytes, returns a raw byte String.
  def self.from_blobs(blobs:)
    return (blobs.first.is_a?(String) ? '0x' : ''.b) if blobs.nil? || blobs.empty?

    # Determine output format based on input type (match viem default behavior)
    return_hex = blobs.first.is_a?(String)

    active = true
    out = []

    blobs.each do |blob|
      bytes = if blob.is_a?(String)
        [blob.sub(/\A0x/i, '')].pack('H*').bytes
      else
        blob.bytes
      end

      pos = 0
      while active && pos < bytes.length
        # Skip leading 0x00 of the field element
        pos += 1

        consume = [BYTES_PER_FIELD_ELEMENT - 1, bytes.length - pos].min
        consume.times do
          byte = bytes[pos]
          pos += 1

          remaining = bytes[pos..-1] || []
          # Match viem: terminator if this byte is 0x80 and there is no other 0x80 in the rest of the current blob
          is_terminator = (byte == 0x80) && !remaining.include?(0x80)
          if is_terminator
            active = false
            break
          end

          out << byte
        end
      end
    end

    packed = out.pack('C*')
    return_hex ? ("0x" + packed.unpack1('H*')) : packed
  end
end