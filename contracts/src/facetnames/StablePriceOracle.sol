//SPDX-License-Identifier: MIT
pragma solidity ~0.8.17;

import {StringUtils} from "ens-contracts/utils/StringUtils.sol";

import {IPriceOracle} from "src/facetnames/interface/IPriceOracle.sol";
import "solady/utils/Initializable.sol";
import {MigrationLib} from "src/libraries/MigrationLib.sol";
/// @title Stable Pricing Oracle
///
/// @notice The pricing mechanism for setting the "base price" of names on a per-letter basis.
///         Inspired by the ENS StablePriceOracle contract:
///         https://github.com/ensdomains/ens-contracts/blob/staging/contracts/ethregistrar/StablePriceOracle.sol
///
/// @author Coinbase (https://github.com/base-org/usernames)
/// @author ENS (https://github.com/ensdomains/ens-contracts)
contract StablePriceOracle is IPriceOracle, Initializable {
    using StringUtils for *;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STORAGE                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice The price for a 1 letter name per second.
    uint256 public price1Letter;

    /// @notice The price for a 2 letter name per second.
    uint256 public price2Letter;

    /// @notice The price for a 3 letter name per second.
    uint256 public price3Letter;

    /// @notice The price for a 4 letter name per second.
    uint256 public price4Letter;

    /// @notice The price for a 5 to 9 letter name per second.
    uint256 public price5Letter;

    /// @notice The price for a 10 or longer letter name per second.
    uint256 public price10Letter;

    constructor() {
        _disableInitializers();
    }
    
    function _initializeStablePriceOracle(uint256[] memory _rentPrices) internal initializer {
        price1Letter = _rentPrices[0];
        price2Letter = _rentPrices[1];
        price3Letter = _rentPrices[2];
        price4Letter = _rentPrices[3];
        price5Letter = _rentPrices[4];
        price10Letter = _rentPrices[5];
    }

    /// @notice Returns the price to register or renew a name given an expiry and duration.
    ///
    /// @param name The name being registered or renewed.
    /// @param expires When the name presently expires (0 if this is a new registration).
    /// @param duration How long the name is being registered or extended for, in seconds.
    ///
    /// @return A `Price` tuple of `basePrice` and `premiumPrice`.
    function price(string calldata name, uint256 expires, uint256 duration)
        external
        view
        returns (IPriceOracle.Price memory)
    {
        uint256 len = name.strlen();
        uint256 basePrice;

        if (MigrationLib.isInMigration()) {
            // USD-based pricing model for migration
            if (len >= 10) {
                basePrice = price10Letter * duration;
            } else if (len >= 5) {
                basePrice = price5Letter * duration;
            } else if (len == 4) {
                basePrice = price4Letter * duration;
            } else if (len == 3) {
                basePrice = price3Letter * duration;
            } else if (len == 2) {
                basePrice = price2Letter * duration;
            } else {
                basePrice = price1Letter * duration;
            }
            
            uint256 usdWeiCentsInOneEth = 200000000000000000000000;
            uint256 totalPriceWeiCents = basePrice;
            uint256 totalPriceEth = (totalPriceWeiCents * 1 ether) / usdWeiCentsInOneEth;
            
            return IPriceOracle.Price({base: totalPriceEth, premium: 0});
        } else {
            // Simple pricing model for non-migration
            if (len >= 10) {
                basePrice = 3_168_087 * duration;
            } else if (len >= 5) {
                basePrice = 31_680_878 * duration;
            } else if (len == 4) {
                basePrice = 316_808_781 * duration;
            } else if (len == 3) {
                basePrice = 3_168_087_814 * duration;
            } else if (len == 2) {
                basePrice = 31_680_878_140 * duration;
            } else {
                basePrice = 316_808_781_402 * duration;
            }
            
            uint256 premium_ = _premium(name, expires, duration);
            return IPriceOracle.Price({base: basePrice, premium: premium_});
        }
    }

    /// @notice Returns the pricing premium denominated in wei.
    function premium(string calldata name, uint256 expires, uint256 duration) external view returns (uint256) {
        return _premium(name, expires, duration);
    }

    /// @notice Returns the pricing premium denominated in wei.
    function _premium(string memory, uint256, uint256) internal view virtual returns (uint256) {
        return 0;
    }
}
