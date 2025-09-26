import { 
  createWalletClient, 
  http, 
  createPublicClient,
  parseGwei, 
  toBlobs,
  toHex,
  keccak256,
  numberToHex,
  concatHex,
  size,
  encodeFunctionData,
  parseAbi,
  encodeAbiParameters,
  parseAbiParameters
} from 'viem';
import { sepolia, hoodi, holesky } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';
import { toRlp } from 'viem/utils';
import cKzg from 'c-kzg';
import { mainnetTrustedSetupPath } from 'viem/node';
import dotenv from 'dotenv';
// no fs/crypto needed
import { formatGwei } from 'viem';

dotenv.config({ path: '.env.node' });

// Configuration from environment
const CHAIN = process.env.CHAIN;
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const RPC_URL = process.env.RPC_URL;
const DA_BUILDER_URL = process.env.DA_BUILDER_URL; // optional: submit via DA Builder if set
const L2_CHAIN_ID = parseInt(process.env.L2_CHAIN_ID, 16); // Default Facet L2 chain ID
const FACET_MAGIC_PREFIX = process.env.FACET_MAGIC_PREFIX || '0x0000000000012345';
const PROPOSER_ADDRESS = process.env.PROPOSER_ADDRESS; // Required for DA Builder mode

console.log('Environment loaded:', {
  CHAIN,
  RPC_URL,
  L2_CHAIN_ID: `0x${L2_CHAIN_ID.toString(16)}`,
  HAS_PRIVATE_KEY: !!PRIVATE_KEY
});

// Chain selection
const chain = CHAIN === 'hoodi' ? hoodi : CHAIN === 'holesky' ? holesky : sepolia;

// Helper to encode minimal-length big-endian integers for RLP
// const toMinimalHex = (n) => {
//   if (n === 0 || n === 0n) return '0x';
//   const hex = typeof n === 'bigint' ? toHex(n) : numberToHex(n);
//   // Remove leading zeros but keep at least one byte
//   return hex === '0x00' ? '0x' : hex.replace(/^0x0+/, '0x');
// };

function buildFacetBatchData(version, chainId, role, targetL1Block, transactions, extraData = '0x') {
  // FacetBatchData = [version, chainId, role, targetL1Block, transactions[], extraData]
  return [
    toHex(version),     // uint8 version
    toHex(chainId),           // uint256 chainId (minimal encoding)
    toHex(role),        // uint8 role (0=FORCED, 1=PRIORITY) per our usage
    toHex(targetL1Block),     // uint256 targetL1Block (minimal encoding)
    transactions,                    // RLP list of byte strings
    extraData                        // bytes extraData
  ];
}

function encodeFacetBatch(batchData, signature = null) {
  // FacetBatch = [FacetBatchData, signature?]
  const outer = signature ? [batchData, signature] : [batchData];
  return toRlp(outer);
}

function createSampleTransactions() {
  // Create some sample EIP-2718 style transactions (as raw bytes)
  // These don't need to be valid transactions, just arbitrary byte payloads for testing
  const transactions = [
    '0x01' + toHex('sample transaction 1').slice(2),
    '0x02' + toHex('sample transaction 2').slice(2),
    '0x02' + toHex('sample transaction 3 with more data').slice(2)
  ];
  return transactions;
}

// EIP-712 helpers for DA Builder
function createEIP712Domain(chainId, verifyingContract) {
  return {
    name: 'TrustlessProposer',
    version: '1',
    chainId: BigInt(chainId),
    verifyingContract: verifyingContract
  };
}

function createEIP712Types() {
  return {
    Call: [
      { name: 'deadline', type: 'uint256' },
      { name: 'nonce', type: 'uint256' },
      { name: 'target', type: 'address' },
      { name: 'value', type: 'uint256' },
      { name: 'calldata', type: 'bytes' },
      { name: 'gasLimit', type: 'uint256' }
    ]
  };
}

async function prepareDABuilderCall(account, publicClient, proposerAddress, targetAddress, calldata, value, gasLimit) {
  // Get nonce from TrustlessProposer contract
  const proposerAbi = parseAbi([
    'function nestedNonce() view returns (uint256)'
  ]);
  
  const nonce = await publicClient.readContract({
    address: account.address, // EOA with 7702 code
    abi: proposerAbi,
    functionName: 'nestedNonce'
  });
  
  // Set deadline to 5 minutes from now
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 300);
  
  // Create EIP-712 message
  const domain = createEIP712Domain(chain.id, account.address);
  const types = createEIP712Types();
  const message = {
    deadline,
    nonce,
    target: targetAddress,
    value: value || 0n,
    calldata: calldata || '0x',
    gasLimit: gasLimit || 500000n
  };
  
  // Sign the message
  const signature = await account.signTypedData({
    domain,
    types,
    primaryType: 'Call',
    message
  });
  
  // Encode the onCall parameters
  const encodedCall = encodeAbiParameters(
    parseAbiParameters('bytes, uint256, uint256, bytes, uint256'),
    [signature, deadline, nonce, calldata || '0x', gasLimit || 500000n]
  );
  
  // Encode the onCall function call
  const onCallData = encodeFunctionData({
    abi: parseAbi(['function onCall(address target, bytes calldata data, uint256 value) returns (bool)']),
    functionName: 'onCall',
    args: [targetAddress, encodedCall, value || 0n]
  });
  
  return onCallData;
}

async function sendBlobTransaction() {
  try {
    if (!PRIVATE_KEY) {
      throw new Error('PRIVATE_KEY environment variable is required');
    }
    
    const account = privateKeyToAccount(PRIVATE_KEY);
  
  const walletClient = createWalletClient({
    account,
    chain,
    transport: http(RPC_URL || chain.rpcUrls.default.http[0])
  });
  
  const publicClient = createPublicClient({
    chain,
    transport: http(RPC_URL || chain.rpcUrls.default.http[0])
  });
  
  console.log(`\n📍 Using ${chain.name} network`);
  console.log(`   RPC: ${RPC_URL || chain.rpcUrls.default.http[0]}`);
  console.log(`   Account: ${account.address}`);
  
  // Get current block and gas fee estimates
  const currentBlock = await publicClient.getBlockNumber();
  const block = await publicClient.getBlock({ blockNumber: currentBlock });
  const targetL1Block = currentBlock + 1n;
  const feeEst = await publicClient.estimateFeesPerGas()
  const maxPriorityFeePerGas = feeEst.maxPriorityFeePerGas * 2n
  const maxFeePerGas = feeEst.maxFeePerGas * 2n
  // Prefer RPC-provided blob base fee (eth_blobBaseFee)
  let blobBase = await publicClient.getBlobBaseFee()
  const maxFeePerBlobGas = (blobBase * 2n) > parseGwei('5') ? (blobBase * 2n) : parseGwei('5');

  console.log(`\n⛽ Gas params:`);
  console.log(`   maxPriorityFeePerGas: ${formatGwei(maxPriorityFeePerGas)} gwei`);
  console.log(`   maxFeePerGas:        ${formatGwei(maxFeePerGas)} gwei`);
  console.log(`   blobBase:            ${formatGwei(blobBase)} gwei`);
  console.log(`   maxFeePerBlobGas:    ${formatGwei(maxFeePerBlobGas)} gwei`);
  
  console.log(`\n📦 Building Facet Batch...`);
  console.log(`   Version: 1`);
  console.log(`   L2 Chain ID: ${L2_CHAIN_ID} (0x${L2_CHAIN_ID.toString(16)})`);
  console.log(`   Role: FORCED (1)`);
  console.log(`   Target L1 Block: ${targetL1Block}`);
  
  // Build spec-compliant batch
  const transactions = createSampleTransactions();
  // Set targetL1Block to 0 to avoid strict anchoring for this e2e
  const batchData = buildFacetBatchData(
    1,                    // version
    L2_CHAIN_ID,         // chainId
    1,                   // role (FORCED)
    0n,                  // targetL1Block (ignored by parser in this e2e)
    transactions,        // transactions
    '0x'                 // extraData
  );
  
  // Compute content hash for verification
  const contentHash = keccak256(toRlp(batchData));
  console.log(`   Content Hash: ${contentHash}`);
  
  // Create FacetBatch (no signature for FORCED)
  const batchRlp = encodeFacetBatch(batchData);
  
  // Build wire format: magic || uint32_be(length) || rlp(batch)
  const batchLength = size(batchRlp);
  const lengthBytes = toHex(batchLength, { size: 4 });
  const wirePayload = concatHex([FACET_MAGIC_PREFIX, lengthBytes, batchRlp]);
  
  console.log(`   Batch RLP Length: ${batchLength} bytes`);
  console.log(`   Wire Payload Length: ${size(wirePayload)} bytes`);
  
  // For DA Builder: send only our data (they handle aggregation)
  // For direct L1: add filler to simulate aggregation
  const useDABuilder = !!DA_BUILDER_URL;
  
  let dataHex, embedOffset;
  if (useDABuilder) {
    // DA Builder will aggregate with other users' data
    dataHex = wirePayload;
    embedOffset = 0;  // Unknown until DA Builder aggregates
  } else {
    // Simulate aggregation for local testing
    const fillerBeforeSize = Math.floor(Math.random() * 10000) + 1000;
    const fillerAfterSize = Math.floor(Math.random() * 10000) + 1000;
    
    const fillerBefore = toHex(new Uint8Array(fillerBeforeSize).map(() => Math.floor(Math.random() * 256)));
    const fillerAfter = toHex(new Uint8Array(fillerAfterSize).map(() => Math.floor(Math.random() * 256)));
    
    dataHex = concatHex([fillerBefore, wirePayload, fillerAfter]);
    embedOffset = fillerBeforeSize;
  }
  
  console.log(`\n🔄 Creating blob...`);
  console.log(`   Total data size: ${size(dataHex)} bytes`);
  if (useDABuilder) {
    console.log(`   Wire payload: ${size(wirePayload)} bytes`);
    console.log(`   (DA Builder will handle aggregation)`);
  } else {
    console.log(`   Embed offset: ${embedOffset} bytes`);
    console.log(`   Wire payload: ${size(wirePayload)} bytes`);
    console.log(`   (Added filler for testing)`);
  }
  
  // Create blobs from the data
  const blobs = toBlobs({ data: dataHex });
  console.log(`   Created ${blobs.length} blob(s)`);
  
  // Set up KZG - explicitly load the trusted setup
  console.log(`\n🔐 Loading KZG trusted setup`);
  const trustedSetupPath = process.env.KZG_TRUSTED_SETUP 
    || process.env.KZG_TRUSTED_SETUP_PATH 
    || cKzg.DEFAULT_TRUSTED_SETUP_PATH 
    || mainnetTrustedSetupPath;
  cKzg.loadTrustedSetup(0, trustedSetupPath);
  console.log(`   ✓ Trusted setup loaded from: ${trustedSetupPath}`);
  const kzg = cKzg;
  
  if (DA_BUILDER_URL) {
    console.log('\n🧱 DA Builder mode enabled');
    console.log(`   Endpoint: ${DA_BUILDER_URL}`);
    
    if (!PROPOSER_ADDRESS) {
      throw new Error('PROPOSER_ADDRESS required for DA Builder mode');
    }
    
    // Check if EOA has EIP-7702 code
    const eoaCode = await publicClient.getCode({ address: account.address });
    if (!eoaCode || eoaCode === '0x') {
      throw new Error(`EOA ${account.address} has no code. Run EIP-7702 setup first.`);
    }
    console.log(`   EOA has code (EIP-7702 set): ${eoaCode.slice(0, 10)}...`);
    
    // For DA Builder, we need to wrap the blob submission in an onCall
    // The target will be a contract that accepts blob data, or we can use a dummy target
    const targetAddress = '0x0000000000000000000000000000000000000000';
    const calldata = dataHex; // The blob data we want to submit
    const value = 0n;
    const gasLimit = 500000n;
    
    console.log('   Preparing EIP-712 signed call...');
    const onCallData = await prepareDABuilderCall(
      account,
      publicClient,
      PROPOSER_ADDRESS,
      targetAddress,
      calldata,
      value,
      gasLimit
    );
    
    // Create DA Builder client
    const builderWallet = createWalletClient({ account, chain, transport: http(DA_BUILDER_URL) });
    const builderPublic = createPublicClient({ transport: http(DA_BUILDER_URL) });
    
    // Note: The nestedNonce from TrustlessProposer is used in the EIP-712 signature (in prepareDABuilderCall)
    // For the L1 transaction nonce, we need a value higher than current nonce to avoid conflicts
    // DA Builder may not use this directly, but it needs to be valid
    const currentNonce = await publicClient.getTransactionCount({ address: account.address });
    const nonce = currentNonce + BigInt(Math.floor(Math.random() * 1000) + 100); // Use a nonce well above current
    
    // Option to use eth_sendBundle instead (set USE_SEND_BUNDLE=true in env)
    const useSendBundle = process.env.USE_SEND_BUNDLE === 'true';
    
    let requestId;
    if (useSendBundle) {
      console.log('   Using eth_sendBundle method...');
      
      // Get current block for target
      const currentBlock = await publicClient.getBlockNumber();
      const targetBlock = currentBlock + 1n;
      
      // Create and serialize the transaction
      const tx = await account.signTransaction({
        to: account.address,
        data: onCallData,
        blobs,
        kzg,
        nonce,
        gas: 500000n,
        maxPriorityFeePerGas,
        maxFeePerGas,
        maxFeePerBlobGas,
        chainId: chain.id,
        type: 'eip4844'
      });
      
      // Submit via eth_sendBundle
      // DA Builder's simplified version: accepts object with txs and blockNumber
      requestId = await builderPublic.request({
        "jsonrpc": "2.0",
        "id": 1,
        method: 'eth_sendBundle',
        params: [{
          txs: [tx],  // Array with single serialized transaction
          blockNumber: toHex(targetBlock)  // Block number as hex string (camelCase)
        }]
      });
      
      console.log(`   Submitted bundle for block ${targetBlock}`);
    } else {
      // Original method using sendTransaction
      console.log('   Submitting to DA Builder via sendTransaction...');
      requestId = await builderWallet.sendTransaction({
        to: account.address, // Send to EOA with 7702 code
        data: onCallData,
        blobs,
        kzg,
        nonce,  // Explicitly provide nonce
        gas: 500000n,  // Explicit gas limit
        maxPriorityFeePerGas,
        maxFeePerGas,
        maxFeePerBlobGas,
      });
    }
    
    console.log(`   Submitted to DA Builder. Request ID: ${requestId}`);
    console.log('\n⏳ Waiting for DA Builder receipt...');
    
    let receipt = null;
    const startTime = Date.now();
    const timeout = 900000; // 15 minutes
    
    while (!receipt) {
      try {
        receipt = await builderPublic.request({ 
          method: 'eth_getTransactionReceipt', 
          params: [requestId] 
        });
        if (receipt) break;
      } catch (e) {
        // Ignore errors, keep polling
      }
      
      if (Date.now() - startTime > timeout) {
        throw new Error('Timeout waiting for DA Builder receipt');
      }
      
      await new Promise((r) => setTimeout(r, 5000)); // Poll every 5 seconds
    }
    
    console.log(`   ✅ Included on-chain. Tx: ${receipt.transactionHash}`);
    console.log(`   Block: ${receipt.blockNumber}`);
    const result = {
      success: true,
      mode: 'da_builder',
      chain: chain.name,
      requestId,
      transactionHash: receipt.transactionHash,
      blockNumber: Number(receipt.blockNumber),
      embedOffset: embedOffset,
      wirePayloadLength: size(wirePayload),
      batchRlpLength: batchLength,
      contentHash: contentHash,
      l2ChainId: L2_CHAIN_ID,
    };
    console.log('\n--- JSON OUTPUT ---');
    console.log(JSON.stringify(result, null, 2));
    return result;
  } else {
    console.log('\n🚀 Sending blob transaction directly to L1...');
    const hash = await walletClient.sendTransaction({
      to: '0x0000000000000000000000000000000000000000',
      blobs,
      kzg,
      maxPriorityFeePerGas,
      maxFeePerGas,
      maxFeePerBlobGas,
    });
    console.log(`   Transaction sent: ${hash}`);
    console.log(`   View on Etherscan: https://${chain.name.toLowerCase()}.etherscan.io/tx/${hash}`);
    console.log('\n⏳ Waiting for confirmation...');
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`   ✅ Confirmed in block ${receipt.blockNumber}`);
    console.log(`   Blob hashes: ${receipt.blobVersionedHashes?.join(', ') || 'none'}`);
    const result = {
      success: true,
      mode: 'direct',
      chain: chain.name,
      transactionHash: hash,
      blockNumber: Number(receipt.blockNumber),
      blobVersionedHashes: receipt.blobVersionedHashes || [],
      embedOffset: embedOffset,
      wirePayloadLength: size(wirePayload),
      batchRlpLength: batchLength,
      contentHash: contentHash,
      l2ChainId: L2_CHAIN_ID,
    };
    console.log('\n--- JSON OUTPUT ---');
    console.log(JSON.stringify(result, null, 2));
    return result;
  }
  } catch (error) {
    console.error('❌ Error:', error.message);
    console.error('Stack trace:', error.stack);
    const errorResult = {
      success: false,
      error: error.message,
      stack: error.stack
    };
    console.log('\n--- JSON OUTPUT ---');
    console.log(JSON.stringify(errorResult, null, 2));
    process.exit(1);
  }
}

sendBlobTransaction();
