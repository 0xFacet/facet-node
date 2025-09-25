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

interface PendingBlob {
  batchId: number;
  txHash: Hex;
  nonce: number;
  gasPrice: bigint;
  blobGasPrice?: bigint;
  submittedAt: number;
  attempts: number;
}

export class L1Poster {
  private wallet: WalletClient;
  private publicClient: PublicClient;
  private account: PrivateKeyAccount;
  private currentBlobTx: PendingBlob | null = null;
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
    const oldFee = this.currentBlobTx!.gasPrice;
    const oldBlobFee = this.currentBlobTx!.blobGasPrice || 1n;
    
    const [baseFee, blobBaseFee] = await Promise.all([
      this.getBaseFee(),
      this.getBlobBaseFee()
    ]);
    
    // Use BigInt math to avoid precision issues
    // Always bump by at least 12.5% (multiply by 9/8)
    const bumpedFee = (oldFee * 9n) / 8n;
    const bumpedBlobFee = (oldBlobFee * 9n) / 8n;
    
    // Also ensure we're at least 2x current base fee
    const minFee = baseFee * 2n;
    const minBlobFee = blobBaseFee * 2n;
    
    // Take the maximum of bumped fee and minimum required
    const newFee = bumpedFee > minFee ? bumpedFee : minFee;
    const newBlobFee = bumpedBlobFee > minBlobFee ? bumpedBlobFee : minBlobFee;
    
    // Ensure priority fee is less than max fee (10% of max fee)
    const priorityFee = newFee / 10n;
    
    logger.info({
      oldFee: oldFee.toString(),
      newFee: newFee.toString(),
      baseFee: baseFee.toString(),
      attempt: this.currentBlobTx!.attempts + 1
    }, 'Escalating L1 transaction fees');
    
    return {
      maxFeePerGas: newFee,
      maxPriorityFeePerGas: priorityFee,
      maxFeePerBlobGas: newBlobFee
    };
  }
  
  private async getBaseFee(): Promise<bigint> {
    const block = await this.publicClient.getBlock({ blockTag: 'latest' });
    return block.baseFeePerGas || 1000000000n;
  }
  
  private async getBlobBaseFee(): Promise<bigint> {
    try {
      const block = await this.publicClient.getBlock({ blockTag: 'latest' });
      // @ts-ignore - blobGasPrice might not be in types yet
      return block.blobGasPrice || 1n;
    } catch {
      return 1n;
    }
  }
  
  private handleSubmissionError(error: any, batchId: number): void {
    const database = this.db.getDatabase();
    
    if (error.message?.includes('replacement transaction underpriced')) {
      logger.warn({ batchId }, 'RBF underpriced, will retry with higher fee');
    } else if (error.message?.includes('nonce too low')) {
      // Reset nonce tracking
      this.currentBlobTx = null;
      logger.warn({ batchId }, 'Nonce too low, resetting');
    } else {
      // Log failure
      database.prepare(`
        UPDATE post_attempts 
        SET status = 'failed', failure_reason = ?
        WHERE batch_id = ? AND status = 'pending'
      `).run(error.message, batchId);
      
      // Reset batch to sealed for retry
      database.prepare(
        'UPDATE batches SET state = ? WHERE id = ?'
      ).run('sealed', batchId);
    }
  }
  
  async checkPendingTransaction(): Promise<void> {
    if (!this.currentBlobTx) return;
    
    try {
      const receipt = await this.publicClient.getTransactionReceipt({
        hash: this.currentBlobTx.txHash
      });
      
      if (receipt) {
        const database = this.db.getDatabase();
        
        // Update post attempt
        database.prepare(`
          UPDATE post_attempts 
          SET status = ?, confirmed_at = ?, block_number = ?, block_hash = ?
          WHERE l1_tx_hash = ? AND status = 'pending'
        `).run(
          'mined',
          Date.now(),
          Number(receipt.blockNumber),
          Buffer.from(receipt.blockHash.slice(2), 'hex'),
          Buffer.from(this.currentBlobTx.txHash.slice(2), 'hex')
        );
        
        // Update batch state
        database.prepare(
          'UPDATE batches SET state = ? WHERE id = ?'
        ).run('l1_included', this.currentBlobTx.batchId);
        
        logger.info({ 
          batchId: this.currentBlobTx.batchId,
          txHash: receipt.transactionHash,
          blockNumber: receipt.blockNumber
        }, 'Batch confirmed on L1');
        
        // Clear current transaction
        this.currentBlobTx = null;
        this.lastNonce++;
      } else {
        // Check if we should escalate fees
        const timePending = Date.now() - this.currentBlobTx.submittedAt;
        if (timePending > 30000 && this.currentBlobTx.attempts < 5) {
          // Escalate after 30 seconds
          logger.info({ batchId: this.currentBlobTx.batchId }, 'Escalating fees');
          await this.postBatch(this.currentBlobTx.batchId);
        }
      }
    } catch (error: any) {
      // Only log actual errors, not "transaction not found" which is expected for pending txs
      if (!error.message?.includes('could not be found')) {
        logger.error({ error: error.message }, 'Error checking pending transaction');
      } else {
        // Transaction is still pending, this is normal
        const timePending = Date.now() - this.currentBlobTx.submittedAt;
        if (timePending > 30000 && this.currentBlobTx.attempts < 5) {
          // Escalate after 30 seconds
          logger.info({ batchId: this.currentBlobTx.batchId }, 'Transaction still pending, escalating fees');
          await this.postBatch(this.currentBlobTx.batchId);
        }
      }
    }
  }
}