// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 as console } from "forge-std/console2.sol";
import "solady/src/utils/LibString.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { EtherBridgeVd58 } from "src/predeploys/EtherBridgeVd58.sol";
import { FacetERC20 } from "src/libraries/FacetERC20.sol";

contract MintableERC20 is FacetERC20 {
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract EtherBridgeGenesisGenerator is Script {
    struct Balance {
        address account;
        uint256 amount;
    }

    struct Allowance {
        uint256 amount;
        address owner;
        address spender;
    }
    
    struct WithdrawalIdAmount {
        bytes32 withdrawalId;
        uint256 amount;
    }

    struct UserWithdrawalId {
        address user;
        bytes32 withdrawalId;
    }

    struct EtherBridgeState {
        Allowance[] allowance;
        Balance[] balanceOf;
        uint8 decimals;
        string name;
        string symbol;
        uint256 totalSupply;
        address trustedSmartContract;
        WithdrawalIdAmount[] withdrawalIdAmounts;
        UserWithdrawalId[] userWithdrawalIds;
        uint256 withdrawalIdNonce;
        address bridgeAndCallHelper;
        address facetBuddyFactory;
        address upgradeAdmin;
        address owner;
    }

    struct EtherBridgeDeployment {
        address contractAddress;
        EtherBridgeState state;
    }
    
    struct EtherBridgeDeploymentSet {
        EtherBridgeDeployment[] deployments;
    }

    function generateEtherBridgeGenesis(string memory filename) public {
        string memory json = vm.readFile(filename);
        bytes memory data = vm.parseJson(json);
        EtherBridgeDeploymentSet memory deploymentSet = abi.decode(data, (EtherBridgeDeploymentSet));

        for (uint i = 0; i < deploymentSet.deployments.length; i++) {
            setEtherBridgeValuesForContract(deploymentSet.deployments[i]);
        }
    }

    function setEtherBridgeValuesForContract(EtherBridgeDeployment memory deployment) internal {
        address bridgeAddr = deployment.contractAddress;
        EtherBridgeState memory state = deployment.state;

        vm.etch(bridgeAddr, type(EtherBridgeVd58).runtimeCode);
        EtherBridgeVd58 bridge = EtherBridgeVd58(bridgeAddr);

        // Initialize the bridge
        bridge.initialize(
            state.name,
            state.symbol,
            state.trustedSmartContract
        );
        
        address finalOwner = state.owner;
        address finalUpgradeAdmin = state.upgradeAdmin;
        
        setBalances(bridgeAddr, state.balanceOf);
        setAllowances(bridgeAddr, state.allowance);
        
        // Set additional EtherBridge state
        setEtherBridgeAdditionalState(bridge, state);

        vm.etch(bridgeAddr, type(EtherBridgeVd58).runtimeCode);

        testEtherBridge(bridge, state);
    }
    
    function setBalances(address dummyAddr, Balance[] memory balances) internal {
        vm.etch(dummyAddr, type(MintableERC20).runtimeCode);
        
        for (uint i = 0; i < balances.length; i++) {
            MintableERC20(dummyAddr).mint(balances[i].account, balances[i].amount);
        }
    }

    function setAllowances(address dummyAddr, Allowance[] memory allowances) internal {
        MintableERC20 dummy = MintableERC20(dummyAddr);
        
        for (uint i = 0; i < allowances.length; i++) {
            vm.startPrank(allowances[i].owner);
            dummy.approve(allowances[i].spender, allowances[i].amount);
            vm.stopPrank();
        }
    }

    function setEtherBridgeAdditionalState(EtherBridgeVd58 bridge, EtherBridgeState memory state) internal {
        // Set facetBuddyFactory
        vm.prank(bridge.owner());
        bridge.setFacetBuddyFactory(state.facetBuddyFactory);

        // Set withdrawalIdAmount
        bytes32[] memory withdrawalIds = getWithdrawalIds(state);
        for (uint i = 0; i < withdrawalIds.length; i++) {
            bytes32 withdrawalId = withdrawalIds[i];
            uint256 amount = state.withdrawalIdAmount[withdrawalId];
            vm.store(
                address(bridge),
                keccak256(abi.encode(withdrawalId, keccak256("BridgeStorage.contract.storage.v1"))),
                bytes32(amount)
            );
        }

        // Set userWithdrawalId
        address[] memory users = getUsers(state);
        for (uint i = 0; i < users.length; i++) {
            address user = users[i];
            bytes32 withdrawalId = state.userWithdrawalId[user];
            vm.store(
                address(bridge),
                keccak256(abi.encode(user, keccak256("BridgeStorage.contract.storage.v1"))),
                withdrawalId
            );
        }

        // Set withdrawalIdNonce
        vm.store(
            address(bridge),
            bytes32(uint256(keccak256("BridgeStorage.contract.storage.v1")) + 2),
            bytes32(state.withdrawalIdNonce)
        );

        // Set bridgeAndCallHelper
        vm.store(
            address(bridge),
            bytes32(uint256(keccak256("BridgeStorage.contract.storage.v1")) + 3),
            bytes32(uint256(uint160(state.bridgeAndCallHelper)))
        );
    }

    function testEtherBridge(EtherBridgeVd58 bridge, EtherBridgeState memory state) internal view {
        require(bridge.getTrustedSmartContract() == state.trustedSmartContract, "Incorrect trustedSmartContract");
        require(bridge.getFacetBuddyFactory() == state.facetBuddyFactory, "Incorrect facetBuddyFactory");
        require(bridge.getWithdrawalIdNonce() == state.withdrawalIdNonce, "Incorrect withdrawalIdNonce");
        require(bridge.getBridgeAndCallHelper() == state.bridgeAndCallHelper, "Incorrect bridgeAndCallHelper");

        // Test some withdrawalIdAmount and userWithdrawalId
        bytes32[] memory withdrawalIds = getWithdrawalIds(state);
        address[] memory users = getUsers(state);

        if (withdrawalIds.length > 0) {
            bytes32 randomWithdrawalId = withdrawalIds[uint256(keccak256(abi.encodePacked(block.timestamp, "withdrawalId"))) % withdrawalIds.length];
            require(bridge.getWithdrawalIdAmount(randomWithdrawalId) == state.withdrawalIdAmount[randomWithdrawalId], "Incorrect withdrawalIdAmount");
        }

        if (users.length > 0) {
            address randomUser = users[uint256(keccak256(abi.encodePacked(block.timestamp, "user"))) % users.length];
            require(bridge.getUserWithdrawalId(randomUser) == state.userWithdrawalId[randomUser], "Incorrect userWithdrawalId");
        }

        console.log("All EtherBridge tests passed for contract at address:", address(bridge));
    }

    // Helper functions to get keys from mappings (you'll need to implement these based on how you store the mapping data in your JSON)
    function getWithdrawalIds(EtherBridgeState memory state) internal pure returns (bytes32[] memory) {
        // Implementation depends on how you store this data in your JSON
    }

    function getUsers(EtherBridgeState memory state) internal pure returns (address[] memory) {
        // Implementation depends on how you store this data in your JSON
    }
}
