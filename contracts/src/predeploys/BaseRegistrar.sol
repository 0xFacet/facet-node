// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ENS} from "ens-contracts/registry/ENS.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "openzeppelin-contracts/contracts/utils/introspection/ERC165.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {LibString} from "solady/utils/LibString.sol";

import {GRACE_PERIOD} from "./Constants.sol";

import "../libraries/MigrationLib.sol";
import "src/libraries/FacetERC721.sol";
import "src/libraries/Upgradeable.sol";
import "solady/utils/Initializable.sol";
import {EventReplayable} from "src/libraries/EventReplayable.sol";
/// @title Base Registrar
///
/// @notice The base-level tokenization contract for an ens domain. The Base Registrar implements ERC721 and, as the owner
///         of a 2LD, can mint and assign ownership rights to its subdomains. I.e. This contract owns "base.eth" and allows
///         users to mint subdomains like "vitalik.base.eth". Registration is delegated to "controller" contracts which have
///         rights to call `onlyController` protected methods.
///
///         The implementation is heavily inspired by the original ENS BaseRegistrarImplementation contract:
///         https://github.com/ensdomains/ens-contracts/blob/staging/contracts/ethregistrar/BaseRegistrarImplementation.sol
///
/// @author Coinbase (https://github.com/base-org/usernames)
contract BaseRegistrar is FacetERC721, Ownable, Initializable, EventReplayable, Upgradeable {
    using LibString for uint256;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STORAGE                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    struct BaseRegistrarStorage {
        // Original state variables
        mapping(uint256 => uint256) nameExpires;
        ENS registry;
        bytes32 baseNode;
        string _baseURI;
        string _collectionURI;
        mapping(address => bool) controllers;
        
        // Migration-related state
        mapping(uint256 => uint256) v1TokenIdToV2TokenId;
        mapping(uint256 => uint256) v2TokenIdToV1TokenId;
        uint256 nextV1TokenId;
    }
    
    function nameExpires(uint256 tokenId) public view returns (uint256) {
        return s().nameExpires[tokenId];
    }
    
    function controllers(address user) public view returns (bool) {
        return s().controllers[user];
    }
    
    function registry() public view returns (ENS) {
        return s().registry;
    }
    
    function baseNode() public view returns (bytes32) {
        return s().baseNode;
    }
    
    function _baseURI() public view returns (string memory) {
        return s()._baseURI;
    }
    
    function _collectionURI() public view returns (string memory) {
        return s()._collectionURI;
    }
    
    function v1TokenIdToV2TokenId(uint256 tokenId) public view returns (uint256) {
        return s().v1TokenIdToV2TokenId[tokenId];
    }
    
    function v2TokenIdToV1TokenId(uint256 tokenId) public view returns (uint256) {
        return s().v2TokenIdToV1TokenId[tokenId];
    }
    
    function nextV1TokenId() public view returns (uint256) {
        return s().nextV1TokenId;
    }
    
    function s() internal pure returns (BaseRegistrarStorage storage bs) {
        bytes32 position = keccak256("BaseRegistrar.storage.v1");
        assembly {
            bs.slot := position
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          CONSTANTS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice InterfaceId for the Reclaim interface
    bytes4 private constant RECLAIM_ID = bytes4(keccak256("reclaim(uint256,address)"));

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          ERRORS                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Thrown when the name has expired.
    ///
    /// @param tokenId The id of the token that expired.
    error Expired(uint256 tokenId);

    /// @notice Thrown when called by an unauthorized owner.
    ///
    /// @param tokenId The id that was being called against.
    /// @param sender The unauthorized sender.
    error NotApprovedOwner(uint256 tokenId, address sender);

    /// @notice Thrown when the name is not available for registration.
    ///
    /// @param tokenId The id of the name that is not available.
    error NotAvailable(uint256 tokenId);

    /// @notice Thrown when the queried tokenId does not exist.
    ///
    /// @param tokenId The id of the name that does not exist.
    error NonexistentToken(uint256 tokenId);

    /// @notice Thrown when the name is not registered or in its Grace Period.
    ///
    /// @param tokenId The id of the token that is not registered or in Grace Period.
    error NotRegisteredOrInGrace(uint256 tokenId);

    /// @notice Thrown when msg.sender is not an approved Controller.
    error OnlyController();

    /// @notice Thrown when this contract does not own the `baseNode`.
    error RegistrarNotLive();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          EVENTS                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Emitted when a Controller is added to the approved `controllers` mapping.
    ///
    /// @param controller The address of the approved controller.
    event ControllerAdded(address indexed controller);

    /// @notice Emitted when a Controller is removed from the approved `controllers` mapping.
    ///
    /// @param controller The address of the removed controller.
    event ControllerRemoved(address indexed controller);

    /// @notice Emitted when a name is registered.
    ///
    /// @param id The id of the registered name.
    /// @param owner The owner of the registered name.
    /// @param expires The expiry of the new ownership record.
    event NameRegistered(uint256 indexed id, address indexed owner, uint256 expires);

    /// @notice Emitted when a name is renewed.
    ///
    /// @param id The id of the renewed name.
    /// @param expires The new expiry for the name.
    event NameRenewed(uint256 indexed id, uint256 expires);

    /// @notice Emitted when metadata for a token range is updated.
    ///
    /// @dev Useful for third-party platforms such as NFT marketplaces who can update
    ///     the images and related attributes of the NFTs in a timely fashion.
    ///     To refresh a whole collection, emit `_toTokenId` with `type(uint256).max`
    ///     ERC-4906: https://eip.tools/eip/4906
    ///
    /// @param _fromTokenId The starting range of `tokenId` for which metadata has been updated.
    /// @param _toTokenId The ending range of `tokenId` for which metadata has been updated.
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    /// @notice Emitted when the metadata for the contract collection is updated.
    ///
    /// @dev ERC-7572: https://eips.ethereum.org/EIPS/eip-7572
    event ContractURIUpdated();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          MODIFIERS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Decorator for determining if the contract is actively managing registrations for its `baseNode`.
    modifier live() {
        if (s().registry.owner(s().baseNode) != address(this)) revert RegistrarNotLive();
        _;
    }

    /// @notice Decorator for restricting methods to only approved Controller callers.
    modifier onlyController() {
        if (!s().controllers[msg.sender]) revert OnlyController();
        _;
    }

    /// @notice Decorator for determining if a name is available.
    ///
    /// @param id The id being checked for availability.
    modifier onlyAvailable(uint256 id) {
        if (!isAvailable(id)) revert NotAvailable(id);
        _;
    }

    /// @notice Decorator for determining if a name has expired.
    ///
    /// @param id The id being checked for expiry.
    modifier onlyNonExpired(uint256 id) {
        uint256 v2Id = s().v1TokenIdToV2TokenId[id];
        
        if (s().nameExpires[v2Id] <= block.timestamp && s().nameExpires[id] <= block.timestamp) revert Expired(id);
        _;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        IMPLEMENTATION                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice BaseRegistrar constructor used to initialize the configuration of the implementation.
    ///
    /// @param registry_ The Registry contract.
    /// @param owner_ The permissioned address initialized as the `owner` in the `Ownable` context.
    /// @param baseNode_ The node that this contract manages registrations for.
    /// @param baseURI_ The base token URI for NFT metadata.
    /// @param collectionURI_ The URI for the collection's metadata.
    function initialize(
        ENS registry_,
        address owner_,
        bytes32 baseNode_,
        string memory baseURI_,
        string memory collectionURI_
    ) public initializer {
        _initializeOwner(owner_);
        _initializeUpgradeAdmin(owner_);
        s().registry = registry_;
        s().baseNode = baseNode_;
        s()._baseURI = baseURI_;
        s()._collectionURI = collectionURI_;
        
        _initializeERC721("Facet Names", "FACETNAME");
    }
    
    constructor() {
        _disableInitializers();
    }

    /// @notice Authorises a controller, who can register and renew domains.
    ///
    /// @dev Emits `ControllerAdded(controller)` after adding the `controller` to the `controllers` mapping.
    ///
    /// @param controller The address of the new controller.
    function addController(address controller) external onlyOwner {
        s().controllers[controller] = true;
        emit ControllerAdded(controller);
    }

    /// @notice Revoke controller permission for an address.
    ///
    /// @dev Emits `ControllerRemoved(controller)` after removing the `controller` from the `controllers` mapping.
    ///
    /// @param controller The address of the controller to remove.
    function removeController(address controller) external onlyOwner {
        s().controllers[controller] = false;
        emit ControllerRemoved(controller);
    }

    /// @notice Set the resolver for the node this registrar manages.
    ///
    /// @param resolver The address of the new resolver contract.
    function setResolver(address resolver) external onlyOwner {
        s().registry.setResolver(s().baseNode, resolver);
    }

    /// @notice Register a name.
    ///
    /// @param id The token id determined by keccak256(label).
    /// @param owner The address that should own the registration.
    /// @param duration Duration in seconds for the registration.
    ///
    /// @return The expiry date of the registered name.
    function register(uint256 id, address owner, uint256 duration) external returns (uint256) {
        return _register(id, owner, duration, true);
    }

    /// @notice Register a name without modifying the Registry.
    ///
    /// @param id The token id determined by keccak256(label).
    /// @param owner The address that should own the registration.
    /// @param duration Duration in seconds for the registration.
    ///
    /// @return The expiry date of the registered name.
    function registerOnly(uint256 id, address owner, uint256 duration) external returns (uint256) {
        return _register(id, owner, duration, false);
    }
    /// @notice Register a name and add details to the record in the Registry.
    ///
    /// @dev This method can only be called if:
    ///         1. The contract is `live`
    ///         2. The caller is an approved `controller`
    ///         3. The name id is `available`
    ///     Emits `NameRegisteredWithRecord()` after successfully registering the name and setting the records.
    ///
    /// @param id The token id determined by keccak256(label).
    /// @param owner The address that should own the registration.
    /// @param duration Duration in seconds for the registration.
    /// @param resolver Address of the resolver for the name.
    /// @param ttl Time-to-live for the name.
    function registerWithRecord(uint256 id, address owner, uint256 duration, address resolver, uint64 ttl)
        external
        live
        onlyController
        onlyAvailable(id)
        returns (uint256)
    {
        uint256 expiry = _localRegister(id, owner, duration);
        s().registry.setSubnodeRecord(s().baseNode, bytes32(id), owner, resolver, ttl);
        
        recordAndEmitEvent(
            "NameRegistered(uint256,address,uint256)",
            abi.encode(id, owner),
            abi.encode(expiry)
        );
        
        return expiry;
    }

    /// @notice Gets the owner of the specified token ID.
    ///
    /// @dev Names become unowned when their registration expires.
    ///
    /// @param tokenId The id of the name to query the owner of.
    ///
    /// @return address The address currently marked as the owner of the given token ID.
    function ownerOf(uint256 tokenId) public view override onlyNonExpired(tokenId) returns (address) {
        return super.ownerOf(tokenId);
    }
    
    function _ownerOf(uint256 tokenId) internal view virtual override returns (address) {
        // First check if it's owned as-is
        address directOwner = super._ownerOf(tokenId);
        if (directOwner != address(0)) return directOwner;
        
        // If not found, check if it's a v1 ID and look up v2
        uint256 v2TokenId = s().v1TokenIdToV2TokenId[tokenId];
        return super._ownerOf(v2TokenId);
    }

    /// @notice Returns true if the specified name is available for registration.
    ///
    /// @param id The id of the name to check availability of.
    ///
    /// @return `true` if the name is available, else `false`.
    function isAvailable(uint256 id) public view returns (bool) {
        // Not available if it's registered here or in its grace period.
        return s().nameExpires[id] + GRACE_PERIOD < block.timestamp;
    }

    /// @notice Allows holders of names to renew their ownerhsip and extend their expiry.
    ///
    /// @dev Renewal can be called while owning a subdomain or while the name is in the
    ///     grace period. Can only be called by a controller.
    ///     Emits `NameRenewed()` after renewing the name by updating the expiry.
    ///
    /// @param id The id of the name to renew.
    /// @param duration The time that will be added to this name's expiry.
    ///
    /// @return The new expiry date.
    function renew(uint256 id, uint256 duration) external live onlyController returns (uint256) {
        uint256 expires = s().nameExpires[id];
        if (expires + GRACE_PERIOD < block.timestamp) revert NotRegisteredOrInGrace(id);

        expires += duration;
        s().nameExpires[id] = expires;
        emit NameRenewed(id, expires);
        return expires;
    }

    /// @notice Reclaim ownership of a name in ENS, if you own it in the registrar.
    ///
    /// @dev Token transfers are ambiguous for determining name ownership transfers. This method exists so that
    ///     if a name token is transfered to a new owner, they have the right to claim ownership over their
    ///     name in the Registry.
    ///
    /// @param id The id of the name to reclaim.
    /// @param owner The address of the owner that will be set in the Registry.
    function reclaim(uint256 id, address owner) external live {
        if (!_isApprovedOrOwner(msg.sender, id)) revert NotApprovedOwner(id, owner);
        s().registry.setSubnodeOwner(s().baseNode, bytes32(id), owner);
    }

    /// @notice ERC165 compliant signal for interface support.
    ///
    /// @dev Checks interface support for reclaim OR IERC721 OR ERC165.
    ///     https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[EIP section]
    ///
    /// @param interfaceID the ERC165 iface id being checked for compliance
    ///
    /// @return bool Whether this contract supports the provided interfaceID
    function supportsInterface(bytes4 interfaceID) public pure override(ERC721) returns (bool) {
        return interfaceID == type(IERC165).interfaceId || interfaceID == type(IERC721).interfaceId
            || interfaceID == RECLAIM_ID;
    }



    /// @notice Returns the Uniform Resource Identifier (URI) for token `id`.
    ///
    /// @dev Reverts if the `tokenId` has not be registered.
    ///
    /// @param tokenId The token for which to return the metadata uri.
    ///
    /// @return The URI for the specified `tokenId`.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (_ownerOf(tokenId) == address(0)) revert NonexistentToken(tokenId);

        return bytes(s()._baseURI).length > 0 ? string.concat(s()._baseURI, tokenId.toString()) : "";
    }

    /// @notice Returns the Uniform Resource Identifier (URI) for the contract.
    ///
    /// @dev ERC-7572: https://eips.ethereum.org/EIPS/eip-7572
    function contractURI() public view returns (string memory) {
        return s()._collectionURI;
    }

    /// @dev Allows the owner to set the the base Uniform Resource Identifier (URI)`.
    ///     Emits the `BatchMetadataUpdate` event for the full range of valid `tokenIds`.
    function setBaseTokenURI(string memory baseURI_) public onlyOwner {
        s()._baseURI = baseURI_;
        /// @dev minimum valid tokenId is `1` because uint256(nodehash) will never be called against `nodehash == 0x0`.
        uint256 minTokenId = 1;
        uint256 maxTokenId = type(uint256).max;
        emit BatchMetadataUpdate(minTokenId, maxTokenId);
    }

    /// @dev Allows the owner to set the the contract Uniform Resource Identifier (URI)`.
    ///     Emits the `ContractURIUpdated` event.
    function setContractURI(string memory collectionURI_) public onlyOwner {
        s()._collectionURI = collectionURI_;
        emit ContractURIUpdated();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      INTERNAL METHODS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Register a name and possibly update the Registry.
    ///
    /// @dev This method can only be called if:
    ///         1. The contract is `live`
    ///         2. The caller is an approved `controller`
    ///         3. The name id is `available`
    ///     Emits `NameRegistered()` after successfully registering the name.
    ///
    /// @param id The token id determined by keccak256(label).
    /// @param owner The address that should own the registration.
    /// @param duration Duration in seconds for the registration.
    /// @param updateRegistry Whether to update the Regstiry with the ownership change
    ///
    /// @return The expiry date of the registered name.
    function _register(uint256 id, address owner, uint256 duration, bool updateRegistry)
        internal
        live
        onlyController
        onlyAvailable(id)
        returns (uint256)
    {
        uint256 expiry = _localRegister(id, owner, duration);
        if (updateRegistry) {
            s().registry.setSubnodeOwner(s().baseNode, bytes32(id), owner);
        }
            
        recordAndEmitEvent(
            "NameRegistered(uint256,address,uint256)",
            abi.encode(id, owner),
            abi.encode(expiry)
        );
        return expiry;
    }

    /// @notice Internal handler for local state changes during registrations.
    ///
    /// @dev Sets the token's expiry time and then `burn`s and `mint`s a new token.
    ///
    /// @param id The token id determined by keccak256(label).
    /// @param owner The address that should own the registration.
    /// @param duration Duration in seconds for the registration.
    ///
    /// @return expiry The expiry date of the registered name.
    function _localRegister(uint256 id, address owner, uint256 duration) internal returns (uint256 expiry) {
        s().nextV1TokenId++;
        s().v1TokenIdToV2TokenId[s().nextV1TokenId] = id;
        s().v2TokenIdToV1TokenId[id] = s().nextV1TokenId;
        
        expiry = block.timestamp + duration;
        s().nameExpires[id] = expiry;
        if (_exists(id)) {
            // Name was previously owned, and expired
            _burn(id);
        }
        _mint(owner, id);
    }

    /// @notice Returns whether the given spender can transfer a given token ID.abi
    ///
    /// @dev v2.1.3 version of _isApprovedOrOwner which calls ownerOf(tokenId) instead of ERC721.ownerOf(tokenId);
    /// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v2.1.3/contracts/token/ERC721/ERC721.sol#L187
    ///
    /// @param spender address of the spender to query
    /// @param tokenId uint256 ID of the token to be transferred
    ///
    /// @return `true` if msg.sender is approved for the given token ID, is an operator of the owner,
    ///         or is the owner of the token, else `false`.
    function _isApprovedOrOwner(address spender, uint256 tokenId)
        internal
        view
        override
        onlyNonExpired(tokenId)
        returns (bool)
    {
        return super._isApprovedOrOwner(spender, tokenId);
    }
}