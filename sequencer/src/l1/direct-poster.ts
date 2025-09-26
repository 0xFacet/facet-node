import {
  createWalletClient,
  createPublicClient,
  http,
  toBlobs,
  type WalletClient,
  type PublicClient,
  type Hex,
  type PrivateKeyAccount,
  type Chain
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import type { DatabaseService, Batch } from '../db/schema.js';
import { logger } from '../utils/logger.js';
import type { Poster, PendingTransaction } from './poster-interface.js';

export class DirectPoster implements Poster {
  private wallet: WalletClient;
  private publicClient: PublicClient;
  private account: PrivateKeyAccount;
  private currentBlobTx: PendingTransaction | null = null;
  private lastNonce: number = 0;
  private kzg: any;
  private kzgReady: Promise<void>;

  constructor(
    private db: DatabaseService,
    private chain: Chain,
    privateKey: Hex,
    rpcUrl: string
  ) {
    this.account = privateKeyToAccount(privateKey);

    this.wallet = createWalletClient({
      account: this.account,
      chain: this.chain,
      transport: http(rpcUrl)
    });

    this.publicClient = createPublicClient({
      chain: this.chain,
      transport: http(rpcUrl)
    });

    // Initialize KZG
    this.kzgReady = this.initKzg();
  }

  private async initKzg() {
    try {
      const cKzg = await import('c-kzg');
      // c-kzg 4.x includes the trusted setup internally
      // Just pass the preset id (0 for mainnet)
      cKzg.default.loadTrustedSetup(0);
      this.kzg = cKzg.default;
      logger.info('KZG initialized successfully');
    } catch (error: any) {
      logger.warn({ error: error.message }, 'KZG initialization failed, blob transactions may not work');
      // Try without any parameters as a fallback
      try {
        const cKzg = await import('c-kzg');
        this.kzg = cKzg.default;
        logger.info('KZG initialized without explicit trusted setup loading');
      } catch (e) {
        logger.error('Failed to initialize KZG completely');
      }
    }
  }

  async postBatch(batchId: number): Promise<void> {
    // Wait for KZG to be ready
    await this.kzgReady;

    const database = this.db.getDatabase();

    // Get batch data
    const batch = database.prepare(
      'SELECT * FROM batches WHERE id = ? AND state = ?'
    ).get(batchId, 'sealed') as Batch | undefined;

    if (!batch) {
      logger.error({ batchId }, 'Batch not found or not sealed');
      return;
    }

    // Check if previous tx confirmed
    const currentNonce = await this.publicClient.getTransactionCount({
      address: this.account.address,
      blockTag: 'latest'
    });

    if (currentNonce > this.lastNonce) {
      // Previous confirmed, start fresh
      this.currentBlobTx = null;
      this.lastNonce = currentNonce;
    }

    // Prepare blob transaction
    const blobTx = this.currentBlobTx ?
      await this.createReplacementTx(batch) :
      await this.createNewTx(batch);

    try {
      // Convert wire format to blobs
      const wireFormatHex = ('0x' + batch.wire_format.toString('hex')) as Hex;
      const blobs = toBlobs({ data: wireFormatHex });

      // Check if KZG is available
      if (!this.kzg) {
        throw new Error('KZG not initialized - cannot send blob transaction');
      }

      // Submit transaction
      const txHash = await this.wallet.sendTransaction({
        account: this.account,
        chain: this.chain,
        blobs,
        kzg: this.kzg, // Pass the KZG instance
        to: '0x0000000000000000000000000000000000000000' as Hex, // Burn address for blobs
        nonce: this.currentBlobTx?.nonce || currentNonce,
        gas: 100000n,
        maxFeePerGas: blobTx.maxFeePerGas,
        maxPriorityFeePerGas: blobTx.maxPriorityFeePerGas,
        maxFeePerBlobGas: blobTx.maxFeePerBlobGas,
        type: 'eip4844'
      });

      // Track for monitoring - make sure we store the actual fees used
      this.currentBlobTx = {
        batchId,
        txHash,
        nonce: this.currentBlobTx?.nonce || currentNonce,
        gasPrice: blobTx.maxFeePerGas,  // Store the actual fee we just used
        blobGasPrice: blobTx.maxFeePerBlobGas,
        submittedAt: Date.now(),
        attempts: (this.currentBlobTx?.attempts || 0) + 1
      };

      // Store post attempt
      database.prepare(`
        INSERT INTO post_attempts (
          batch_id, l1_tx_hash, l1_nonce, gas_price,
          max_fee_per_gas, max_fee_per_blob_gas, submitted_at, status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, 'pending')
      `).run(
        batchId,
        Buffer.from(txHash.slice(2), 'hex'),
        this.currentBlobTx.nonce,
        blobTx.maxFeePerGas.toString(),
        blobTx.maxFeePerGas.toString(),
        blobTx.maxFeePerBlobGas.toString(),
        Date.now()
      );

      // Update batch state
      database.prepare(
        'UPDATE batches SET state = ? WHERE id = ?'
      ).run('submitted', batchId);

      logger.info({
        batchId,
        txHash,
        nonce: this.currentBlobTx.nonce,
        attempt: this.currentBlobTx.attempts
      }, 'Batch submitted to L1');

    } catch (error: any) {
      logger.error({ batchId, error: error.message }, 'Failed to submit batch');
      this.handleSubmissionError(error, batchId);
    }
  }

  async checkPendingTransaction(): Promise<void> {
    if (!this.currentBlobTx) return;

    try {
      const receipt = await this.publicClient.getTransactionReceipt({
        hash: this.currentBlobTx.txHash!
      });

      if (receipt) {
        logger.info({
          txHash: this.currentBlobTx.txHash,
          blockNumber: receipt.blockNumber
        }, 'Transaction confirmed');

        // Clear current tx
        this.currentBlobTx = null;
      }
    } catch (error) {
      // Transaction might still be pending
    }
  }

  getPendingTransaction(): PendingTransaction | null {
    return this.currentBlobTx;
  }

  private async createNewTx(batch: Batch) {
    const [baseFee, blobBaseFee] = await Promise.all([
      this.getBaseFee(),
      this.getBlobBaseFee()
    ]);

    const maxFee = baseFee * 2n;
    const priorityFee = baseFee / 10n; // 10% of base fee as priority

    return {
      maxFeePerGas: maxFee,
      maxPriorityFeePerGas: priorityFee < maxFee ? priorityFee : maxFee / 2n,
      maxFeePerBlobGas: blobBaseFee * 2n
    };
  }

  private async createReplacementTx(batch: Batch) {
    // Smart fee escalation with 12.5% minimum bump
    const minBump = 1125n; // 12.5% = 1.125 * 1000

    const [currentBaseFee, currentBlobBase] = await Promise.all([
      this.getBaseFee(),
      this.getBlobBaseFee()
    ]);

    // Calculate minimum bumped values (12.5% increase)
    const minMaxFee = (this.currentBlobTx!.gasPrice! * minBump) / 1000n;
    const minBlobFee = this.currentBlobTx!.blobGasPrice ?
      (this.currentBlobTx!.blobGasPrice * minBump) / 1000n :
      currentBlobBase * 2n;

    // Use higher of: bumped value or 2x current base
    const maxFee = minMaxFee > (currentBaseFee * 2n) ? minMaxFee : (currentBaseFee * 2n);
    const blobFee = minBlobFee > (currentBlobBase * 2n) ? minBlobFee : (currentBlobBase * 2n);

    return {
      maxFeePerGas: maxFee,
      maxPriorityFeePerGas: maxFee / 10n, // Keep priority at 10%
      maxFeePerBlobGas: blobFee
    };
  }

  private async getBaseFee(): Promise<bigint> {
    const block = await this.publicClient.getBlock({ blockTag: 'latest' });
    return block.baseFeePerGas || 1000000000n; // 1 gwei fallback
  }

  private async getBlobBaseFee(): Promise<bigint> {
    try {
      return await this.publicClient.getBlobBaseFee();
    } catch {
      // Fallback if blob base fee not available
      return 1000000000n; // 1 gwei
    }
  }

  private handleSubmissionError(error: any, batchId: number) {
    if (error.code === 'INSUFFICIENT_FUNDS') {
      logger.error('Insufficient funds for blob transaction');
    } else if (error.code === 'NONCE_TOO_LOW') {
      // Reset and retry
      this.currentBlobTx = null;
      logger.info('Nonce too low, will retry with fresh nonce');
    }
    // Don't change batch state on error - keep it sealed for retry
  }
}