// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import "../src/DABuilder/TrustlessProposer.sol";

interface IGasTank {
    function deposit() external payable;
    function deposit(address operator) external payable;
    function balances(address operator) external view returns (uint256);
}

contract DABuilderSetup is Script {
    // Holesky addresses from DA Builder docs
    address constant GAS_TANK = 0x18Fa15ea0A34a7c4BCA01bf7263b2a9Ac0D32e92;
    address constant PROPOSER_MULTICALL = 0x5132dCe9aD675b2ac5E37D69D2bC7399764b5469;
    
    // Deposit amount (0.1 ETH)
    uint256 constant DEPOSIT_AMOUNT = 0.1 ether;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deployer address:", deployer);
        console.log("Deployer balance:", deployer.balance);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Step 1: Deploy TrustlessProposer
        console.log("\n1. Deploying TrustlessProposer...");
        TrustlessProposer proposer = new TrustlessProposer(PROPOSER_MULTICALL);
        address proposerAddress = address(proposer);
        console.log("   TrustlessProposer deployed at:", proposerAddress);
        
        // Step 2: Setup EIP-7702 authorization
        console.log("\n2. Setting up EIP-7702 authorization...");
        console.log("   Run this command after deployment:");
        console.log("   cast send --private-key $PRIVATE_KEY \\");
        console.log("     --rpc-url $L1_RPC \\");
        console.log("     --auth", proposerAddress, "\\");
        console.log("     ", deployer, "''");
        console.log("\n   This sets EIP-7702 delegation from your EOA to the TrustlessProposer");
        
        // Step 3: Fund Gas Tank
        console.log("\n3. Funding Gas Tank...");
        IGasTank gasTank = IGasTank(GAS_TANK);
        gasTank.deposit{value: DEPOSIT_AMOUNT}();  // Deposits for msg.sender (deployer)
        
        uint256 balance = gasTank.balances(deployer);
        console.log("   Deposited:", DEPOSIT_AMOUNT);
        console.log("   Gas Tank balance:", balance);
        
        vm.stopBroadcast();
        
        // Output summary
        console.log("\n========================================");
        console.log("DA Builder Setup Complete!");
        console.log("========================================");
        console.log("TrustlessProposer:", proposerAddress);
        console.log("EOA Address:", deployer);
        console.log("Gas Tank Balance:", balance);
        console.log("\nNEXT STEPS:");
        console.log("1. Set EIP-7702 authorization (see command above)");
        console.log("2. Verify with: cast code", deployer);
        console.log("   Should return: 0xef0100...<proposer_address>");
        console.log("3. Update .env with PROPOSER_ADDRESS=", proposerAddress);
    }
}