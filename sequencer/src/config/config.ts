import { config as dotenvConfig } from 'dotenv';
import { resolve } from 'path';
import type { Hex } from 'viem';

// Load environment variables
dotenvConfig({ path: resolve(process.cwd(), '.env') });

export interface Config {
  // L1 Connection
  l1RpcUrl: string;
  l1ChainId: number;
  privateKey: Hex;
  
  // L2 Connection
  l2RpcUrl: string;
  l2ChainId: string;
  
  // Facet Configuration
  facetMagicPrefix: Hex;
  
  // Batching Parameters
  maxTxPerBatch: number;
  maxBatchSize: number;
  batchIntervalMs: number;
  maxPerSender: number;
  
  // Economics
  minGasPrice: bigint;
  baseFeeMultiplier: number;
  escalationRate: number;
  
  // Operational
  maxPendingTxs: number;
  dbPath: string;
  port: number;
  logLevel: string;
  
  // Monitoring
  metricsEnabled: boolean;
  metricsPort: number;
}

export function loadConfig(): Config {
  const config: Config = {
    // L1 Connection
    l1RpcUrl: process.env.L1_RPC_URL!,
    l1ChainId: parseInt(process.env.L1_CHAIN_ID!, 16), // Holesky
    privateKey: (process.env.PRIVATE_KEY || '0x') as Hex,
    
    // L2 Connection
    l2RpcUrl: process.env.L2_RPC_URL || 'http://localhost:8546',
    l2ChainId: process.env.L2_CHAIN_ID!,
    
    // Facet Configuration
    facetMagicPrefix: process.env.FACET_MAGIC_PREFIX as Hex,
    
    // Batching Parameters
    maxTxPerBatch: parseInt(process.env.MAX_TX_PER_BATCH || '500'),
    maxBatchSize: parseInt(process.env.MAX_BATCH_SIZE || '131072'),
    batchIntervalMs: parseInt(process.env.BATCH_INTERVAL_MS || '3000'),
    maxPerSender: parseInt(process.env.MAX_PER_SENDER || '10'),
    
    // Economics
    minGasPrice: BigInt(process.env.MIN_GAS_PRICE || '1000000000'),
    baseFeeMultiplier: parseFloat(process.env.BASE_FEE_MULTIPLIER || '2'),
    escalationRate: parseFloat(process.env.ESCALATION_RATE || '1.125'),
    
    // Operational
    maxPendingTxs: parseInt(process.env.MAX_PENDING_TXS || '10000'),
    dbPath: process.env.DB_PATH || './data/sequencer.db',
    port: parseInt(process.env.PORT || '8547'),
    logLevel: process.env.LOG_LEVEL || 'info',
    
    // Monitoring
    metricsEnabled: process.env.METRICS_ENABLED === 'true',
    metricsPort: parseInt(process.env.METRICS_PORT || '9090')
  };
  
  // Validate required config
  if (!config.privateKey || config.privateKey === '0x') {
    throw new Error('PRIVATE_KEY is required');
  }
  
  if (!config.l1RpcUrl) {
    throw new Error('L1_RPC_URL is required');
  }
  
  return config;
}