import { DatabaseService } from './db/schema.js';
import { SequencerAPI } from './server/api.js';
import { BatchMaker } from './batch/maker.js';
import type { Poster } from './l1/poster-interface.js';
import { DirectPoster } from './l1/direct-poster.js';
import { DABuilderPoster } from './l1/da-builder-poster.js';
import { InclusionMonitor } from './l1/monitor.js';
import { loadConfig } from './config/config.js';
import { logger } from './utils/logger.js';
import { defineChain, createPublicClient, http } from 'viem';
import { holesky, mainnet } from 'viem/chains';
import { mkdir } from 'fs/promises';
import { dirname } from 'path';

class Sequencer {
  private db!: DatabaseService;
  private api!: SequencerAPI;
  private batchMaker!: BatchMaker;
  private poster!: Poster;
  private monitor!: InclusionMonitor;
  private config = loadConfig();
  private isRunning = false;
  private batchInterval?: NodeJS.Timeout;
  private posterInterval?: NodeJS.Timeout;
  
  async init(): Promise<void> {
    logger.info('Initializing sequencer...');
    
    // Ensure data directory exists
    await mkdir(dirname(this.config.dbPath), { recursive: true });
    
    // Initialize database
    this.db = new DatabaseService(this.config.dbPath);
    
    // Determine L1 chain
    let l1Chain;
    if (this.config.l1ChainId === 1) {
      l1Chain = mainnet;
    } else if (this.config.l1ChainId === 17000) {
      l1Chain = holesky;
    } else if (this.config.l1ChainId === 560048) {
      // Define Hoodi chain
      l1Chain = defineChain({
        id: 560048,
        name: 'Hoodi',
        nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
        rpcUrls: {
          default: { http: [this.config.l1RpcUrl] }
        }
      });
    } else {
      // Define custom chain
      l1Chain = defineChain({
        id: this.config.l1ChainId,
        name: 'Custom L1',
        nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
        rpcUrls: {
          default: { http: [this.config.l1RpcUrl] }
        }
      });
    }
    
    // Define L2 chain
    const l2Chain = defineChain({
      id: parseInt(this.config.l2ChainId, 16),
      name: 'Facet',
      nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
      rpcUrls: {
        default: { http: [this.config.l2RpcUrl] }
      }
    });
    
    // Create L1 public client for BatchMaker
    const l1PublicClient = createPublicClient({
      chain: l1Chain,
      transport: http(this.config.l1RpcUrl)
    });

    // Initialize components
    this.api = new SequencerAPI(this.db, this.config);
    this.batchMaker = new BatchMaker(
      this.db,
      l1PublicClient,
      this.config.l2ChainId
    );

    // Select poster implementation based on config
    if (this.config.useDABuilder) {
      logger.info('Using DA Builder poster');
      this.poster = new DABuilderPoster(
        this.db,
        l1Chain,
        this.config.privateKey,
        this.config.l1RpcUrl,
        this.config.daBuilderUrl!,
        this.config.proposerAddress!
      );
    } else {
      logger.info('Using direct poster');
      this.poster = new DirectPoster(
        this.db,
        l1Chain,
        this.config.privateKey,
        this.config.l1RpcUrl
      );
    }
    this.monitor = new InclusionMonitor(
      this.db,
      this.config.l1RpcUrl,
      this.config.l2RpcUrl,
      l1Chain,
      l2Chain
    );
    
    logger.info('Sequencer initialized');
  }
  
  async start(): Promise<void> {
    if (this.isRunning) return;
    this.isRunning = true;
    
    logger.info('Starting sequencer...');
    
    // Start API server
    await this.api.start();
    
    // Start inclusion monitor
    await this.monitor.start();
    
    // Start batch creation loop
    this.batchInterval = setInterval(async () => {
      try {
        if (await this.batchMaker.shouldCreateBatch()) {
          const batchId = await this.batchMaker.createBatch();
          if (batchId) {
            logger.info({ batchId }, 'Created new batch');
            // Post immediately
            await this.poster.postBatch(batchId);
          }
        }
      } catch (error: any) {
        logger.error({ error: error.message }, 'Error in batch creation loop');
      }
    }, this.config.batchIntervalMs);
    
    // Start poster check loop (for RBF)
    this.posterInterval = setInterval(async () => {
      try {
        await this.poster.checkPendingTransaction();
        
        // Also check for any sealed batches that need posting
        const database = this.db.getDatabase();
        const sealedBatches = database.prepare(
          'SELECT id FROM batches WHERE state = ? LIMIT 1'
        ).all('sealed') as Array<{ id: number }>;
        
        for (const batch of sealedBatches) {
          await this.poster.postBatch(batch.id);
        }
      } catch (error: any) {
        logger.error({ error: error.message }, 'Error in poster check loop');
      }
    }, 10000); // Check every 10 seconds
    
    logger.info('Sequencer started successfully');
    
    // Log initial stats
    const stats = await this.getStats();
    logger.info(stats, 'Initial stats');
  }
  
  async stop(): Promise<void> {
    if (!this.isRunning) return;
    
    logger.info('Stopping sequencer...');
    
    // Stop intervals
    if (this.batchInterval) clearInterval(this.batchInterval);
    if (this.posterInterval) clearInterval(this.posterInterval);
    
    // Stop API
    await this.api.stop();
    
    // Close database
    this.db.close();
    
    this.isRunning = false;
    logger.info('Sequencer stopped');
  }
  
  private async getStats(): Promise<any> {
    const database = this.db.getDatabase();
    return database.prepare(`
      SELECT 
        (SELECT COUNT(*) FROM transactions) as total_txs,
        (SELECT COUNT(*) FROM transactions WHERE state = 'queued') as queued_txs,
        (SELECT COUNT(*) FROM batches) as total_batches,
        (SELECT COUNT(*) FROM batches WHERE state = 'l1_included') as confirmed_batches
    `).get();
  }
}

// Main entry point
async function main() {
  const sequencer = new Sequencer();
  
  try {
    await sequencer.init();
    await sequencer.start();
    
    // Handle graceful shutdown
    process.on('SIGINT', async () => {
      logger.info('Received SIGINT, shutting down gracefully...');
      await sequencer.stop();
      process.exit(0);
    });
    
    process.on('SIGTERM', async () => {
      logger.info('Received SIGTERM, shutting down gracefully...');
      await sequencer.stop();
      process.exit(0);
    });
    
  } catch (error: any) {
    logger.error({ error: error.message }, 'Failed to start sequencer');
    process.exit(1);
  }
}

// Run if this is the main module
if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch(console.error);
}

export { Sequencer };