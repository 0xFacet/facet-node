// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import '../legacy/FacetERC20.sol';
import "solady/src/utils/Initializable.sol";

contract StubERC20 is FacetERC20, Initializable {
    constructor() {
        _disableInitializers();
    }
    
    function initialize(string memory name) public initializer {
        _initializeERC20(name, "symbol", 18);
    }

    function mint(uint256 amount) public {
        _mint(msg.sender, amount);
    }

    function airdrop(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function updateName(string memory name) public {
        _FacetERC20Storage().name = name;
    }
}
