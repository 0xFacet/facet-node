module HexDataProcessor
  class CompressionLimitExceededError < StandardError; end

  def self.hex_to_utf8(hex_string, support_gzip:)
    clean_hex_string = hex_string.gsub(/\A0x/, '')
    binary_data = hex_string_to_binary(clean_hex_string)
    
    if support_gzip && gzip_compressed?(binary_data)
      decompressed_data = decompress_with_ratio_limit(binary_data, 10)
    else
      decompressed_data = binary_data
    end
  
    clean_utf8(decompressed_data)
  rescue Zlib::Error, CompressionLimitExceededError => e
    nil
  end

  def self.hex_string_to_binary(hex_string)
    [hex_string].pack('H*')
  end

  def self.gzip_compressed?(data)
    data[0..1].bytes == [0x1F, 0x8B]
  end

  def self.ungzip_if_necessary(binary_data, ratio_limit: 10)
    if gzip_compressed?(binary_data)
      return decompress_with_ratio_limit(binary_data, ratio_limit)
    end

    binary_data
  end

  def self.decompress_with_ratio_limit(data, max_ratio)
    original_size = data.bytesize
    decompressed = StringIO.new

    Zlib::GzipReader.wrap(StringIO.new(data)) do |gz|
      while chunk = gz.read(16.kilobytes) # Read in chunks
        decompressed.write(chunk)
        if decompressed.length > original_size * max_ratio
          raise CompressionLimitExceededError, "Compression ratio exceeded #{max_ratio}"
        end
      end
    end

    decompressed.string
  end

  def self.clean_utf8(binary_data)
    utf8_string = binary_data.force_encoding('UTF-8')
    
    unless utf8_string.valid_encoding?
      utf8_string = utf8_string.encode('UTF-8', invalid: :replace, undef: :replace, replace: "\uFFFD")
    end
    
    utf8_string.delete("\u0000")
  end
end
