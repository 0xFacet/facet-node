import Database from 'better-sqlite3';
import { type Hex } from 'viem';

export interface Transaction {
  hash: Buffer;
  raw: Buffer;
  from_address: Buffer;
  nonce: number;
  max_fee_per_gas: string;
  max_priority_fee_per_gas?: string;  // Optional for legacy transactions
  gas_limit: number;
  intrinsic_gas: number;
  received_seq: number;
  received_at: number;
  state: 'queued' | 'batched' | 'submitted' | 'l1_included' | 'l2_included' | 'dropped' | 'requeued';
  batch_id?: number;
  l2_block_number?: number;
  drop_reason?: string;
}

export interface Batch {
  id: number;
  content_hash: Buffer;
  wire_format: Buffer;
  state: 'open' | 'sealed' | 'submitted' | 'l1_included' | 'reorged' | 'failed' | 'finalized';
  sealed_at?: number;
  blob_size: number;
  gas_bid: string;
  tx_count: number;
  target_l1_block?: number;
  tx_hashes: string; // JSON array of transaction hashes
}

// Removed BatchItem interface - now using JSON column in batches table

export interface PostAttempt {
  id: number;
  batch_id: number;
  l1_tx_hash?: Buffer;
  da_builder_request_id?: string;
  l1_nonce?: number;
  gas_price: string;
  max_fee_per_gas?: string;
  max_fee_per_blob_gas?: string;
  submitted_at: number;
  confirmed_at?: number;
  block_number?: number;
  block_hash?: Buffer;
  status: 'pending' | 'mined' | 'replaced' | 'reorged' | 'failed';
  replaced_by?: number;
  failure_reason?: string;
}

export const createSchema = (db: Database.Database) => {
  db.pragma('journal_mode = WAL');
  db.pragma('busy_timeout = 5000');
  
  db.exec(`
    -- Transaction state machine
    CREATE TABLE IF NOT EXISTS transactions (
      hash BLOB PRIMARY KEY,
      raw BLOB NOT NULL,
      from_address BLOB NOT NULL,
      nonce INTEGER NOT NULL,
      max_fee_per_gas TEXT NOT NULL,
      max_priority_fee_per_gas TEXT,  -- Nullable for legacy transactions
      gas_limit INTEGER NOT NULL,
      intrinsic_gas INTEGER NOT NULL,
      received_seq INTEGER NOT NULL,
      received_at INTEGER NOT NULL,
      state TEXT NOT NULL DEFAULT 'queued' CHECK(state IN (
        'queued', 'batched', 'submitted', 'l1_included', 'l2_included', 'dropped', 'requeued'
      )),
      batch_id INTEGER,
      l2_block_number INTEGER,
      drop_reason TEXT,
      FOREIGN KEY (batch_id) REFERENCES batches(id)
    );
    
    -- Batch state machine
    CREATE TABLE IF NOT EXISTS batches (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      content_hash BLOB NOT NULL UNIQUE,
      wire_format BLOB NOT NULL,
      state TEXT NOT NULL DEFAULT 'open' CHECK(state IN (
        'open', 'sealed', 'submitted', 'l1_included', 'reorged', 'failed', 'finalized'
      )),
      sealed_at INTEGER,
      blob_size INTEGER NOT NULL,
      gas_bid TEXT NOT NULL,
      tx_count INTEGER NOT NULL,
      target_l1_block INTEGER,
      tx_hashes JSON NOT NULL DEFAULT '[]' -- JSON array of transaction hashes in order
    );
    
    -- Tracks all L1 submission attempts
    CREATE TABLE IF NOT EXISTS post_attempts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      batch_id INTEGER NOT NULL,
      l1_tx_hash BLOB,
      da_builder_request_id TEXT,
      l1_nonce INTEGER,
      gas_price TEXT NOT NULL,
      max_fee_per_gas TEXT,
      max_fee_per_blob_gas TEXT,
      submitted_at INTEGER NOT NULL,
      confirmed_at INTEGER,
      block_number INTEGER,
      block_hash BLOB,
      status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN (
        'pending', 'mined', 'replaced', 'reorged', 'failed'
      )),
      replaced_by INTEGER,
      failure_reason TEXT,
      FOREIGN KEY (batch_id) REFERENCES batches(id),
      FOREIGN KEY (replaced_by) REFERENCES post_attempts(id)
    );
    
    -- Critical indexes for performance
    CREATE INDEX IF NOT EXISTS idx_tx_state_queued 
      ON transactions(state, max_fee_per_gas DESC, received_seq ASC) 
      WHERE state IN ('queued', 'requeued');
    CREATE INDEX IF NOT EXISTS idx_tx_from_nonce 
      ON transactions(from_address, nonce);
    CREATE INDEX IF NOT EXISTS idx_batch_state 
      ON batches(state) WHERE state IN ('sealed', 'submitted');
    CREATE INDEX IF NOT EXISTS idx_batch_content_hash 
      ON batches(content_hash);
    CREATE INDEX IF NOT EXISTS idx_attempts_pending 
      ON post_attempts(status, submitted_at) WHERE status = 'pending';
    CREATE INDEX IF NOT EXISTS idx_attempts_batch 
      ON post_attempts(batch_id, status);
  `);
};

export class DatabaseService {
  private db: Database.Database;
  
  constructor(dbPath: string) {
    this.db = new Database(dbPath);
    createSchema(this.db);
    
    // Prepare common statements
    this.insertTx = this.db.prepare(`
      INSERT INTO transactions (
        hash, raw, from_address, nonce, max_fee_per_gas,
        max_priority_fee_per_gas, gas_limit, intrinsic_gas,
        received_seq, received_at, state
      ) VALUES (
        @hash, @raw, @from_address, @nonce, @max_fee_per_gas,
        @max_priority_fee_per_gas, @gas_limit, @intrinsic_gas,
        @received_seq, @received_at, @state
      )
    `);
    
    this.getQueuedCount = this.db.prepare(`
      SELECT COUNT(*) as count FROM transactions 
      WHERE state IN ('queued', 'requeued')
    `);
    
    this.getQueuedTxs = this.db.prepare(`
      SELECT * FROM transactions 
      WHERE state IN ('queued', 'requeued')
      ORDER BY max_fee_per_gas DESC, received_seq ASC
      LIMIT ?
    `);
  }
  
  private insertTx: Database.Statement;
  private getQueuedCount: Database.Statement;
  private getQueuedTxs: Database.Statement;
  
  getDatabase(): Database.Database {
    return this.db;
  }
  
  close(): void {
    this.db.close();
  }
}