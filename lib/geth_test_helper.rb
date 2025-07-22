module GethTestHelper
  extend self
  
  def setup_rspec_geth
    geth_dir = ENV.fetch('LOCAL_GETH_DIR')
    http_port = ENV.fetch('NON_AUTH_GETH_RPC_URL').split(':').last
    authrpc_port = ENV.fetch('GETH_RPC_URL').split(':').last
    discovery_port = ENV.fetch('GETH_DISCOVERY_PORT')
    
    MemeryExtensions.clear_all_caches!
    SolidityCompiler.reset_checksum
    SolidityCompiler.compile_all_legacy_files
    
    teardown_rspec_geth
    
    @temp_datadir = Dir.mktmpdir('geth_datadir_', '/tmp')
    geth_dir_hash = Digest::SHA256.hexdigest(ENV.fetch('LOCAL_GETH_DIR')).first(5)
    log_file_location = Rails.root.join('tmp', "geth_#{geth_dir_hash}.log").to_s
    if File.exist?(log_file_location)
      File.delete(log_file_location)
    end
    
    genesis_filename = ChainIdManager.on_mainnet? ? "facet-mainnet.json" : "facet-sepolia.json"
    
    system("cd #{geth_dir} && ./facet-chain/unzip_genesis.sh && make geth && ./build/bin/geth init --cache.preimages --state.scheme=hash --datadir #{@temp_datadir} facet-chain/#{genesis_filename}")
    
    geth_command = [
      "#{geth_dir}/build/bin/geth",
      "--datadir", @temp_datadir,
      "--http",
      "--http.api", "eth,net,web3,debug",
      "--http.vhosts", "*",
      "--authrpc.jwtsecret", "/tmp/jwtsecret",
      "--http.port", http_port,
      "--authrpc.port", authrpc_port,
      "--discovery.port", discovery_port,
      "--port", discovery_port,
      "--authrpc.addr", "localhost",
      "--authrpc.vhosts", "*",
      "--nodiscover",
      "--maxpeers", "0",
      "--log.file", log_file_location,
      "--syncmode", "full",
      "--gcmode", "archive",
      "--history.state", "0",
      "--history.transactions", "0",
      "--nocompaction",
      "--rollup.enabletxpooladmission=false",
      "--rollup.disabletxpoolgossip",
      "--cache", "12000",
      "--cache.preimages",
    ]
    
    FileUtils.rm(log_file_location) if File.exist?(log_file_location)
    
    pid = Process.spawn(*geth_command, [:out, :err] => [log_file_location, 'w'])

    Process.detach(pid)
    
    geth_dir_hash = Digest::SHA256.hexdigest(geth_dir)
    
    File.write(geth_pid_file, pid)
    
    begin
      Timeout.timeout(30) do
        loop do
          break if File.exist?(log_file_location) && File.read(log_file_location).include?("NAT mapped port")
          sleep 0.5
        end
      end
    rescue Timeout::Error
      raise "Geth setup did not complete within the expected time"
    end
  end
  
  def teardown_rspec_geth
    if File.exist?(geth_pid_file)
      pid = File.read(geth_pid_file).to_i
      begin
        # Kill the specific geth process
        Process.kill('TERM', pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD => e
        puts e.message
      ensure
        File.delete(geth_pid_file)
      end
    end
    
    # Clean up the temporary data directory
    Dir.glob('/tmp/geth_datadir_*').each do |dir|
      FileUtils.rm_rf(dir)
    end
  end
  
  def geth_pid_file
    geth_dir_hash = Digest::SHA256.hexdigest(ENV.fetch('LOCAL_GETH_DIR')).first(5)
    "tmp/geth_pid_#{geth_dir_hash}.pid"
  end
end
