import type { Hex } from 'viem';

export interface PendingTransaction {
  batchId: number;
  txHash?: Hex;
  requestId?: string;
  nonce?: number;
  gasPrice?: bigint;
  blobGasPrice?: bigint;
  submittedAt: number;
  attempts: number;
}

export interface Poster {
  /**
   * Post a batch to L1 (either directly or via DA Builder)
   */
  postBatch(batchId: number): Promise<void>;

  /**
   * Check status of pending transactions and handle confirmations
   */
  checkPendingTransaction(): Promise<void>;

  /**
   * Get current pending transaction info
   */
  getPendingTransaction(): PendingTransaction | null;
}