module BaseFeeGetter
  extend self

  MAX_RETRIES = 5
  RETRY_DELAY = 2

  def ethereum_client
    @_ethereum_client ||= begin
      client_class = ENV.fetch('ETHEREUM_CLIENT_CLASS', 'AlchemyClient').constantize
      client_class.new(
        api_key: ENV['ETHEREUM_CLIENT_API_KEY'],
        base_url: ENV.fetch('ETHEREUM_CLIENT_BASE_URL')
      )
    end
  end

  def start_block
    network = ENV.fetch('ETHEREUM_NETWORK')
    
    network == "eth-mainnet" ? 18684900 : 5192784
    
    # 20441267 - 1000
  end
  
  def fetch_base_fees(fetch_batch_size = 100, save_batch_size = 10000)
    current_block = start_block
    base_fees = {}

    loop do
      block_numbers = (current_block...(current_block + fetch_batch_size)).to_a
      block_promises = block_numbers.map do |block_number|
        Concurrent::Promise.execute do
          retry_with_backoff do
            [block_number, ethereum_client.get_block(block_number)]
          end
        end
      end

      block_responses = block_promises.map(&:value!).compact

      break if block_responses.empty?

      fees_collected = false
      block_responses.each do |block_number, block|
        next unless block && block['result']
        
        base_fee = block['result']['baseFeePerGas']
        if base_fee
          base_fees[block_number] = base_fee
          fees_collected = true
        end
      end

      # Break if no base fees were collected in this batch
      break unless fees_collected

      current_block += fetch_batch_size

      # Save if the accumulated base fees reach the save batch size
      if base_fees.size >= save_batch_size
        puts "Saving base fees for blocks #{current_block - base_fees.size} to #{current_block - 1}"
        save_to_json(base_fees, "base_fees_#{current_block - base_fees.size}_to_#{current_block - 1}.json")
        base_fees.clear # Clear the hash to free up memory after each batch
      end
    end

    # Save any remaining base fees
    unless base_fees.empty?
      puts "Saving remaining base fees for blocks #{current_block - base_fees.size} to #{current_block - 1}"
      save_to_json(base_fees, "base_fees_#{current_block - base_fees.size}_to_#{current_block - 1}.json")
    end
  end
  
  HEX_REGEX = /\A0x[0-9a-fA-F]+\z/

  def read_and_verify_json_files
    dir = Rails.root.join("base_fees")
    files = Dir.glob(dir.join("base_fees_*.json"))

    all_base_fees = {}

    files.each do |file|
      data = JSON.parse(File.read(file))
      data.each do |block, fee|
        block_number = block.to_i
        if fee.nil? || !fee.match?(HEX_REGEX)
          raise "Invalid fee value for block #{block_number}: #{fee.inspect}"
        end
        all_base_fees[block_number] = fee
      end
    end

    all_base_fees
  end

  def verify_and_print_block_ranges
    all_base_fees = read_and_verify_json_files

    all_blocks = all_base_fees.keys.sort

    first_block = all_blocks.first
    last_block = all_blocks.last

    puts "First block: #{first_block}"
    puts "Last block: #{last_block}"
    puts "Block count: #{all_blocks.count}"

    all_blocks.each_cons(2) do |block1, block2|
      if block1 + 1 != block2
        raise "Gap detected between blocks #{block1} and #{block2}"
      end
    end

    puts "No gaps detected in block ranges."
  end
  
  def save_to_json(data, file_path)
    dir = Rails.root.join("base_fees")
    file_path = dir.join(file_path)
    FileUtils.mkdir_p(dir)
    
    File.open(file_path, 'w') do |file|
      file.write(JSON.pretty_generate(data))
    end
  end

  def last_saved_block
    dir = Rails.root.join("base_fees")
    files = Dir.glob(dir.join("base_fees_*.json"))
    return nil if files.empty?

    last_file = files.max_by { |f| File.mtime(f) }
    match = last_file.match(/base_fees_(\d+)_to_(\d+)\.json/)
    match ? match[2].to_i : nil
  end

  def run
    initial_block = last_saved_block || start_block
    puts "Starting fetch from block #{initial_block}"
    fetch_base_fees(initial_block)
    puts "Base fees fetched and saved in batches."
  end

  private

  def retry_with_backoff(max_retries = MAX_RETRIES, delay = RETRY_DELAY)
    retries = 0
    begin
      yield
    rescue Net::ReadTimeout, Errno::ECONNRESET => e
      retries += 1
      if retries <= max_retries
        sleep delay ** retries
        retry
      else
        raise "Failed after #{max_retries} retries: #{e.message}"
      end
    end
  end
end