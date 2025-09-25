import { 
  parseTransaction, 
  type TransactionSerializableEIP1559, 
  keccak256, 
  type Hex, 
  toHex,
  recoverTransactionAddress,
  type TransactionSerializedEIP1559
} from 'viem';
import type { DatabaseService } from '../db/schema.js';
import { logger } from '../utils/logger.js';

export class IngressServer {
  private readonly MAX_PENDING = 10000;
  private readonly MIN_BASE_FEE = 1000000000n; // 1 gwei
  private readonly MAX_TX_SIZE = 128 * 1024; // 128KB
  private readonly BLOCK_GAS_LIMIT = 30_000_000;
  
  constructor(private db: DatabaseService) {}
  
  async handleTransaction(rawTx: Hex): Promise<Hex> {
    // Input sanitization
    if (!rawTx.startsWith('0x') || rawTx.length % 2 !== 0) {
      throw new Error('Invalid hex encoding');
    }
    
    if (rawTx.length > this.MAX_TX_SIZE * 2) {
      throw new Error('Transaction too large');
    }
    
    // Back-pressure check
    const queuedCount = this.db.getDatabase().prepare(
      'SELECT COUNT(*) as count FROM transactions WHERE state IN (?, ?)'
    ).get('queued', 'requeued') as { count: number };
    
    if (queuedCount.count >= this.MAX_PENDING) {
      throw new Error('Sequencer busy');
    }
    
    // Decode and validate EIP-1559
    let tx: TransactionSerializableEIP1559;
    let from: Hex;
    try {
      const parsed = parseTransaction(rawTx);
      if (parsed.type !== 'eip1559') {
        throw new Error('Only EIP-1559 transactions accepted');
      }
      tx = parsed as TransactionSerializableEIP1559;
      
      // Recover the from address from the signed transaction
      from = await recoverTransactionAddress({
        serializedTransaction: rawTx as TransactionSerializedEIP1559
      });
      
      if (!from) {
        throw new Error('Could not recover sender address');
      }
    } catch (e: any) {
      throw new Error('Invalid transaction encoding: ' + e.message);
    }
    
    if (!tx.maxFeePerGas || tx.maxFeePerGas < this.MIN_BASE_FEE) {
      throw new Error('Max fee per gas below minimum');
    }
    
    if (!tx.maxPriorityFeePerGas) {
      throw new Error('Priority fee required');
    }
    
    if (!tx.gas || tx.gas > BigInt(this.BLOCK_GAS_LIMIT)) {
      throw new Error('Invalid gas limit');
    }
    
    // Calculate intrinsic gas
    const intrinsicGas = this.calculateIntrinsicGas(tx);
    if (intrinsicGas > Number(tx.gas)) {
      throw new Error('Gas limit below intrinsic gas');
    }
    
    // Calculate transaction hash
    const txHash = keccak256(rawTx);
    
    // Store transaction atomically
    const database = this.db.getDatabase();
    const result = database.transaction(() => {
      // Get next sequence number
      const seqResult = database.prepare(
        'SELECT COALESCE(MAX(received_seq), 0) + 1 as next_seq FROM transactions'
      ).get() as { next_seq: number };
      
      // Check for duplicate hash
      const existing = database.prepare(
        'SELECT hash FROM transactions WHERE hash = ?'
      ).get(Buffer.from(txHash.slice(2), 'hex'));
      
      if (existing) {
        return { exists: true, hash: txHash, replaced: false };
      }
      
      // Check for same nonce (potential replacement)
      const sameNonce = database.prepare(
        'SELECT hash, max_fee_per_gas FROM transactions WHERE from_address = ? AND nonce = ? AND state = ?'
      ).get(
        Buffer.from(from.slice(2), 'hex'),
        Number(tx.nonce || 0),
        'queued'
      ) as any;
      
      if (sameNonce) {
        // Replace-by-fee: new transaction must have higher gas price
        const oldMaxFee = BigInt(sameNonce.max_fee_per_gas);
        const newMaxFee = tx.maxFeePerGas!;
        
        if (newMaxFee > oldMaxFee) {
          // Delete old transaction and insert new one
          database.prepare('DELETE FROM transactions WHERE hash = ?').run(sameNonce.hash);
          logger.info({ 
            oldHash: '0x' + sameNonce.hash.toString('hex'),
            newHash: txHash,
            oldFee: oldMaxFee.toString(),
            newFee: newMaxFee.toString()
          }, 'Replacing transaction with higher gas price');
        } else {
          throw new Error('Replacement transaction underpriced');
        }
      }
      
      // Insert transaction
      const stmt = database.prepare(`
        INSERT INTO transactions (
          hash, raw, from_address, nonce, max_fee_per_gas,
          max_priority_fee_per_gas, gas_limit, intrinsic_gas,
          received_seq, received_at, state
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `);
      
      stmt.run(
        Buffer.from(txHash.slice(2), 'hex'),
        Buffer.from(rawTx.slice(2), 'hex'),
        Buffer.from(from.slice(2), 'hex'),
        Number(tx.nonce || 0),
        tx.maxFeePerGas!.toString(),
        tx.maxPriorityFeePerGas!.toString(),
        Number(tx.gas),
        intrinsicGas,
        seqResult.next_seq,
        Date.now(),
        'queued'
      );
      
      return { exists: false, hash: txHash, replaced: !!sameNonce };
    })();
    
    if (!result.exists) {
      logger.info({ hash: txHash }, 'Transaction accepted');
    }
    
    return txHash;
  }
  
  private calculateIntrinsicGas(tx: TransactionSerializableEIP1559): number {
    // Base cost
    let gas = 21000;
    
    // Contract creation cost
    if (!tx.to) {
      gas += 32000;
    }
    
    // Data cost (4 gas per zero byte, 16 per non-zero)
    if (tx.data) {
      const data = typeof tx.data === 'string' ? tx.data : toHex(tx.data);
      const bytes = Buffer.from(data.slice(2), 'hex');
      for (const byte of bytes) {
        gas += byte === 0 ? 4 : 16;
      }
    }
    
    // Access list cost
    if (tx.accessList && tx.accessList.length > 0) {
      for (const entry of tx.accessList) {
        gas += 2400; // Address cost
        gas += 1900 * (entry.storageKeys?.length || 0); // Storage key cost
      }
    }
    
    return gas;
  }
  
  async getTransactionStatus(hash: Hex): Promise<any> {
    const tx = this.db.getDatabase().prepare(`
      SELECT 
        t.state,
        t.batch_id,
        t.l2_block_number,
        t.drop_reason,
        b.state as batch_state,
        pa.l1_tx_hash,
        pa.block_number as l1_block,
        pa.status as attempt_status
      FROM transactions t
      LEFT JOIN batches b ON t.batch_id = b.id
      LEFT JOIN post_attempts pa ON b.id = pa.batch_id AND pa.status = 'mined'
      WHERE t.hash = ?
    `).get(Buffer.from(hash.slice(2), 'hex')) as any;
    
    if (!tx) {
      return { status: 'unknown' };
    }
    
    return {
      status: tx.state,
      batchId: tx.batch_id,
      batchState: tx.batch_state,
      l1TxHash: tx.l1_tx_hash ? '0x' + tx.l1_tx_hash.toString('hex') : undefined,
      l1Block: tx.l1_block,
      l2Block: tx.l2_block_number,
      dropReason: tx.drop_reason
    };
  }
}