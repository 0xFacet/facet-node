# Facet Micro-Sequencer

A lightweight, permissionless TypeScript sequencer for Facet L2 transactions.

## Features

- **EIP-1559 Transaction Support**: Only accepts properly formatted EIP-1559 transactions
- **Smart Batching**: Dynamic batch creation based on size, count, and time thresholds
- **RBF Support**: Automatic fee escalation for stuck transactions
- **L1/L2 Monitoring**: Tracks transaction inclusion across both layers
- **Reorg Handling**: Automatically detects and handles L1 reorgs
- **SQLite Storage**: Simple, embedded database with WAL mode for performance
- **Prometheus Metrics**: Built-in metrics endpoint for monitoring

## Quick Start

### Development

```bash
# Install dependencies
npm install

# Copy and configure environment
cp .env.example .env
# Edit .env with your configuration

# Run in development mode
npm run dev
```

### Production

```bash
# Build
npm run build

# Run
npm start
```

### Docker

```bash
# Build image
docker build -t facet-sequencer .

# Run container
docker run -d \
  --name facet-sequencer \
  -p 8547:8547 \
  -p 9090:9090 \
  -v $(pwd)/data:/data \
  -v $(pwd)/.env:/app/.env:ro \
  facet-sequencer
```

## Configuration

All configuration is done via environment variables:

```env
# L1 Connection (required)
L1_RPC_URL=https://holesky.infura.io/v3/YOUR_KEY
PRIVATE_KEY=0x...  # Private key for L1 transactions

# L2 Connection
L2_RPC_URL=http://localhost:8545  # Your Facet node RPC

# Batching
MAX_TX_PER_BATCH=500
BATCH_INTERVAL_MS=3000  # Create batch every 3 seconds if transactions pending

# Economics
MIN_GAS_PRICE=1000000000  # 1 gwei minimum
```

## API Endpoints

### JSON-RPC

- `eth_sendRawTransaction` - Submit a transaction
- `eth_chainId` - Get the L2 chain ID
- `sequencer_getTxStatus` - Get detailed transaction status
- `sequencer_getStats` - Get sequencer statistics

### HTTP

- `GET /health` - Health check endpoint
- `GET /metrics` - Prometheus metrics

## Transaction Lifecycle

1. **Queued**: Transaction received and validated
2. **Batched**: Included in a batch
3. **Submitted**: Batch sent to L1
4. **L1 Included**: Batch confirmed on L1
5. **L2 Included**: Transaction executed on L2

## Database Schema

The sequencer uses SQLite with the following main tables:

- `transactions`: Transaction pool and state tracking
- `batches`: Batch creation and L1 submission tracking
- `batch_items`: Transaction ordering within batches
- `post_attempts`: L1 submission attempts with RBF chain

## Monitoring

The sequencer exposes Prometheus metrics on port 9090:

- `sequencer_queued_txs`: Current queued transactions
- `sequencer_included_txs_total`: Total included transactions
- `sequencer_confirmed_batches_total`: Total L1 confirmed batches
- `sequencer_pending_batches`: Current pending batches

## Development

```bash
# Run tests
npm test

# Type checking
npm run typecheck

# Linting
npm run lint

# Database migrations
npm run migrate
```

## Architecture

```
┌─────────────┐  eth_sendRawTransaction
│  HTTP RPC   │◄──────── users
└────┬────────┘
     ▼
┌─────────────┐  
│   Ingress   │  validates and stores
└────┬────────┘
     ▼
┌─────────────┐  
│ BatchMaker  │  creates Facet batches
└────┬────────┘
     ▼
┌─────────────┐  
│   Poster    │  submits to L1 with RBF
└────┬────────┘
     ▼
┌──────────────┐
│   Monitor    │  tracks inclusion
└──────────────┘
```

## Security

- Private keys are never logged
- Transactions are validated before acceptance
- Sender fairness prevents monopolization
- Database uses WAL mode for consistency

## License

MIT