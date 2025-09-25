#!/usr/bin/env tsx

import {
  createWalletClient,
  createPublicClient,
  http,
  type Hex,
  parseEther,
  formatEther,
  toHex,
  toRlp,
  concatHex,
  pad,
  numberToHex
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { defineChain } from 'viem';
import { holesky, sepolia } from 'viem/chains';

// Configuration
const L1_RPC = process.env.L1_RPC_URL || 'https://ethereum-hoodi-rpc.publicnode.com';
const L1_CHAIN = process.env.L1_CHAIN || 'hoodi';
const L2_RPC = 'http://localhost:9545'; // Direct to Facet geth
const FACET_INBOX_ADDRESS = '0x00000000000000000000000000000000000face7' as Hex;
const FACET_TX_TYPE = 0x46; // Facet transaction type
const L2_CHAIN_ID = 0xface7b; // Facet chain ID

// Private key to use for minting (needs L1 ETH for gas!)
const MINTER_PRIVATE_KEY = process.env.PRIVATE_KEY!;

// Helper to create a Facet transaction payload
function createFacetDepositPayload(recipientAddress: Hex): Hex {
  // Create a simple deposit Facet transaction
  // Structure: [chain_id, to, value, max_gas_fee, gas_limit, data]
  const facetTx = [
    toHex(L2_CHAIN_ID),                    // chain_id (Facet L2)
    recipientAddress,                       // to (recipient on L2)
    '0x' as Hex,                              // value (0 for deposit)
    toHex(21000),                     // max_gas_fee (1 gwei)
    '0x' as Hex,                            // data (empty),
    '0x' as Hex                            // data (empty)
  ];

  // RLP encode the Facet transaction
  const rlpEncoded = toRlp(facetTx);

  // Prepend the Facet transaction type (0x46)
  const typePrefix = toHex(FACET_TX_TYPE, { size: 1 });
  const facetPayload = concatHex([typePrefix, rlpEncoded]);

  return facetPayload;
}

async function mintEth() {
  console.log('💰 Minting ETH on Facet L2\n');

  // Create account from private key
  const minter = privateKeyToAccount(MINTER_PRIVATE_KEY as Hex);
  console.log('🔑 Minter account:', minter.address);

  // Determine L1 chain
  let l1Chain;
  if (L1_CHAIN === 'holesky') {
    l1Chain = holesky;
  } else if (L1_CHAIN === 'sepolia') {
    l1Chain = sepolia;
  } else {
    // Assume Hoodi
    l1Chain = defineChain({
      id: 560048,
      name: 'Hoodi',
      nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
      rpcUrls: {
        default: { http: [L1_RPC] }
      }
    });
  }

  // Create L1 wallet client
  const l1Wallet = createWalletClient({
    account: minter,
    chain: l1Chain,
    transport: http(L1_RPC)
  });

  // Create L1 public client for balance checks
  const l1Client = createPublicClient({
    chain: l1Chain,
    transport: http(L1_RPC)
  });

  // Create L2 public client to check balances
  const l2Client = createPublicClient({
    chain: defineChain({
      id: L2_CHAIN_ID,
      name: 'Facet',
      nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
      rpcUrls: {
        default: { http: [L2_RPC] }
      }
    }),
    transport: http(L2_RPC)
  });

  try {
    // Check L1 balance
    const l1Balance = await l1Client.getBalance({
      address: minter.address
    });
    console.log('💵 L1 balance:', formatEther(l1Balance), 'ETH');

    if (l1Balance === 0n) {
      console.error('❌ No L1 ETH! You need L1 ETH to send the deposit transaction.');
      console.error('   Please fund this account on L1:', minter.address);
      process.exit(1);
    }

    // Check initial L2 balance
    const initialL2Balance = await l2Client.getBalance({
      address: minter.address
    }).catch(() => 0n);

    console.log('💵 Initial L2 balance:', formatEther(initialL2Balance), 'ETH');

    // Get L1 nonce
    const l1Nonce = await l1Client.getTransactionCount({
      address: minter.address,
      blockTag: 'latest'
    });

    console.log('📝 L1 nonce:', l1Nonce);

    // Create the Facet deposit payload
    const facetPayload = createFacetDepositPayload(minter.address);
    console.log('\n🔧 Created Facet deposit payload:', facetPayload);

    // Create L1 transaction to send to Facet inbox
    const depositTx = {
      account: minter,
      chain: l1Chain,
      to: FACET_INBOX_ADDRESS,
      value: 0n, // No value needed
      data: facetPayload, // Facet transaction as payload
      gas: 100000n, // More gas for processing the payload
      maxFeePerGas: parseEther('0.00000003'), // 30 gwei
      maxPriorityFeePerGas: parseEther('0.000000003'), // 3 gwei
      nonce: l1Nonce,
    };

    console.log('\n📤 Sending deposit transaction on L1...');
    console.log('   Chain:', L1_CHAIN);
    console.log('   To (inbox):', FACET_INBOX_ADDRESS);
    console.log('   Recipient on L2:', minter.address);

    // Send L1 transaction
    const hash = await l1Wallet.sendTransaction(depositTx);
    console.log('\n✅ L1 transaction sent!');
    console.log('   Hash:', hash);

    // Wait for L1 confirmation
    console.log('\n⏳ Waiting for L1 confirmation...');
    const receipt = await l1Client.waitForTransactionReceipt({
      hash,
      confirmations: 1
    });

    if (receipt.status === 'success') {
      console.log('✅ L1 transaction confirmed in block:', receipt.blockNumber);
    } else {
      console.error('❌ L1 transaction failed!');
      process.exit(1);
    }

    // Now wait for L2 balance update
    console.log('\n⏳ Waiting for L2 mint (this may take 30-60 seconds)...');
    console.log('   The Facet importer needs to process the L1 block and derive the L2 state');

    let attempts = 0;
    const maxAttempts = 120; // 2 minutes
    let finalL2Balance = initialL2Balance;

    while (attempts < maxAttempts) {
      await new Promise(r => setTimeout(r, 1000));

      // Check new L2 balance
      finalL2Balance = await l2Client.getBalance({
        address: minter.address
      }).catch(() => initialL2Balance);

      if (finalL2Balance > initialL2Balance) {
        console.log('\n🎉 ETH minted successfully on L2!');
        console.log('   Initial L2 balance:', formatEther(initialL2Balance), 'ETH');
        console.log('   Final L2 balance:', formatEther(finalL2Balance), 'ETH');
        console.log('   Minted:', formatEther(finalL2Balance - initialL2Balance), 'ETH');
        break;
      }

      process.stdout.write('.');
      attempts++;
    }

    if (finalL2Balance === initialL2Balance) {
      console.log('\n⚠️  L2 balance unchanged after 2 minutes');
      console.log('   The deposit may still be processing');
      console.log('   Check:');
      console.log('   1. Facet importer logs for processing of block', receipt.blockNumber);
      console.log('   2. Geth logs for L2 block derivation');
    }

  } catch (error: any) {
    console.error('\n❌ Error:', error.message);
    if (error.details) {
      console.error('   Details:', error.details);
    }
    process.exit(1);
  }
}

// Run the mint script
mintEth().catch(console.error);