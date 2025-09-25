#!/usr/bin/env tsx

import { 
  createWalletClient, 
  createPublicClient,
  http, 
  type Hex,
  parseEther,
  type TransactionSerializableEIP1559
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { defineChain } from 'viem';

// Test configuration
const SEQUENCER_RPC = 'http://localhost:8547';
const TEST_PRIVATE_KEY = '';

async function testSequencer() {
  console.log('🚀 Testing Facet Sequencer\n');
  
  // Create test account
  const account = privateKeyToAccount(TEST_PRIVATE_KEY as Hex);
  console.log('📝 Test account:', account.address);
  
  // Define custom chain for sequencer
  const facetChain = defineChain({
    id: 0xface7b, // Facet chain ID (as number)
    name: 'Facet (via Sequencer)',
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: {
      default: { http: [SEQUENCER_RPC] }
    }
  });
  
  // Create wallet client
  const wallet = createWalletClient({
    account,
    chain: facetChain,
    transport: http(SEQUENCER_RPC)
  });
  
  // For L2 transactions, we need to track nonce properly
  // In a real scenario, this would come from the L2 node
  // For testing, we'll use an incrementing counter stored in a file or environment
  let nonce = 0;
  try {
    // Try to read last nonce from a file
    const fs = await import('fs');
    const noncePath = '.test-nonce';
    if (fs.existsSync(noncePath)) {
      nonce = parseInt(fs.readFileSync(noncePath, 'utf8')) + 1;
    }
    // Save the new nonce for next run
    fs.writeFileSync(noncePath, nonce.toString());
  } catch (e) {
    // If file operations fail, use timestamp-based for uniqueness
    console.log('Using timestamp-based nonce for testing');
    nonce = Math.floor(Date.now() / 1000) % 100000;
  }
  
  // Create a test transaction
  const tx: TransactionSerializableEIP1559 = {
    type: 'eip1559',
    chainId: 0xface7b,
    nonce,
    to: '0x70997970C51812dc3A010C7d01b50e0d17dc79C8' as Hex, // Random address
    value: parseEther('0.001'),
    gas: 21000n,
    maxFeePerGas: parseEther('0.00000002'), // 20 gwei
    maxPriorityFeePerGas: parseEther('0.000000002'), // 2 gwei
  };
  
  try {
    console.log('📤 Sending transaction to sequencer...');
    console.log('   From:', account.address);
    console.log('   To:', tx.to);
    console.log('   Nonce:', nonce);
    console.log('   Value:', tx.value?.toString(), 'wei');
    console.log('   Gas:', tx.gas?.toString());
    console.log('   Max Fee:', tx.maxFeePerGas?.toString(), 'wei\n');
    
    // Send transaction
    const hash = await wallet.sendRawTransaction({
      serializedTransaction: await wallet.signTransaction(tx)
    });
    
    console.log('✅ Transaction accepted!');
    console.log('   Hash:', hash, '\n');
    
    // Check transaction status
    console.log('🔍 Checking transaction status...');
    const statusResponse = await fetch(SEQUENCER_RPC, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: '2.0',
        method: 'sequencer_getTxStatus',
        params: [hash],
        id: 1
      })
    });
    
    const statusResult = await statusResponse.json();
    console.log('   Status:', JSON.stringify(statusResult.result, null, 2), '\n');
    
    // Get sequencer stats
    console.log('📊 Sequencer statistics:');
    const statsResponse = await fetch(SEQUENCER_RPC, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: '2.0',
        method: 'sequencer_getStats',
        params: [],
        id: 2
      })
    });
    
    const statsResult = await statsResponse.json();
    console.log(JSON.stringify(statsResult.result, null, 2));
    
  } catch (error: any) {
    console.error('❌ Error:', error.message);
    if (error.details) {
      console.error('   Details:', error.details);
    }
  }
}

// Run the test
testSequencer().catch(console.error);