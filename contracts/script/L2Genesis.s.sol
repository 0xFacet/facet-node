// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 as console } from "forge-std/console2.sol";
import "solady/src/utils/LibString.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { ERC20PublicMintGenesis } from "./ERC20PublicMintGenesis.s.sol";

contract L2Genesis is Script {
    using LibString for *;
    using stdJson for string;

    uint256 public constant PRECOMPILE_COUNT = 256;
    address internal deployer;
    
    struct PredeployContract {
        address addr;
        string name;
    }
    
    struct PredeployContractList {
        PredeployContract[] contracts;
    }

    PredeployContractList internal predeployContracts;

    ERC20PublicMintGenesis public erc20Generator;

    function setUp() public {
        deployer = makeAddr("deployer");
        erc20Generator = new ERC20PublicMintGenesis();
        // populatePredeployContracts();
    }

    function run() public {
        vm.startPrank(deployer);
        
        etchContracts();
        generateAllGenesis();
        vm.stopPrank();
        
        vm.etch(msg.sender, "");
        vm.resetNonce(msg.sender);
        vm.deal(msg.sender, 0);

        vm.deal(deployer, 0);
        vm.resetNonce(deployer);

        console.log("Writing state dump to: facet-local-genesis-allocs.json");
        
        vm.dumpState("facet-local-genesis-allocs.json");
        
        // Write predeployContracts to JSON
        writePredeployContractsToJson();
    }
    
    function generateAllGenesis() internal {
        // Generate ERC20 genesis
        erc20Generator.generateERC20Genesis("script/erc20_state_test.json");
        
        // Add calls to other genesis generators here as needed
        // For example:
        // bridgeGenesisGenerator.generateBridgeGenesis("script/bridge_state.json");
        // swapGenesisGenerator.generateSwapGenesis("script/swap_state.json");
    }
    
    function etchContracts() internal {
        console.log("Etching contracts");
        for (uint i = 0; i < predeployContracts.contracts.length; i++) {
            string memory name = predeployContracts.contracts[i].name;
            address addr = predeployContracts.contracts[i].addr;
            
            etchContract(name, addr);
        }
    }
    
    function isDeployedByContract(string memory contractName) internal pure returns (bool) {
        return contractName.startsWith("ERC20Bridge") ||
               contractName.startsWith("FacetBuddy") ||
               contractName.startsWith("FacetSwapPair");
    }

    function etchContract(string memory contractName, address addr) internal {
        string memory artifactPath = string(abi.encodePacked("predeploys/", contractName, ".sol:", contractName));
        bytes memory bytecode = vm.getDeployedCode(artifactPath);
        vm.etch(addr, bytecode);
        
        if (vm.getNonce(addr) == 0) {
            vm.setNonce(addr, 1);
        }
        
        disableInitializableSlot(addr);
        
        console.log("Etched", contractName, "at", vm.toString(addr));
    }
    
    function disableInitializableSlot(address addr) internal {
        bytes32 slot = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffbf601132;
        uint256 maxUint64 = type(uint64).max;
        uint256 value = maxUint64 << 1;
        bytes32 valueBytes = bytes32(value);
        vm.store(addr, slot, valueBytes);
    }
    
    function populatePredeployContracts() internal {
        string[] memory inputs = new string[](3);
        inputs[0] = "bash";
        inputs[1] = "-c";
        inputs[2] = "bundle exec rails runner 'puts ({contracts: PredeployManager.predeploy_to_local_map.invert.map { |name, addr| {name: name, addr: addr} } }.to_json)' | tail -n 1";
        bytes memory result = vm.ffi(inputs);
        string memory json = string(result);
        
        // Parse the JSON and populate the struct
        bytes memory parsedJson = vm.parseJson(json);
        predeployContracts = abi.decode(parsedJson, (PredeployContractList));
        
        PredeployContract[] memory derivedContracts = new PredeployContract[](predeployContracts.contracts.length);
        uint256 derivedCount = 0;

        for (uint i = 0; i < predeployContracts.contracts.length; i++) {
            string memory name = predeployContracts.contracts[i].name;
            address addr = predeployContracts.contracts[i].addr;
            
            if (isDeployedByContract(name)) {
                console.log("Deployed by contract:", name);
                string memory artifactPath = string(abi.encodePacked("predeploys/", name, ".sol:", name));
                bytes memory creationCode = vm.getCode(artifactPath);
                bytes32 initCodeHash = keccak256(creationCode);
                address derivedAddress = address(uint160(uint256(initCodeHash)));
                derivedContracts[derivedCount] = PredeployContract({name: name, addr: derivedAddress});
                derivedCount++;
            }
        }

        // Add derived contracts to predeployContracts
        for (uint i = 0; i < derivedCount; i++) {
            predeployContracts.contracts.push(derivedContracts[i]);
        }
    }

    function writePredeployContractsToJson() internal {
        string memory jsonPath = "predeploy-contracts.json";
        string memory json = "["; // Start with an opening bracket

        for (uint i = 0; i < predeployContracts.contracts.length; i++) {
            PredeployContract memory c = predeployContracts.contracts[i];
            
            // Create a JSON object for each contract
            string memory contractJson = string(abi.encodePacked(
                '{"name":"', c.name, '","addr":"', c.addr.toHexString(), '"}'
            ));

            // Add comma if it's not the first element
            if (i > 0) {
                json = string(abi.encodePacked(json, ","));
            }

            // Append the contract object to the array
            json = string(abi.encodePacked(json, contractJson));
        }

        // Close the array
        json = string(abi.encodePacked(json, "]"));

        // Write the final JSON array to the file
        vm.writeFile(jsonPath, json);

        console.log("Wrote predeploy contracts to:", jsonPath);
    }
}
