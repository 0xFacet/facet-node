#!/usr/bin/env tsx

import Database from 'better-sqlite3';
import { resolve } from 'path';

const DB_PATH = process.env.DB_PATH || './data/sequencer.db';

function inspectDatabase() {
  console.log('🔍 Inspecting Sequencer Database\n');
  console.log('📁 Database path:', resolve(DB_PATH), '\n');
  
  const db = new Database(DB_PATH, { readonly: true });
  
  try {
    // Get transaction count by state
    console.log('📊 Transaction Statistics:');
    const txStats = db.prepare(`
      SELECT state, COUNT(*) as count 
      FROM transactions 
      GROUP BY state
    `).all();
    
    for (const stat of txStats) {
      console.log(`   ${stat.state}: ${stat.count}`);
    }
    
    // Get recent transactions
    console.log('\n📜 Recent Transactions (last 5):');
    const recentTxs = db.prepare(`
      SELECT 
        '0x' || hex(hash) as hash,
        '0x' || hex(from_address) as from_address,
        nonce,
        max_fee_per_gas,
        state,
        datetime(received_at/1000, 'unixepoch') as received_at
      FROM transactions 
      ORDER BY received_seq DESC 
      LIMIT 5
    `).all();
    
    for (const tx of recentTxs) {
      console.log(`\n   Hash: ${tx.hash}`);
      console.log(`   From: ${tx.from_address}`);
      console.log(`   Nonce: ${tx.nonce}`);
      console.log(`   Max Fee: ${tx.max_fee_per_gas} wei`);
      console.log(`   State: ${tx.state}`);
      console.log(`   Received: ${tx.received_at}`);
    }
    
    // Get batch statistics
    console.log('\n📦 Batch Statistics:');
    const batchStats = db.prepare(`
      SELECT state, COUNT(*) as count 
      FROM batches 
      GROUP BY state
    `).all();
    
    if (batchStats.length === 0) {
      console.log('   No batches created yet');
    } else {
      for (const stat of batchStats) {
        console.log(`   ${stat.state}: ${stat.count}`);
      }
    }
    
    // Get recent batches
    const recentBatches = db.prepare(`
      SELECT 
        id,
        '0x' || hex(content_hash) as content_hash,
        state,
        tx_count,
        blob_size,
        datetime(sealed_at/1000, 'unixepoch') as sealed_at
      FROM batches 
      ORDER BY id DESC 
      LIMIT 3
    `).all();
    
    if (recentBatches.length > 0) {
      console.log('\n📦 Recent Batches:');
      for (const batch of recentBatches) {
        console.log(`\n   Batch #${batch.id}`);
        console.log(`   Content Hash: ${batch.content_hash}`);
        console.log(`   State: ${batch.state}`);
        console.log(`   Transactions: ${batch.tx_count}`);
        console.log(`   Size: ${batch.blob_size} bytes`);
        console.log(`   Sealed: ${batch.sealed_at || 'Not sealed'}`);
      }
    }
    
    // Show raw SQL query option
    console.log('\n💡 Tip: You can also query directly with:');
    console.log(`   sqlite3 ${DB_PATH} "SELECT * FROM transactions;"`);
    
  } catch (error: any) {
    console.error('❌ Error reading database:', error.message);
  } finally {
    db.close();
  }
}

// Run inspection
inspectDatabase();