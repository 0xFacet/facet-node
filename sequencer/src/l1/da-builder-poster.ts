import {
  createPublicClient,
  http,
  type Hex,
  type PrivateKeyAccount,
  type PublicClient,
  type Chain
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import type { DatabaseService, Batch } from '../db/schema.js';
import { logger } from '../utils/logger.js';
import type { Poster, PendingTransaction } from './poster-interface.js';
import { DABuilderClient } from './da-builder-client.js';

export class DABuilderPoster implements Poster {
  private publicClient: PublicClient;
  private account: PrivateKeyAccount;
  private daBuilderClient: DABuilderClient;
  private currentPending: PendingTransaction | null = null;
  private lastPollTime: number = 0;
  private pollInterval: number = 5000; // Poll every 5 seconds

  constructor(
    private db: DatabaseService,
    private chain: Chain,
    privateKey: Hex,
    rpcUrl: string,
    daBuilderUrl: string
  ) {
    this.account = privateKeyToAccount(privateKey);

    this.publicClient = createPublicClient({
      chain: this.chain,
      transport: http(rpcUrl)
    });

    this.daBuilderClient = new DABuilderClient(
      daBuilderUrl,
      this.chain.id,
      this.account,
      this.publicClient
    );
  }

  async postBatch(batchId: number): Promise<void> {
    const database = this.db.getDatabase();

    // Get batch data
    const batch = database.prepare(
      'SELECT * FROM batches WHERE id = ? AND state = ?'
    ).get(batchId, 'sealed') as Batch | undefined;

    if (!batch) {
      logger.error({ batchId }, 'Batch not found or not sealed');
      return;
    }

    try {
      // Convert wire format to hex
      const wireFormatHex = ('0x' + batch.wire_format.toString('hex')) as Hex;

      // Submit to DA Builder with the target block from the batch
      const targetBlock = batch.target_l1_block ? BigInt(batch.target_l1_block) : undefined;
      const submitResult = await this.daBuilderClient.submit(wireFormatHex, targetBlock);

      // Track pending transaction
      this.currentPending = {
        batchId,
        requestId: submitResult.id,
        submittedAt: Date.now(),
        attempts: 1
      };

      // Store post attempt with DA Builder request ID
      // Need to provide all required columns even if not used for DA Builder
      database.prepare(`
        INSERT INTO post_attempts (
          batch_id, da_builder_request_id, l1_nonce, gas_price,
          max_fee_per_gas, max_fee_per_blob_gas, submitted_at, status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, 'pending')
      `).run(
        batchId,
        submitResult.id,
        0, // nonce not used for DA Builder
        '0', // gas prices handled by DA Builder
        '0',
        '0',
        Date.now()
      );

      // Update batch state
      database.prepare(
        'UPDATE batches SET state = ? WHERE id = ?'
      ).run('submitted', batchId);

      logger.info({
        batchId,
        requestId: submitResult.id
      }, 'Batch submitted to DA Builder');

    } catch (error: any) {
      logger.error({ batchId, error: error.message }, 'Failed to submit batch to DA Builder');

      // Check if we should fallback to direct submission
      // This would be handled by the orchestrator based on config.fallbackToDirect
      throw error;
    }
  }

  async checkPendingTransaction(): Promise<void> {
    if (!this.currentPending || !this.currentPending.requestId) return;

    // Rate limit polling
    const now = Date.now();
    if (now - this.lastPollTime < this.pollInterval) return;
    this.lastPollTime = now;

    try {
      // Poll DA Builder for receipt
      const receipt = await this.daBuilderClient.poll(this.currentPending.requestId);

      if (receipt) {
        const database = this.db.getDatabase();

        // Update post attempt with L1 tx hash
        database.prepare(`
          UPDATE post_attempts
          SET l1_tx_hash = ?, status = 'mined', confirmed_at = ?
          WHERE da_builder_request_id = ?
        `).run(
          Buffer.from(receipt.txHash.slice(2), 'hex'),
          Date.now(),
          this.currentPending.requestId
        );

        logger.info({
          batchId: this.currentPending.batchId,
          requestId: this.currentPending.requestId,
          txHash: receipt.txHash,
          blockNumber: receipt.blockNumber
        }, 'DA Builder transaction confirmed');

        // Clear current pending
        this.currentPending = null;
      } else {
        // Still pending, check if timeout
        const elapsed = Date.now() - this.currentPending.submittedAt;
        if (elapsed > 900000) { // 15 minutes timeout
          logger.warn({
            batchId: this.currentPending.batchId,
            requestId: this.currentPending.requestId,
            elapsed
          }, 'DA Builder submission timeout');

          // Mark as failed
          const database = this.db.getDatabase();
          database.prepare(`
            UPDATE post_attempts
            SET status = 'failed'
            WHERE da_builder_request_id = ?
          `).run(this.currentPending.requestId);

          // Clear and let orchestrator handle retry
          this.currentPending = null;
        }
      }
    } catch (error: any) {
      logger.debug({
        error: error.message,
        requestId: this.currentPending.requestId
      }, 'Error checking DA Builder status');
    }
  }

  getPendingTransaction(): PendingTransaction | null {
    return this.currentPending;
  }
}