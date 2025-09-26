import { keccak256, toHex, concatHex, toRlp, size, type Hex, encodePacked } from 'viem';
import type { DatabaseService } from '../db/schema.js';
import { logger } from '../utils/logger.js';
import type { PublicClient } from 'viem';

interface Transaction {
  hash: Buffer;
  raw: Buffer;
  from_address: Buffer;
  nonce: number;
  max_fee_per_gas: string;
  intrinsic_gas: number;
  received_seq: number;
}

export class BatchMaker {
  private readonly MAX_PER_SENDER = 10;
  private readonly MAX_BATCH_GAS = 30_000_000;
  private readonly FACET_MAGIC_PREFIX = '0x0000000000012345' as Hex;
  private readonly L2_CHAIN_ID: bigint;
  private readonly MAX_BLOB_SIZE = 131072; // 128KB
  private lastBatchTime = Date.now();
  
  constructor(
    private db: DatabaseService,
    private l1Client: PublicClient,
    l2ChainId: string
  ) {
    this.L2_CHAIN_ID = BigInt(l2ChainId);
  }
  
  async createBatch(maxBytes: number = this.MAX_BLOB_SIZE - 1000, maxCount: number = 500): Promise<number | null> {
    const database = this.db.getDatabase();

    // Get L1 data before starting the transaction
    const targetL1Block = await this.getNextL1Block();
    const gasBid = await this.calculateGasBid();

    return database.transaction(() => {
      // Select transactions ordered by fee
      const candidates = database.prepare(`
        SELECT * FROM transactions
        WHERE state IN ('queued', 'requeued')
        ORDER BY max_fee_per_gas DESC, received_seq ASC
        LIMIT ?
      `).all(maxCount * 2) as Transaction[];

      if (candidates.length === 0) return null;

      // Apply selection criteria
      const selected = this.selectTransactions(candidates, maxBytes, maxCount);
      if (selected.length === 0) return null;
      
      // Create Facet batch wire format
      const wireFormat = this.createFacetWireFormat(selected, targetL1Block);
      const contentHash = this.calculateContentHash(selected, targetL1Block);
      
      // Check for duplicate batch
      const existing = database.prepare(
        'SELECT id FROM batches WHERE content_hash = ?'
      ).get(contentHash);
      
      if (existing) {
        logger.warn({ contentHash: toHex(contentHash) }, 'Batch already exists');
        return null;
      }
      
      // Prepare the ordered transaction hashes for JSON storage
      const txHashesJson = JSON.stringify(
        selected.map(tx => '0x' + tx.hash.toString('hex'))
      );

      // Create batch record with tx_hashes as JSON
      const batchResult = database.prepare(`
        INSERT INTO batches (content_hash, wire_format, state, blob_size, gas_bid, tx_count, target_l1_block, tx_hashes)
        VALUES (?, ?, 'open', ?, ?, ?, ?, ?)
      `).run(
        contentHash,
        wireFormat,
        wireFormat.length,
        gasBid.toString(),
        selected.length,
        Number(targetL1Block),
        txHashesJson
      );

      const batchId = batchResult.lastInsertRowid as number;
      
      // Update transaction states
      const updateTxs = database.prepare(`
        UPDATE transactions 
        SET state = 'batched', batch_id = ?
        WHERE hash = ?
      `);
      
      for (const tx of selected) {
        updateTxs.run(batchId, tx.hash);
      }
      
      // Seal the batch
      database.prepare(
        'UPDATE batches SET state = ?, sealed_at = ? WHERE id = ?'
      ).run('sealed', Date.now(), batchId);
      
      logger.info({ 
        batchId, 
        txCount: selected.length,
        size: wireFormat.length,
        targetL1Block: targetL1Block.toString()
      }, 'Batch created');
      
      return batchId;
    })() as number | null;
  }
  
  private selectTransactions(candidates: Transaction[], maxBytes: number, maxCount: number): Transaction[] {
    const selected: Transaction[] = [];
    const senderCounts = new Map<string, number>();
    let currentSize = 200; // Account for batch overhead
    let currentGas = 0;
    
    for (const tx of candidates) {
      // Size constraint
      if (currentSize + tx.raw.length > maxBytes) continue;
      
      // Gas constraint  
      if (currentGas + tx.intrinsic_gas > this.MAX_BATCH_GAS) continue;
      
      // Sender fairness
      const senderKey = tx.from_address.toString('hex');
      const count = senderCounts.get(senderKey) || 0;
      if (count >= this.MAX_PER_SENDER) continue;
      
      selected.push(tx);
      currentSize += tx.raw.length;
      currentGas += tx.intrinsic_gas;
      senderCounts.set(senderKey, count + 1);
      
      if (selected.length >= maxCount) break;
    }
    
    return selected;
  }
  
  private createFacetWireFormat(transactions: Transaction[], targetL1Block: bigint): Buffer {
    // Build FacetBatchData structure
    const batchData = [
      toHex(1), // version
      toHex(this.L2_CHAIN_ID), // chainId  
      "0x" as Hex, // role (0 = FORCED)
      toHex(targetL1Block), // targetL1Block
      transactions.map(tx => ('0x' + tx.raw.toString('hex')) as Hex), // raw transaction bytes
      '0x' as Hex // extraData
    ];
    
    // For forced batches, wrap in outer array: [FacetBatchData]
    // For priority batches, it would be: [FacetBatchData, signature]
    const wrappedBatch = [batchData];
    
    // RLP encode the wrapped batch
    const batchRlp = toRlp(wrappedBatch);
    
    // Create wire format: magic || uint32_be(length) || rlp(batch)
    const lengthBytes = toHex(size(batchRlp), { size: 4 });
    const wireFormatHex = concatHex([
      this.FACET_MAGIC_PREFIX,
      lengthBytes,
      batchRlp
    ]);
    
    return Buffer.from(wireFormatHex.slice(2), 'hex');
  }
  
  private calculateContentHash(transactions: Transaction[], targetL1Block: bigint): Buffer {
    // Calculate content hash for deduplication
    const batchData = [
      toHex(1), // version
      toHex(this.L2_CHAIN_ID), // chainId
      "0x" as Hex, // role (0 = FORCED)  
      toHex(targetL1Block), // targetL1Block
      transactions.map(tx => ('0x' + tx.raw.toString('hex')) as Hex),
      '0x' as Hex
    ];
    
    const hash = keccak256(toRlp(batchData));
    return Buffer.from(hash.slice(2), 'hex');
  }
  
  private async getNextL1Block(): Promise<bigint> {
    // Get the actual next L1 block number
    const currentBlock = await this.l1Client.getBlockNumber();
    return currentBlock + 1n;
  }

  private async calculateGasBid(): Promise<bigint> {
    // Get actual gas prices from L1
    const fees = await this.l1Client.estimateFeesPerGas();
    // Use 2x the current base fee for reliability
    return fees.maxFeePerGas ? fees.maxFeePerGas * 2n : 100000000000n;
  }
  
  async shouldCreateBatch(): Promise<boolean> {
    const database = this.db.getDatabase();
    
    const stats = database.prepare(`
      SELECT 
        COUNT(*) as pending_count,
        SUM(LENGTH(raw)) as pending_size
      FROM transactions 
      WHERE state IN ('queued', 'requeued')
    `).get() as { pending_count: number; pending_size: number | null };
    
    if (stats.pending_count === 0) return false;
    
    const timeSinceLastBatch = Date.now() - this.lastBatchTime;
    const pendingSize = stats.pending_size || 0;
    
    // Dynamic triggers
    const shouldBatch = 
      pendingSize >= (this.MAX_BLOB_SIZE - 1000) ||
      stats.pending_count >= this.getOptimalBatchSize() ||
      (stats.pending_count > 0 && timeSinceLastBatch >= 3000);
    
    if (shouldBatch) {
      this.lastBatchTime = Date.now();
    }
    
    return shouldBatch;
  }
  
  private getOptimalBatchSize(): number {
    // In production, adjust based on L1 congestion
    return 200;
  }
}