// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 as console } from "forge-std/console2.sol";
import "solady/src/utils/LibString.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { PublicMintERC20Vc88 } from "src/predeploys/PublicMintERC20Vc88.sol";

contract MintableERC20 is PublicMintERC20Vc88 {
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract ERC20PublicMintGenesis is Script {
    using LibString for *;
    using stdJson for string;

    struct Balance {
        address account;
        uint256 amount;
    }

    struct Allowance {
        uint256 amount;
        address owner;
        address spender;
    }

    struct ERC20State {
        Allowance[] allowance;
        Balance[] balanceOf;
        uint8 decimals;
        uint256 maxSupply;
        string name;
        uint256 perMintLimit;
        string symbol;
        uint256 totalSupply;
    }

    struct ERC20Deployment {
        address contractAddress;
        ERC20State state;
    }
    
    struct ERC20DeploymentSet {
        ERC20Deployment[] deployments;
    }

    function generateERC20Genesis(string memory filename) public {
        string memory json = vm.readFile(filename);
        bytes memory data = vm.parseJson(json);
        ERC20DeploymentSet memory deploymentSet = abi.decode(data, (ERC20DeploymentSet));

        for (uint i = 0; i < deploymentSet.deployments.length; i++) {
            setERC20ValuesForContract(deploymentSet.deployments[i]);
        }
    }

    function setERC20ValuesForContract(ERC20Deployment memory deployment) internal {
        address dummyAddr = deployment.contractAddress;
        ERC20State memory state = deployment.state;

        vm.etch(dummyAddr, type(PublicMintERC20Vc88).runtimeCode);
        PublicMintERC20Vc88 dummy = PublicMintERC20Vc88(dummyAddr);

        dummy.initialize(state.name, state.symbol, state.maxSupply, state.perMintLimit, state.decimals);

        setBalances(dummy, state.balanceOf);
        setAllowances(dummy, state.allowance);

        require(state.totalSupply == dummy.totalSupply(), "Total supply mismatch");
        
        vm.setNonce(dummyAddr, 1);
        vm.deal(dummyAddr, 0);
        
        testDummyERC20(dummy, state);
    }

    function setBalances(PublicMintERC20Vc88 dummy, Balance[] memory balances) internal {
        address dummyAddr = address(dummy);
        vm.etch(dummyAddr, type(MintableERC20).runtimeCode);
        
        for (uint i = 0; i < balances.length; i++) {
            MintableERC20(dummyAddr).mint(balances[i].account, balances[i].amount);
        }
        
        vm.etch(dummyAddr, type(PublicMintERC20Vc88).runtimeCode);
    }

    function setAllowances(PublicMintERC20Vc88 dummy, Allowance[] memory allowances) internal {
        for (uint i = 0; i < allowances.length; i++) {
            vm.startPrank(allowances[i].owner);
            dummy.approve(allowances[i].spender, allowances[i].amount);
            vm.stopPrank();
        }
    }

    function testDummyERC20(PublicMintERC20Vc88 token, ERC20State memory state) internal view {
        require(keccak256(bytes(token.name())) == keccak256(bytes(state.name)), "Incorrect name");
        require(keccak256(bytes(token.symbol())) == keccak256(bytes(state.symbol)), "Incorrect symbol");
        require(token.decimals() == state.decimals, "Incorrect decimals");
        require(token.totalSupply() == state.totalSupply, "Incorrect total supply");
        require(token.getMaxSupply() == state.maxSupply, "Incorrect maxSupply");
        require(token.getPerMintLimit() == state.perMintLimit, "Incorrect perMintLimit");

        // Test a random balance
        if (state.balanceOf.length > 0) {
            uint256 index = uint256(keccak256(abi.encodePacked(block.timestamp))) % state.balanceOf.length;
            require(token.balanceOf(state.balanceOf[index].account) == state.balanceOf[index].amount, "Incorrect balance");
        }

        // Test a random allowance
        if (state.allowance.length > 0) {
            uint256 index = uint256(keccak256(abi.encodePacked(block.timestamp, "allowance"))) % state.allowance.length;
            Allowance memory allowance = state.allowance[index];
            require(token.allowance(allowance.owner, allowance.spender) == allowance.amount, "Incorrect allowance");
        }

        require(keccak256(address(token).code) == keccak256(type(PublicMintERC20Vc88).runtimeCode), "Token is not deployed");
    }
}