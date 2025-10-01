import {
  createPublicClient,
  http,
  type PublicClient,
  type Hex,
  type Block,
  type Transaction,
  type Chain,
  keccak256,
  toRlp
} from 'viem';
import type { DatabaseService } from '../db/schema.js';
import { logger } from '../utils/logger.js';

export class InclusionMonitor {
  private l1Client: PublicClient;
  private l2Client: PublicClient;
  private readonly FACET_MAGIC_PREFIX = '0x0000000000012345';
  private isMonitoring = false;

  constructor(
    private db: DatabaseService,
    l1RpcUrl: string,
    l2RpcUrl: string,
    private l1Chain: Chain,
    private l2Chain: Chain
  ) {
    this.l1Client = createPublicClient({
      chain: this.l1Chain,
      transport: http(l1RpcUrl)
    });

    this.l2Client = createPublicClient({
      chain: this.l2Chain,
      transport: http(l2RpcUrl)
    });
  }
  
  async start(): Promise<void> {
    if (this.isMonitoring) return;
    this.isMonitoring = true;
    
    logger.info('Starting inclusion monitor');
    
    // Monitor L1 blocks for Facet batches
    const unwatch = this.l1Client.watchBlocks({
      onBlock: async (block) => {
        try {
          await this.scanBlockForFacetBatches(block);
        } catch (error: any) {
          logger.error({ error: error.message }, 'Error scanning L1 block');
        }
      },
      pollingInterval: 12000
    });
    
    // Monitor L2 blocks for transaction inclusion
    const unwatchL2 = this.l2Client.watchBlocks({
      onBlock: async (block) => {
        try {
          await this.checkL2Inclusions(Number(block.number));
        } catch (error: any) {
          logger.error({ error: error.message }, 'Error checking L2 inclusions');
        }
      },
      pollingInterval: 1000
    });
    
    // Periodic reorg check
    setInterval(() => this.checkForReorgs(), 60000);
  }
  
  private async scanBlockForFacetBatches(block: Block): Promise<void> {
    const blockWithTxs = await this.l1Client.getBlock({
      blockNumber: block.number!,
      includeTransactions: true
    });
    
    for (const tx of blockWithTxs.transactions as Transaction[]) {
      // Check calldata for Facet batches
      if (tx.input && tx.input.includes(this.FACET_MAGIC_PREFIX)) {
        await this.handleFacetBatchInCalldata(tx, block);
      }
      
      // Check blob sidecars for Facet batches
      if (tx.blobVersionedHashes && tx.blobVersionedHashes.length > 0) {
        await this.checkBlobsForFacetBatch(tx, block);
      }
    }
  }
  
  private async checkBlobsForFacetBatch(tx: Transaction, block: Block): Promise<void> {
    // For each blob hash, try to fetch the blob data
    for (const blobHash of tx.blobVersionedHashes || []) {
      try {
        // In production, this would fetch from beacon API
        // For now, we'll check our database for matching batches
        const database = this.db.getDatabase();
        
        // Find post attempt for this transaction
        const attempt = database.prepare(`
          SELECT * FROM post_attempts 
          WHERE l1_tx_hash = ? AND status = 'pending'
        `).get(Buffer.from(tx.hash.slice(2), 'hex')) as any;
        
        if (attempt) {
          await this.handleBatchConfirmation(tx, block, attempt.batch_id);
        }
      } catch (error: any) {
        logger.debug({ error: error.message }, 'Error fetching blob');
      }
    }
  }
  
  private async handleFacetBatchInCalldata(tx: Transaction, block: Block): Promise<void> {
    const database = this.db.getDatabase();
    
    // Find post attempt for this transaction
    const attempt = database.prepare(`
      SELECT * FROM post_attempts 
      WHERE l1_tx_hash = ? AND status = 'pending'
    `).get(Buffer.from(tx.hash.slice(2), 'hex')) as any;
    
    if (attempt) {
      await this.handleBatchConfirmation(tx, block, attempt.batch_id);
    }
  }
  
  private async handleBatchConfirmation(
    tx: Transaction, 
    block: Block, 
    batchId: number
  ): Promise<void> {
    const database = this.db.getDatabase();
    
    database.transaction(() => {
      // Update post attempt
      database.prepare(`
        UPDATE post_attempts 
        SET status = 'mined', 
            confirmed_at = ?, 
            block_number = ?,
            block_hash = ?
        WHERE l1_tx_hash = ? AND status = 'pending'
      `).run(
        Date.now(),
        Number(block.number),
        Buffer.from(block.hash!.slice(2), 'hex'),
        Buffer.from(tx.hash.slice(2), 'hex')
      );
      
      // Update batch state
      database.prepare(
        'UPDATE batches SET state = ? WHERE id = ?'
      ).run('l1_included', batchId);
      
      // Update transactions to submitted
      // Since we now use JSON array in batches.tx_hashes, we just update by batch_id
      database.prepare(`
        UPDATE transactions
        SET state = 'submitted'
        WHERE batch_id = ? AND state = 'batched'
      `).run(batchId);
    })();
    
    logger.info({ 
      batchId, 
      txHash: tx.hash,
      blockNumber: block.number 
    }, 'Batch confirmed on L1');
  }
  
  private async checkL2Inclusions(l2BlockNumber: number): Promise<void> {
    const database = this.db.getDatabase();
    
    try {
      // Get L2 block with transactions
      const block = await this.l2Client.getBlock({
        blockNumber: BigInt(l2BlockNumber),
        includeTransactions: true
      });
      
      if (!block || !block.transactions) return;
      
      const includedHashes = new Set(
        (block.transactions as Transaction[]).map(tx => tx.hash.toLowerCase())
      );
      
      // Find all submitted transactions
      const submittedTxs = database.prepare(`
        SELECT hash FROM transactions 
        WHERE state = 'submitted'
      `).all() as Array<{ hash: Buffer }>;
      
      for (const tx of submittedTxs) {
        const txHash = '0x' + tx.hash.toString('hex');
        if (includedHashes.has(txHash.toLowerCase())) {
          // Transaction made it into L2!
          database.prepare(`
            UPDATE transactions 
            SET state = 'l2_included', l2_block_number = ?
            WHERE hash = ?
          `).run(l2BlockNumber, tx.hash);
          
          logger.info({ 
            txHash, 
            l2BlockNumber 
          }, 'Transaction included in L2');
        }
      }
      
      // Check for dropped transactions
      this.checkForDroppedTransactions(l2BlockNumber);
      
    } catch (error: any) {
      logger.debug({ error: error.message }, 'Error checking L2 block');
    }
  }
  
  private checkForDroppedTransactions(l2BlockNumber: number): void {
    const database = this.db.getDatabase();

    // Transactions submitted more than 10 minutes ago but not included
    const tenMinutesAgo = Date.now() - (10 * 60 * 1000);

    const dropped = database.prepare(`
      SELECT t.hash, t.batch_id
      FROM transactions t
      JOIN batches b ON t.batch_id = b.id
      JOIN post_attempts pa ON pa.batch_id = b.id
      WHERE t.state = 'submitted'
      AND pa.status = 'mined'
      AND pa.confirmed_at < ?
    `).all(tenMinutesAgo) as Array<{ hash: Buffer; batch_id: number }>;

    for (const tx of dropped) {
      database.prepare(`
        UPDATE transactions
        SET state = 'dropped', drop_reason = 'Not included after 10 minutes'
        WHERE hash = ?
      `).run(tx.hash);

      logger.warn({
        txHash: '0x' + tx.hash.toString('hex')
      }, 'Transaction dropped');
    }
  }
  
  private async checkForReorgs(): Promise<void> {
    const database = this.db.getDatabase();
    
    const currentBlock = await this.l1Client.getBlockNumber();
    
    const recentAttempts = database.prepare(`
      SELECT * FROM post_attempts 
      WHERE status = 'mined' 
      AND block_number > ? - 10
    `).all(Number(currentBlock)) as Array<{
      id: number;
      batch_id: number;
      block_number: number;
      block_hash: Buffer;
    }>;
    
    for (const attempt of recentAttempts) {
      try {
        const block = await this.l1Client.getBlock({
          blockNumber: BigInt(attempt.block_number)
        });
        
        const blockHash = Buffer.from(block.hash!.slice(2), 'hex');
        if (!block || !blockHash.equals(attempt.block_hash)) {
          await this.handleReorg(attempt);
        }
      } catch (error: any) {
        logger.error({ error: error.message }, 'Error checking for reorg');
      }
    }
  }
  
  private async handleReorg(attempt: any): Promise<void> {
    const database = this.db.getDatabase();
    
    database.transaction(() => {
      // Mark attempt as reorged
      database.prepare(
        'UPDATE post_attempts SET status = ? WHERE id = ?'
      ).run('reorged', attempt.id);
      
      // Revert batch state
      database.prepare(
        'UPDATE batches SET state = ? WHERE id = ?'
      ).run('sealed', attempt.batch_id);
      
      // Revert transaction states
      database.prepare(`
        UPDATE transactions 
        SET state = 'batched'
        WHERE batch_id = ? AND state IN ('submitted', 'l1_included')
      `).run(attempt.batch_id);
    })();
    
    logger.warn({ 
      batchId: attempt.batch_id,
      blockNumber: attempt.block_number 
    }, 'Reorg detected, reverting batch');
  }
}