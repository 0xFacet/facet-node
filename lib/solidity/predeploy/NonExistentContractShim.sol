// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "solady/src/utils/LibString.sol";

contract NonExistentContractShim {
    using LibString for *;
    
    fallback() external {
        if (msg.data.length != 20) {
            // Return here as we are expecting an error
            return;
        }
        
        address attemptedAddress = abi.decode(msg.data, (address));
        revert("Contract not found: ".concat(attemptedAddress.toHexString()));
    }
}
