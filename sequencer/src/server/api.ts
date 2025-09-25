import Fastify, { type FastifyInstance, type FastifyRequest } from 'fastify';
import cors from '@fastify/cors';
import { IngressServer } from './ingress.js';
import type { DatabaseService } from '../db/schema.js';
import { logger } from '../utils/logger.js';
import type { Config } from '../config/config.js';
import type { Hex } from 'viem';

interface JsonRpcRequest {
  jsonrpc: string;
  method: string;
  params: any[];
  id: number | string;
}

export class SequencerAPI {
  private app: FastifyInstance;
  private ingress: IngressServer;
  private l2RpcUrl: string;

  constructor(
    private db: DatabaseService,
    private config: Config
  ) {
    this.app = Fastify({
      logger: false
    });

    this.ingress = new IngressServer(db);
    this.l2RpcUrl = config.l2RpcUrl;
    this.setupEndpoints();
  }
  
  private setupEndpoints(): void {
    // Enable CORS
    this.app.register(cors, {
      origin: true
    });
    
    // Main JSON-RPC endpoint
    this.app.post('/', async (req: FastifyRequest<{ Body: JsonRpcRequest }>, reply) => {
      const { method, params, id } = req.body;
      
      try {
        switch (method) {
          case 'eth_sendRawTransaction': {
            const hash = await this.ingress.handleTransaction(params[0] as Hex);
            reply.send({ jsonrpc: '2.0', result: hash, id });
            break;
          }

          case 'sequencer_getTxStatus': {
            const status = await this.ingress.getTransactionStatus(params[0] as Hex);
            reply.send({ jsonrpc: '2.0', result: status, id });
            break;
          }
          
          case 'sequencer_getStats': {
            const stats = await this.getStats();
            reply.send({ jsonrpc: '2.0', result: stats, id });
            break;
          }

          default:
            // Proxy unknown methods to L2 RPC
            const proxyResult = await this.proxyToL2(method, params, id);
            reply.send(proxyResult);
        }
      } catch (error: any) {
        logger.error({ method, error: error.message }, 'RPC error');
        reply.code(500).send({
          jsonrpc: '2.0',
          error: { code: -32000, message: error.message },
          id
        });
      }
    });
    
    // Health check endpoint
    this.app.get('/health', async (req, reply) => {
      const health = await this.checkHealth();
      reply.code(health.healthy ? 200 : 503).send(health);
    });
    
    // Metrics endpoint
    this.app.get('/metrics', async (req, reply) => {
      const metrics = await this.getMetrics();
      reply.type('text/plain').send(metrics);
    });
  }
  
  async start(): Promise<void> {
    try {
      await this.app.listen({ 
        port: this.config.port,
        host: '0.0.0.0'
      });
      logger.info({ port: this.config.port }, 'API server started');
    } catch (error) {
      logger.error(error, 'Failed to start API server');
      throw error;
    }
  }
  
  async stop(): Promise<void> {
    await this.app.close();
  }

  private async proxyToL2(method: string, params: any[], id: number | string): Promise<any> {
    try {
      // Forward the exact RPC request to L2
      const response = await fetch(this.l2RpcUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          jsonrpc: '2.0',
          method,
          params,
          id
        })
      });

      const result = await response.json();

      // Log proxied methods for debugging (but not too verbose)
      if (!['eth_getBlockByNumber', 'eth_blockNumber', 'eth_getBalance'].includes(method)) {
        logger.debug({ method, proxiedTo: this.l2RpcUrl }, 'Proxied RPC method');
      }

      return result;
    } catch (error: any) {
      logger.error({ method, error: error.message }, 'Proxy to L2 failed');
      return {
        jsonrpc: '2.0',
        error: {
          code: -32000,
          message: `Proxy error: ${error.message}`
        },
        id
      };
    }
  }
  
  private async checkHealth(): Promise<any> {
    const database = this.db.getDatabase();
    
    const stats = database.prepare(`
      SELECT 
        (SELECT COUNT(*) FROM transactions WHERE state IN ('queued', 'requeued')) as queued,
        (SELECT COUNT(*) FROM batches WHERE state IN ('sealed', 'submitted')) as pending_batches,
        (SELECT MAX(confirmed_at) FROM post_attempts WHERE status = 'mined') as last_confirmation
    `).get() as any;
    
    const now = Date.now();
    const healthy = 
      stats.queued < this.config.maxPendingTxs &&
      (!stats.last_confirmation || (now - stats.last_confirmation) < 300000);
    
    return {
      healthy,
      uptime: process.uptime(),
      queuedTxs: stats.queued,
      pendingBatches: stats.pending_batches,
      lastL1Confirmation: stats.last_confirmation
    };
  }
  
  private async getStats(): Promise<any> {
    const database = this.db.getDatabase();
    
    return database.prepare(`
      SELECT 
        (SELECT COUNT(*) FROM transactions WHERE state = 'queued') as queued_txs,
        (SELECT COUNT(*) FROM transactions WHERE state = 'l2_included') as included_txs,
        (SELECT COUNT(*) FROM transactions WHERE state = 'dropped') as dropped_txs,
        (SELECT COUNT(*) FROM batches WHERE state = 'l1_included') as confirmed_batches,
        (SELECT COUNT(*) FROM batches WHERE state = 'sealed') as pending_batches
    `).get();
  }
  
  private async getMetrics(): Promise<string> {
    const stats = await this.getStats();
    
    // Prometheus format
    return `
# HELP sequencer_queued_txs Number of queued transactions
# TYPE sequencer_queued_txs gauge
sequencer_queued_txs ${stats.queued_txs}

# HELP sequencer_included_txs_total Total included transactions
# TYPE sequencer_included_txs_total counter
sequencer_included_txs_total ${stats.included_txs}

# HELP sequencer_dropped_txs_total Total dropped transactions  
# TYPE sequencer_dropped_txs_total counter
sequencer_dropped_txs_total ${stats.dropped_txs}

# HELP sequencer_confirmed_batches_total Total confirmed batches
# TYPE sequencer_confirmed_batches_total counter
sequencer_confirmed_batches_total ${stats.confirmed_batches}

# HELP sequencer_pending_batches Number of pending batches
# TYPE sequencer_pending_batches gauge
sequencer_pending_batches ${stats.pending_batches}
`.trim();
  }
}