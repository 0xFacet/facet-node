/**
 * Simple in-memory transaction status cache for RPC responses
 * This replaces complex database state tracking
 */

import { type Hex } from 'viem';

interface TxStatus {
  hash: Hex;
  status: 'pending' | 'batched' | 'included' | 'failed';
  timestamp: number;
  batchId?: number;
  l2BlockNumber?: number;
  l2BlockHash?: Hex;
  receipt?: any; // Full receipt once included
}

export class TxStatusCache {
  private cache = new Map<string, TxStatus>();
  private readonly TTL_MS = 60 * 60 * 1000; // 1 hour

  constructor() {
    // Cleanup old entries every 5 minutes
    setInterval(() => this.cleanup(), 5 * 60 * 1000);
  }

  setPending(hash: Hex): void {
    this.cache.set(hash.toLowerCase(), {
      hash,
      status: 'pending',
      timestamp: Date.now()
    });
  }

  setBatched(hash: Hex, batchId: number): void {
    const existing = this.cache.get(hash.toLowerCase());
    if (existing) {
      existing.status = 'batched';
      existing.batchId = batchId;
    }
  }

  setIncluded(hash: Hex, blockNumber: number, blockHash: Hex, receipt: any): void {
    const existing = this.cache.get(hash.toLowerCase());
    if (existing) {
      existing.status = 'included';
      existing.l2BlockNumber = blockNumber;
      existing.l2BlockHash = blockHash;
      existing.receipt = receipt;
    } else {
      // Even if we didn't track it before, cache the result
      this.cache.set(hash.toLowerCase(), {
        hash,
        status: 'included',
        timestamp: Date.now(),
        l2BlockNumber: blockNumber,
        l2BlockHash: blockHash,
        receipt
      });
    }
  }

  get(hash: Hex): TxStatus | undefined {
    return this.cache.get(hash.toLowerCase());
  }

  getReceipt(hash: Hex): any | null {
    const status = this.cache.get(hash.toLowerCase());
    if (status?.status === 'included' && status.receipt) {
      return status.receipt;
    }
    return null;
  }

  private cleanup(): void {
    const now = Date.now();
    const expired: string[] = [];

    for (const [hash, status] of this.cache.entries()) {
      if (now - status.timestamp > this.TTL_MS) {
        expired.push(hash);
      }
    }

    for (const hash of expired) {
      this.cache.delete(hash);
    }

    if (expired.length > 0) {
      console.log(`Cleaned up ${expired.length} expired tx statuses`);
    }
  }

  // For monitoring
  stats(): { pending: number; batched: number; included: number; total: number } {
    let pending = 0, batched = 0, included = 0;

    for (const status of this.cache.values()) {
      switch (status.status) {
        case 'pending': pending++; break;
        case 'batched': batched++; break;
        case 'included': included++; break;
      }
    }

    return { pending, batched, included, total: this.cache.size };
  }
}