#!/usr/bin/env tsx

import { 
  createWalletClient, 
  createPublicClient,
  http, 
  type Hex,
  parseEther,
  formatEther,
  type TransactionSerializableEIP1559,
  parseGwei
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { defineChain } from 'viem';

// Configuration
const SEQUENCER_RPC = 'http://localhost:8547';
const L2_RPC = 'http://localhost:9545'; // Your local geth/Facet node

// Use the Anvil/Hardhat test accounts (they have ETH in local test networks)
const TEST_ACCOUNTS = [
  process.env.PRIVATE_KEY!, // Account 0
];

async function testE2E() {
  console.log('🚀 Testing Facet E2E Flow\n');
  
  // Create accounts
  const sender = privateKeyToAccount(TEST_ACCOUNTS[0] as Hex);
  const receiver = sender
  
  console.log('📝 Test accounts:');
  console.log('   Sender:', sender.address);
  console.log('   Receiver:', receiver.address);
  
  // Define Facet chain
  const facetChain = defineChain({
    id: 0xface7b,
    name: 'Facet Local',
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: {
      default: { http: [L2_RPC] }
    }
  });
  
  // Create L2 client to check balances
  const l2Client = createPublicClient({
    chain: facetChain,
    transport: http(L2_RPC)
  });
  
  // Check initial balances on L2
  console.log('\n💰 Checking L2 balances...');
  const senderBalance = await l2Client.getBalance({ address: sender.address });
  const receiverBalance = await l2Client.getBalance({ address: receiver.address });
  
  console.log('   Sender balance:', formatEther(senderBalance), 'ETH');
  console.log('   Receiver balance:', formatEther(receiverBalance), 'ETH');
  
  if (senderBalance === 0n) {
    console.log('\n⚠️  Sender has no ETH on L2!');
    console.log('   In local dev, accounts usually have pre-funded ETH.');
    console.log('   You may need to fund the account or use a different test account.');
  }
  
  // Get current nonce from L2
  const nonce = await l2Client.getTransactionCount({ 
    address: sender.address,
    blockTag: 'latest'
  });
  console.log('   Sender nonce on L2:', nonce);
  
  // Create wallet client for sequencer
  const sequencerWallet = createWalletClient({
    account: sender,
    chain: facetChain,
    transport: http(SEQUENCER_RPC)
  });
  
  // Create a real value transfer transaction
  const tx: TransactionSerializableEIP1559 = {
    type: 'eip1559',
    chainId: 0xface7b,
    nonce: Number(nonce),
    to: receiver.address,
    value: 0n, // Send 0.1 ETH
    data: '0x7711',
    gas: 75000n,
    maxFeePerGas: parseGwei('20'), // 20 gwei
    maxPriorityFeePerGas: parseGwei('0.000001'), // 2 gwei
  };
  
  try {
    console.log('\n📤 Sending transaction to sequencer...');
    console.log('   From:', sender.address);
    console.log('   To:', receiver.address);
    console.log('   Value:', formatEther(tx.value!), 'ETH');
    console.log('   Nonce:', tx.nonce);
    console.log('   Gas:', tx.gas?.toString());
    
    // Send transaction to sequencer
    const hash = await sequencerWallet.sendRawTransaction({
      serializedTransaction: await sequencerWallet.signTransaction(tx)
    });
    
    console.log('\n✅ Transaction accepted by sequencer!');
    console.log('   Hash:', hash);
    
    // Check transaction status in sequencer
    console.log('\n🔍 Checking sequencer status...');
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
    console.log('   Status:', JSON.stringify(statusResult.result, null, 2));
    
    // Wait for batch creation (3 seconds)
    console.log('\n⏳ Waiting for batch creation (3 seconds)...');
    await new Promise(r => setTimeout(r, 3500));
    
    // Check status again
    const status2Response = await fetch(SEQUENCER_RPC, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: '2.0',
        method: 'sequencer_getTxStatus',
        params: [hash],
        id: 2
      })
    });
    
    const status2Result = await status2Response.json();
    console.log('   Updated status:', JSON.stringify(status2Result.result, null, 2));
    
    // Monitor L2 for inclusion
    console.log('\n👀 Monitoring L2 for transaction inclusion...');
    console.log('   (This may take 30-60 seconds after L1 confirmation)');
    
    let included = false;
    let attempts = 0;
    const maxAttempts = 60; // Check for up to 1 minute
    
    // Heuristic: Check if OTHER transactions from the same batch made it
    // This tells us if the derivation node processed the batch
    let batchProcessed = false;
    
    while (!included && attempts < maxAttempts) {
      try {
        // First check if transaction exists in the node (even if failed)
        const tx = await l2Client.getTransaction({ hash }).catch(() => null);
        
        if (tx) {
          console.log('\n📦 Transaction found in L2 mempool/chain!');
          console.log('   Transaction was derived from L1 batch');
          
          // Now check for receipt (execution result)
          const receipt = await l2Client.getTransactionReceipt({ hash }).catch(() => null);
          
          if (receipt) {
            console.log('\n🎯 Transaction executed on L2!');
            console.log('   Block:', receipt.blockNumber);
            console.log('   Gas Used:', receipt.gasUsed);
            
            if (receipt.status === 'success') {
              console.log('   Status: ✅ Success');
              
              // Check final balances
              const finalSenderBalance = await l2Client.getBalance({ address: sender.address });
              const finalReceiverBalance = await l2Client.getBalance({ address: receiver.address });
              
              console.log('\n💰 Final L2 balances:');
              console.log('   Sender:', formatEther(finalSenderBalance), 'ETH');
              console.log('   Receiver:', formatEther(finalReceiverBalance), 'ETH');
              console.log('   Receiver gained:', formatEther(finalReceiverBalance - receiverBalance), 'ETH');
            } else {
              console.log('   Status: ❌ Failed (reverted)');
              console.log('\n⚠️  Transaction was included but failed execution');
              console.log('   Possible reasons:');
              console.log('   - Insufficient balance for transfer');
              console.log('   - Contract revert');
              console.log('   - Out of gas');
              
              // Still check balances to see the state
              const finalSenderBalance = await l2Client.getBalance({ address: sender.address });
              console.log('\n💰 Current L2 balance:');
              console.log('   Sender:', formatEther(finalSenderBalance), 'ETH');
              console.log('   (Transaction failed, no value transferred)');
            }
            
            included = true;
          } else {
            // Transaction exists but no receipt yet - might still be pending
            console.log('   Waiting for execution...');
          }
        }
      } catch (e: any) {
        // Check if this is a specific error about transaction not found
        if (e.message?.includes('not found')) {
          // Transaction genuinely not in L2 yet
        } else {
          // Some other error
          console.log('   Error checking transaction:', e.message);
        }
      }
      
      if (!included) {
        process.stdout.write('.');
        await new Promise(r => setTimeout(r, 1000));
        attempts++;
      }
    }
    
    if (!included) {
      console.log('\n⚠️  Transaction not found in L2 after 1 minute');
      console.log('\n   Debugging steps:');
      console.log('   1. Check if batch was posted to L1:');
      console.log(`      Check sequencer status for tx ${hash}`);
      console.log('   2. Check derivation node logs for:');
      console.log('      - "Found Facet batch" messages');
      console.log('      - "Processing transaction" messages');
      console.log('      - Any error messages');
      console.log('   3. Check L2 node (geth) logs for:');
      console.log('      - Transaction processing errors');
      console.log('      - State changes');
    }
    
  } catch (error: any) {
    console.error('\n❌ Error:', error.message);
    if (error.details) {
      console.error('   Details:', error.details);
    }
  }
}

// Run the test
testE2E().catch(console.error);