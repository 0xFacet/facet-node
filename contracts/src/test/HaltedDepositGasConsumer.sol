// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

contract HaltedDepositGasConsumer {
    constructor() {
        // First, allocate a large amount of memory (expensive operation)
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x1000) // Store 4096 at memory pointer
            mstore8(0x00, 0) // Allocate 4096 bytes of memory
        }
        
        // Then do some expensive operations in a loop
        for (uint i = 0; i < 10; i++) {
            bytes32 hash = keccak256(abi.encodePacked(block.timestamp, i));
            // Just consume the hash to avoid optimization
            assembly {
                pop(hash)
            }
        }
        
        // Finally halt with INVALID opcode
        assembly {
            invalid()
        }
    }
}