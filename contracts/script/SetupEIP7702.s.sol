// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";

contract SetupEIP7702 is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address proposerAddress = vm.envAddress("PROPOSER_ADDRESS");
        
        console.log("Setting up EIP-7702 for EOA:", deployer);
        console.log("Delegating to TrustlessProposer:", proposerAddress);
        
        // Get current nonce
        uint256 currentNonce = vm.getNonce(deployer);
        uint256 authNonce = currentNonce + 1; // Critical: auth nonce = tx nonce + 1
        
        console.log("Current nonce:", currentNonce);
        console.log("Authorization nonce:", authNonce);
        
        // Note: Foundry doesn't have native EIP-7702 support yet
        // This script outputs the command to run with cast
        
        console.log("\n========================================");
        console.log("Run this command to set EIP-7702:");
        console.log("========================================\n");
        
        console.log("# First, create the authorization signature");
        console.log("# The authorization format is: chainId || nonce || address");
        console.log("# For Holesky (chain 17000):");
        console.log("");
        console.log("export PROPOSER_ADDRESS=", proposerAddress);
        console.log("export AUTH_NONCE=", authNonce);
        console.log("");
        console.log("# This is a placeholder - actual EIP-7702 signing needs special tooling");
        console.log("# Most wallets don't support it yet, may need custom implementation");
        console.log("");
        console.log("# After setting authorization, verify with:");
        console.log("cast code", deployer, "--rpc-url $L1_RPC");
        console.log("# Expected: 0xef0100", proposerAddress, "(without 0x prefix)");
    }
}