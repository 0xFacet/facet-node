import {
  type Hex,
  type PrivateKeyAccount,
  type PublicClient,
  type WalletClient,
  toHex,
  parseAbi,
  encodeAbiParameters,
  parseAbiParameters,
  encodeFunctionData,
  toBlobs,
  createWalletClient,
  http
} from 'viem';
import { logger } from '../utils/logger.js';

export interface DABuilderSubmitResult {
  id: string;  // Request ID from DA Builder
}

export interface DABuilderReceiptResult {
  txHash: Hex;
  blockNumber: bigint;
  blockHash: Hex;
}

export class DABuilderClient {
  private walletClient: WalletClient;
  private kzg: any;

  constructor(
    private daBuilderUrl: string,
    private chainId: number,
    private account: PrivateKeyAccount,
    private publicClient: PublicClient
  ) {
    // Create wallet client for DA Builder
    this.walletClient = createWalletClient({
      account: this.account,
      chain: { id: this.chainId, name: 'Custom', nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: [daBuilderUrl] } } },
      transport: http(daBuilderUrl)
    });
  }

  async initKzg() {
    try {
      const cKzg = await import('c-kzg');
      cKzg.default.loadTrustedSetup(0);
      this.kzg = cKzg.default;
    } catch (error: any) {
      logger.error({ error: error.message }, 'Failed to initialize KZG for DA Builder');
      throw error;
    }
  }

  /**
   * Submit blob data to DA Builder
   */
  async submit(blobData: Hex, targetBlock?: bigint): Promise<DABuilderSubmitResult> {
    try {
      // Initialize KZG if not ready
      if (!this.kzg) {
        await this.initKzg();
      }

      // Prepare the EIP-712 signed call
      const onCallData = await this.prepareEIP712Call(blobData);

      // Convert data to blobs
      const blobs = toBlobs({ data: blobData });

      // Get current nonce and add random offset to avoid duplicates
      // DA Builder doesn't actually use this nonce on-chain, but needs unique transactions
      const currentNonce = await this.publicClient.getTransactionCount({
        address: this.account.address,
        blockTag: 'latest'
      });
      const nonce = currentNonce + (Math.floor(Math.random() * 1000) + 100);

      // Get gas prices
      const fees = await this.publicClient.estimateFeesPerGas();
      const blobBaseFee = await this.publicClient.getBlobBaseFee();

      // Use provided target block or compute it
      const targetBlockNumber = targetBlock ?? (await this.publicClient.getBlockNumber()) + 1n;

      // Sign the transaction
      const signedTx = await this.account.signTransaction({
        to: this.account.address, // EOA with 7702 code
        data: onCallData,
        blobs,
        kzg: this.kzg,
        nonce,
        gas: 500000n,
        maxPriorityFeePerGas: fees.maxPriorityFeePerGas! * 2n,
        maxFeePerGas: fees.maxFeePerGas! * 2n,
        maxFeePerBlobGas: blobBaseFee * 2n > 5000000000n ? blobBaseFee * 2n : 5000000000n, // Min 5 gwei
        type: 'eip4844',
        chainId: this.chainId
      });

      // Submit via eth_sendBundle
      const response = await fetch(this.daBuilderUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          jsonrpc: '2.0',
          id: 1,
          method: 'eth_sendBundle',
          params: [{
            txs: [signedTx],  // Array with single serialized transaction
            blockNumber: `0x${targetBlockNumber.toString(16)}`  // Block number as hex string
          }]
        })
      });

      const result: any = await response.json();

      if (result.error) {
        throw new Error(result.error.message || 'DA Builder returned error');
      }

      const requestId = result.result;
      logger.info({ requestId, targetBlock: targetBlockNumber }, 'Submitted bundle to DA Builder');

      return { id: requestId };
    } catch (error: any) {
      logger.error({ error: error.message }, 'Failed to submit to DA Builder');
      throw error;
    }
  }

  /**
   * Poll DA Builder for transaction receipt
   */
  async poll(requestId: string): Promise<DABuilderReceiptResult | null> {
    try {
      const response = await fetch(this.daBuilderUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          jsonrpc: '2.0',
          id: 1,
          method: 'eth_getTransactionReceipt',
          params: [requestId]
        })
      });

      const result: any = await response.json();

      if (result.result) {
        return {
          txHash: result.result.transactionHash,
          blockNumber: BigInt(result.result.blockNumber),
          blockHash: result.result.blockHash
        };
      }

      return null; // Still pending
    } catch (error: any) {
      logger.debug({ error: error.message }, 'Error polling DA Builder');
      return null;
    }
  }

  /**
   * Prepare EIP-712 signed call for TrustlessProposer
   */
  private async prepareEIP712Call(blobData: Hex): Promise<Hex> {
    // Get nested nonce from TrustlessProposer contract
    const proposerAbi = parseAbi([
      'function nestedNonce() view returns (uint256)'
    ]);

    const nonce = await this.publicClient.readContract({
      address: this.account.address, // EOA with 7702 code
      abi: proposerAbi,
      functionName: 'nestedNonce'
    });

    // Set deadline to 5 minutes from now
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 300);

    // Create EIP-712 domain
    const domain = {
      name: 'TrustlessProposer',
      version: '1',
      chainId: BigInt(this.chainId),
      verifyingContract: this.account.address // EOA with 7702 code
    };

    // EIP-712 types
    const types = {
      Call: [
        { name: 'deadline', type: 'uint256' },
        { name: 'nonce', type: 'uint256' },
        { name: 'target', type: 'address' },
        { name: 'value', type: 'uint256' },
        { name: 'calldata', type: 'bytes' },
        { name: 'gasLimit', type: 'uint256' }
      ]
    } as const;

    // Message to sign
    const message = {
      deadline,
      nonce,
      target: '0x0000000000000000000000000000000000000000' as Hex, // Dummy target for blob data
      value: 0n,
      calldata: blobData,
      gasLimit: 500000n
    };

    // Sign the message
    const signature = await this.account.signTypedData({
      domain,
      types,
      primaryType: 'Call',
      message
    });

    // Encode the onCall parameters
    const encodedCall = encodeAbiParameters(
      parseAbiParameters('bytes, uint256, uint256, bytes, uint256'),
      [signature, deadline, nonce, blobData, 500000n]
    );

    // Encode the onCall function call
    const onCallData = encodeFunctionData({
      abi: parseAbi(['function onCall(address target, bytes calldata data, uint256 value) returns (bool)']),
      functionName: 'onCall',
      args: ['0x0000000000000000000000000000000000000000' as Hex, encodedCall, 0n]
    });

    return onCallData;
  }
}