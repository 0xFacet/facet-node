namespace :l1_block do
  desc "Generate L1Block compiled output and save to file"
  task :generate_bytecode => :environment do
    filename = Rails.root.join('contracts/src/upgrades/L1Block.sol')
    compiled = SolidityCompiler.compile(filename)
    
    # Save full compiled output to config directory
    output_path = Rails.root.join('config', FacetTransaction::Special::L1_BLOCK_BLUEBIRD_COMPILED_FILENAME)
    File.write(output_path, JSON.pretty_generate(compiled))
    
    puts "L1Block compiled output saved to: #{output_path}"
    puts "Bytecode length: #{compiled['L1Block']['bytecode'].length} characters"
  end
end
