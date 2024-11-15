// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "src/libraries/FacetERC20.sol";
import "src/libraries/Upgradeable.sol";
import "src/predeploys/FacetSwapFactoryVac5.sol";
import "src/interfaces/IFacetSwapV1Callee.sol";
import "solady/utils/Initializable.sol";
import "solady/utils/LibString.sol";
import "src/libraries/UQ112x112.sol";

contract FacetSwapPairVdfd is FacetERC20, Initializable, Upgradeable {
    using UQ112x112 for uint224;
    using LibString for *;
    
    struct FacetSwapPairStorage {
        address factory;
        address token0;
        address token1;
        uint112 reserve0;
        uint112 reserve1;
        uint32 blockTimestampLast;
        uint256 price0CumulativeLast;
        uint256 price1CumulativeLast;
        uint256 kLast;
        uint256 unlocked;
    }
    
    function s() internal pure returns (FacetSwapPairStorage storage cs) {
        bytes32 position = keccak256("FacetSwapPairStorage.contract.storage.v1");
        assembly {
           cs.slot := position
        }
    }
    
    function factory() public view returns (address) {
        return s().factory;
    }
    
    function token0() public view returns (address) {
        return s().token0;
    }
    
    function token1() public view returns (address) {
        return s().token1;
    }

    function price0CumulativeLast() public view returns (uint256) {
        return s().price0CumulativeLast;
    }

    function price1CumulativeLast() public view returns (uint256) {
        return s().price1CumulativeLast;
    }

    function kLast() public view returns (uint256) {
        return s().kLast;
    }
    
    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;

    modifier lock() {
        require(s().unlocked == 1, "FacetSwapV1: LOCKED");
        s().unlocked = 0;
        _;
        s().unlocked = 1;
    }

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(address indexed sender, uint256 amount0In, uint256 amount1In, uint256 amount0Out, uint256 amount1Out, address indexed to);
    event Sync(uint112 reserve0, uint112 reserve1);
    event PreSwapReserves(uint112 reserve0, uint112 reserve1);

    constructor() {
        _disableInitializers();
    }

    function initialize() external initializer {
        _initializeERC20("FacetSwap V1 ERC20", "FACET-V1", 18);
        s().factory = msg.sender;
        s().unlocked = 1;
        _initializeUpgradeAdmin(msg.sender);
    }

    function init(address _token0, address _token1) external {
        require(msg.sender == s().factory, 'UniswapV2: FORBIDDEN');
        
        s().token0 = _token0;
        s().token1 = _token1;
    }
    
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = s().reserve0;
        _reserve1 = s().reserve1;
        _blockTimestampLast = s().blockTimestampLast;
    }

    function _safeTransfer(address token, address to, uint value) private {
        bytes4 selector = bytes4(keccak256(bytes('transfer(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    function _update(uint256 balance0, uint256 balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "FacetSwapV1: OVERFLOW");
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        
        uint32 timeElapsed;
        unchecked {
            timeElapsed = blockTimestamp - s().blockTimestampLast;
        }
        
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            unchecked {
                s().price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
                s().price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
            }
        }
        emit PreSwapReserves(s().reserve0, s().reserve1);
        s().reserve0 = uint112(balance0);
        s().reserve1 = uint112(balance1);
        s().blockTimestampLast = blockTimestamp;
        emit Sync(s().reserve0, s().reserve1);
    }

    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool) {
        address feeTo = FacetSwapFactoryVac5(s().factory).feeTo();
        bool feeOn = feeTo != address(0);
        uint256 _kLast = s().kLast;
        if (feeOn) {
            if (_kLast != 0) {
                uint squared = uint(_reserve0) * uint(_reserve1);
                uint256 rootK = sqrt(squared);
                uint256 rootKLast = sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint256 numerator = totalSupply() * (rootK - rootKLast);
                    uint256 denominator = rootK * 5 + rootKLast;
                    uint256 liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            s().kLast = 0;
        }
        return feeOn;
    }

    function mint(address to) external lock returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves();
        uint256 balance0 = ERC20(s().token0).balanceOf(address(this));
        uint256 balance1 = ERC20(s().token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            liquidity = sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            liquidity = min((amount0 * _totalSupply) / _reserve0, (amount1 * _totalSupply) / _reserve1);
        }
        require(liquidity > 0, "FacetSwapV1: INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) s().kLast = uint256(s().reserve0) * s().reserve1;
        emit Mint(msg.sender, amount0, amount1);
    }

    function burn(address to) external lock returns (uint256 amount0, uint256 amount1) {
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves();
        address _token0 = s().token0;
        address _token1 = s().token1;
        uint256 balance0 = ERC20(_token0).balanceOf(address(this));
        uint256 balance1 = ERC20(_token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply();
        amount0 = (liquidity * balance0) / _totalSupply;
        amount1 = (liquidity * balance1) / _totalSupply;
        require(amount0 > 0 && amount1 > 0, "FacetSwapV1: INSUFFICIENT_LIQUIDITY_BURNED");
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = ERC20(_token0).balanceOf(address(this));
        balance1 = ERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) s().kLast = uint256(s().reserve0) * s().reserve1;
        emit Burn(msg.sender, amount0, amount1, to);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, "FacetSwapV1: INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves();
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "FacetSwapV1: INSUFFICIENT_LIQUIDITY");

        uint256 balance0;
        uint256 balance1;
        {
            address _token0 = s().token0;
            address _token1 = s().token1;
            require(to != _token0 && to != _token1, "FacetSwapV1: INVALID_TO");
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out);
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out);
            if (data.length > 0) FacetSwapV1Callee(to).facetSwapV1Call(msg.sender, amount0Out, amount1Out, data);
            balance0 = ERC20(_token0).balanceOf(address(this));
            balance1 = ERC20(_token1).balanceOf(address(this));
        }

        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "FacetSwapV1: INSUFFICIENT_INPUT_AMOUNT");

        {
            uint256 lpFeeBPS = FacetSwapFactoryVac5(s().factory).lpFeeBPS();
            uint256 balance0Adjusted = balance0 * 1000 - (amount0In * lpFeeBPS) / 10;
            uint256 balance1Adjusted = balance1 * 1000 - (amount1In * lpFeeBPS) / 10;
            require(balance0Adjusted * balance1Adjusted >= uint256(_reserve0) * _reserve1 * (1000**2), "FacetSwapV1: K");
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    function skim(address to) external lock {
        address _token0 = s().token0;
        address _token1 = s().token1;
        _safeTransfer(_token0, to, ERC20(_token0).balanceOf(address(this)) - s().reserve0);
        _safeTransfer(_token1, to, ERC20(_token1).balanceOf(address(this)) - s().reserve1);
    }

    function sync() external lock {
        _update(ERC20(s().token0).balanceOf(address(this)), ERC20(s().token1).balanceOf(address(this)), s().reserve0, s().reserve1);
    }

    function sqrt(uint input) public view returns (uint) {
        if (MigrationLib.isInMigration()) {
            address pre = 0x00050db43a2b7dACe8D24c481E0Fe45459a09000;
            (bool success, bytes memory output) = pre.staticcall(abi.encode(input));
            require(success, "Failed to call sqrt precompile contract");
            return abi.decode(output, (uint));
        } else {
            return fixedPointSqrt(input);
        }
    }
    
    function fixedPointSqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function min(uint x, uint y) internal pure returns (uint z) {
        z = x < y ? x : y;
    }
}
