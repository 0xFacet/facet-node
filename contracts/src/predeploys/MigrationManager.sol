// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "src/libraries/FacetERC20.sol";
import "src/libraries/FacetERC721.sol";
import "lib/solady/src/utils/EnumerableSetLib.sol";
import "lib/solady/src/utils/LibString.sol";
import "src/libraries/MigrationLib.sol";

interface FacetSwapFactory {
    function allPairs(uint256 index) external view returns (address);
    function allPairsLength() external view returns (uint256);
    function emitPairCreated(address pair, address token0, address token1, uint256 pairLength) external;
}

interface FacetSwapPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function sync() external;
}

contract MigrationManager {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using EnumerableSetLib for EnumerableSetLib.Bytes32Set;
    using EnumerableSetLib for EnumerableSetLib.Uint256Set;
    
    bool public migrationExecuted;
    EnumerableSetLib.AddressSet public factories;
    mapping(address => EnumerableSetLib.AddressSet) public factoryToPairs;
    
    EnumerableSetLib.AddressSet public allERC20Tokens;
    mapping(address => EnumerableSetLib.AddressSet) public erc20TokenToHolders;
    
    EnumerableSetLib.AddressSet public allERC721Tokens;
    mapping(address => EnumerableSetLib.Uint256Set) public erc721TokenToTokenIds;
    
    uint256 public currentBatchEmittedEvents;
    uint256 public totalEmittedEvents;
    uint256 public totalEventsToEmit;
    uint256 public constant MAX_EVENTS_PER_BATCH = 10_000;
    
    function transactionsRequired() public view returns (uint256) {
        return (calculateTotalEventsToEmit() + MAX_EVENTS_PER_BATCH - 1) / MAX_EVENTS_PER_BATCH;
    }
    
    function recordERC20Holder(address holder) external whileInV1 {
        address token = msg.sender;
        
        allERC20Tokens.add(token);
        
        if (holder != address(0)) {
            erc20TokenToHolders[token].add(holder);
        }
    }
    
    function recordERC721TokenId(uint256 id) external whileInV1 {
        address token = msg.sender;
        
        allERC721Tokens.add(token);
        erc721TokenToTokenIds[token].add(id);
    }
    
    function recordPairCreation(address pair) external whileInV1 {
        address factory = msg.sender;
        
        factories.add(factory);
        factoryToPairs[factory].add(pair);
    }
    
    function calculateTotalEventsToEmit() public view returns (uint256) {
        unchecked {
            uint256 totalERC20Events = 0;
            uint256 erc20TokensLength = allERC20Tokens.length();
            for (uint256 i = 0; i < erc20TokensLength; i++) {
                address token = allERC20Tokens.at(i);
                totalERC20Events += erc20TokenToHolders[token].length();
            }
            
            uint256 totalERC721Events = 0;
            uint256 erc721TokensLength = allERC721Tokens.length();
            for (uint256 i = 0; i < erc721TokensLength; i++) {
                address token = allERC721Tokens.at(i);
                totalERC721Events += erc721TokenToTokenIds[token].length();
            }
            
            uint256 totalFactoriesEvents = 0;
            uint256 factoriesLength = factories.length();
            for (uint256 i = 0; i < factoriesLength; i++) {
                address factory = factories.at(i);
                uint256 pairCount = factoryToPairs[factory].length();
                totalFactoriesEvents += pairCount * 2;
            }
            
            return totalERC20Events + totalERC721Events + totalFactoriesEvents;
        }
    }
    
    function executeMigration() external whileInV2 returns (uint256 remainingEvents) {
        require(msg.sender == MigrationLib.SYSTEM_ADDRESS, "Only system address can call");
        require(!migrationExecuted, "Migration already executed");
        
        if (totalEventsToEmit == 0) {
            totalEventsToEmit = calculateTotalEventsToEmit();
        }
        
        currentBatchEmittedEvents = 0;
        
        processFactories();
        
        if (!batchFinished()) {
            processERC20Tokens();
        }
        if (!batchFinished()) {
            processERC721Tokens();
        }
        
        totalEmittedEvents += currentBatchEmittedEvents;
        remainingEvents = totalEventsToEmit - totalEmittedEvents;
        
        if (remainingEvents == 0) {
            migrationExecuted = true;
        }
    }
    
    function batchFinished() public view returns (bool) {
        return currentBatchEmittedEvents >= MAX_EVENTS_PER_BATCH;
    }
    
    function processERC20Tokens() internal whileInV2 {
        unchecked {
            uint256 tokensLength = allERC20Tokens.length();
            for (uint256 i = tokensLength; i > 0; --i) {
                address token = allERC20Tokens.at(i - 1);
                
                migrateERC20(token);
                if (batchFinished()) return;
            }
        }
    }
    
    function processERC721Tokens() internal whileInV2 {
        unchecked {
            uint256 tokensLength = allERC721Tokens.length();
            for (uint256 i = tokensLength; i > 0; --i) {
                address token = allERC721Tokens.at(i - 1);
                
                migrateERC721(token);
                if (batchFinished()) return;
            }
        }
    }
    
    function processFactories() internal whileInV2 {
        unchecked {
            uint256 factoriesLength = factories.length();
            
            for (uint256 i = factoriesLength; i > 0; --i) {
                FacetSwapFactory factory = FacetSwapFactory(factories.at(i - 1));
                EnumerableSetLib.AddressSet storage pairs = factoryToPairs[address(factory)];
                
                uint256 pairsLength = pairs.length();
                for (uint256 j = pairsLength; j > 0; --j) {
                    FacetSwapPair pair = FacetSwapPair(pairs.at(j - 1));
                    address token0 = pair.token0();
                    address token1 = pair.token1();
                    
                    migrateERC20(token0);
                    if (batchFinished()) return;
                    
                    migrateERC20(token1);
                    if (batchFinished()) return;
                    
                    factory.emitPairCreated(address(pair), token0, token1, j);
                    
                    migrateERC20(address(pair), true);
                    pair.sync();
                    
                    currentBatchEmittedEvents += 2;
                    pairs.remove(address(pair));
                    
                    if (pairs.length() == 0) {
                        delete factoryToPairs[address(factory)];
                        factories.remove(address(factory));
                    }
                    
                    if (batchFinished()) return;
                }
            }
        }
    }
    
    function migrateERC20(address token) internal {
        return migrateERC20(token, false);
    }
    
    function migrateERC20(address token, bool isPair) internal {
        unchecked {
            EnumerableSetLib.AddressSet storage holders = erc20TokenToHolders[token];
            
            uint256 holdersLength = holders.length();
            for (uint256 j = holdersLength; j > 0; --j) {
                address holder = holders.at(j - 1);
                uint256 balance = FacetERC20(token).balanceOf(holder);
                
                require(holder != address(0), "Should not happen");
                
                if (balance > 0) {
                    FacetERC20(token).emitTransferEvent(holder, balance);
                }
                
                currentBatchEmittedEvents++;
                holders.remove(holder);
                
                if (holders.length() == 0) {
                    delete erc20TokenToHolders[token];
                    allERC20Tokens.remove(token);
                }
                
                if (batchFinished() && !isPair) return;
            }
        }
    }
    
    function migrateERC721(address token) internal {
        unchecked {
            EnumerableSetLib.Uint256Set storage tokenIds = erc721TokenToTokenIds[token];
            
            uint256 tokenIdsLength = tokenIds.length();
            for (uint256 j = tokenIdsLength; j > 0; --j) {
                uint256 tokenId = tokenIds.at(j - 1);
                address owner = FacetERC721(token).safeOwnerOf(tokenId);
                
                if (owner != address(0)) {
                    FacetERC721(token).emitTransferEvent(owner, tokenId);
                }
                
                currentBatchEmittedEvents++;
                tokenIds.remove(tokenId);
                
                if (tokenIds.length() == 0) {
                    delete erc721TokenToTokenIds[token];
                    allERC721Tokens.remove(token);
                }
                
                if (batchFinished()) return;
            }
        }
    }
    
    modifier whileInV1() {
        require(!migrationExecuted, "Migration already executed");
        require(MigrationLib.isInV1(), "Not in V1");
        _;
    }
    
    modifier whileInV2() {
        require(MigrationLib.isInV2(), "Not in V2");
        _;
    }
}