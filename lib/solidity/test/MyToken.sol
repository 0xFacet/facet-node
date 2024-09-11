// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import '../legacy/FacetERC20.sol';

contract MyToken is FacetERC20 {
    event SayHi(string message);
    constructor() {
         _initializeERC20("MyToken", "MTK", 18);
    }
    
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
        emit SayHi("hello!");
    }
}
