// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "src/libraries/Upgradeable.sol";
import "./FacetSwapPairVdfd.sol";
import "./FacetSwapFactoryVac5.sol";
import "src/libraries/FacetERC20.sol";
import "src/libraries/Pausable.sol";
import "src/libraries/FacetOwnable.sol";
import "solady/utils/Initializable.sol";
import "solady/utils/SafeTransferLib.sol";

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint value) external returns (bool);
    function withdraw(uint) external;
}

contract FacetSwapRouterV56d is Initializable, Upgradeable, FacetOwnable, Pausable {
    using SafeTransferLib for address;
    
    IWETH public constant WFCT = IWETH(0x4200000000000000000000000000000000000006);
    
    struct FacetSwapRouterStorage {
        address factory;
        address WETH;
        uint256 maxPathLength;
        uint256 protocolFeeBPS;
    }

    function s() internal pure returns (FacetSwapRouterStorage storage rs) {
        bytes32 position = keccak256("FacetSwapRouterStorage.contract.storage.v1");
        assembly {
            rs.slot := position
        }
    }
    
    event FeeAdjustedSwap(
        address indexed inputToken,
        address indexed outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 feeAmount,
        address indexed to
    );

    constructor() {
        _disableInitializers();
    }
    
    function initialize(address _factory, address _WETH, uint256 protocolFeeBPS, bool initialPauseState) public initializer {
        s().factory = _factory;
        s().WETH = _WETH;
        s().maxPathLength = 3;
        _initializeUpgradeAdmin(msg.sender);
        
        _initializeOwner(msg.sender);
        updateProtocolFee(protocolFeeBPS);
        _initializePausable(initialPauseState);
    }
    
    function setWETH(address _WETH) public onlyOwner {
        s().WETH = _WETH;
    }
    
    function getWETH() public view returns (address) {
        return s().WETH;
    }
    
    function setPathLength(uint256 maxPathLength) public onlyOwner {
        s().maxPathLength = maxPathLength;
    }
    
    function setFactory(address _factory) public onlyOwner {
        s().factory = _factory;
    }

    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal virtual returns (uint256 amountA, uint256 amountB) {
        if (FacetSwapFactoryVac5(s().factory).getPair(tokenA, tokenB) == address(0)) {
            FacetSwapFactoryVac5(s().factory).createPair(tokenA, tokenB);
        }
        (uint256 reserveA, uint256 reserveB) = getReserves(s().factory, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            return (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, "FacetSwapV1Router: INSUFFICIENT_B_AMOUNT");
                return (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = quote(amountBDesired, reserveB, reserveA);
                require(amountAOptimal <= amountADesired, "ASSERT");
                require(amountAOptimal >= amountAMin, "FacetSwapV1Router: INSUFFICIENT_A_AMOUNT");
                return (amountAOptimal, amountBDesired);
            }
        }
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) public virtual whenNotPaused returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        require(deadline >= block.timestamp, "FacetSwapV1Router: EXPIRED");
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = pairFor(s().factory, tokenA, tokenB);
        _safeTransferFrom(tokenA, msg.sender, pair, amountA);
        _safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = FacetSwapPairVdfd(pair).mint(to);
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) public virtual whenNotPaused returns (uint256 amountA, uint256 amountB) {
        require(deadline >= block.timestamp, "FacetSwapV1Router: EXPIRED");
        address pair = pairFor(s().factory, tokenA, tokenB);
        FacetSwapPairVdfd(pair).transferFrom(msg.sender, pair, liquidity);
        (uint256 amount0, uint256 amount1) = FacetSwapPairVdfd(pair).burn(to);
        (address token0, ) = sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin, "FacetSwapV1Router: INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "FacetSwapV1Router: INSUFFICIENT_B_AMOUNT");
    }

    modifier ensureWETHBalance() {
        uint256 initialWETHBalance = ERC20(s().WETH).balanceOf(address(this));
        _;
        uint256 finalWETHBalance = ERC20(s().WETH).balanceOf(address(this));
        require(finalWETHBalance >= initialWETHBalance, "Router WETH balance decreased");
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) public virtual payable whenNotPaused ensureWETHBalance returns (uint256[] memory amounts) {
        require(path[0] == s().WETH || path[path.length - 1] == s().WETH, "Must have WETH as either first or last token");
        require(path[0] != path[path.length - 1], "Cannot self trade");
        
        if (path[0] == address(WFCT) && msg.value > 0) {
            require(msg.value == amountIn, "Incorrect FCT amount");
            WFCT.deposit{value: amountIn}();
            WFCT.transfer(msg.sender, amountIn);
        }

        uint256 amountInWithFee = path[0] == s().WETH ? amountIn - calculateFeeAmount(amountIn) : amountIn;
        amounts = _swapExactTokensForTokens(amountInWithFee, amountOutMin, path, address(this), deadline);
        
        uint256 amountToChargeFeeOn = path[0] == s().WETH ? amountIn : amounts[amounts.length - 1];
        uint256 feeAmount = calculateFeeAmount(amountToChargeFeeOn);
        
        if (path[0] == s().WETH) {
            amounts[0] = amountIn;
            ERC20(s().WETH).transferFrom(msg.sender, address(this), feeAmount);
        } else {
            amounts[amounts.length - 1] = amounts[amounts.length - 1] - feeAmount;
        }

        address outputToken = path[path.length - 1];
        uint256 outputAmount = amounts[amounts.length - 1];
        
        if (outputToken == address(WFCT)) {
            WFCT.withdraw(outputAmount);
            _safeTransferFCT(to, outputAmount);
        } else {
            outputToken.safeTransfer(to, outputAmount);
        }

        emit FeeAdjustedSwap(path[0], outputToken, amounts[0], outputAmount, feeAmount, to);
        return amounts;
    }

    function _swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) internal virtual returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "FacetSwapV1Router: EXPIRED");
        amounts = getAmountsOut(s().factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "FacetSwapV1Router: INSUFFICIENT_OUTPUT_AMOUNT");
        _safeTransferFrom(path[0], msg.sender, pairFor(s().factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
        return amounts;
    }

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] memory path,
        address to,
        uint256 deadline
    ) public virtual payable whenNotPaused ensureWETHBalance returns (uint256[] memory amounts) {
        require(path[0] == s().WETH || path[path.length - 1] == s().WETH, "Must have WETH as either first or last token");
        require(path[0] != path[path.length - 1], "Cannot self trade");

        uint256 amountOutWithFee = path[path.length - 1] == s().WETH ? amountOut + calculateFeeAmount(amountOut) : amountOut;
        
        amounts = getAmountsIn(s().factory, amountOutWithFee, path);

        if (path[0] == address(WFCT) && msg.value > 0) {
            require(msg.value >= amounts[0], 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
            
            if (msg.value > amounts[0]) {
                _safeTransferFCT(msg.sender, msg.value - amounts[0]);
            }
            
            WFCT.deposit{value: amounts[0]}();
            WFCT.transfer(msg.sender, amounts[0]);
        }
        
        _swapTokensForExactTokens(amountOutWithFee, amountInMax, path, address(this), deadline);
        
        uint256 amountToChargeFeeOn = path[0] == s().WETH ? amounts[0] : amountOut;
        uint256 feeAmount = calculateFeeAmount(amountToChargeFeeOn);
        
        if (path[0] == s().WETH) {
            amounts[0] = amounts[0] + feeAmount;
            ERC20(s().WETH).transferFrom(msg.sender, address(this), feeAmount);
        } else {
            amounts[amounts.length - 1] = amountOut;
        }

        address outputToken = path[path.length - 1];
        uint256 outputAmount = amounts[amounts.length - 1];

        if (outputToken == address(WFCT)) {
            WFCT.withdraw(outputAmount);
            _safeTransferFCT(to, outputAmount);
        } else {
            outputToken.safeTransfer(to, outputAmount);
        }

        emit FeeAdjustedSwap(path[0], outputToken, amounts[0], outputAmount, feeAmount, to);
        return amounts;
    }

    function _swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] memory path,
        address to,
        uint256 deadline
    ) internal virtual returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "FacetSwapV1Router: EXPIRED");
        amounts = getAmountsIn(s().factory, amountOut, path);
        require(amounts[0] <= amountInMax, "FacetSwapV1Router: EXCESSIVE_INPUT_AMOUNT");
        _safeTransferFrom(path[0], msg.sender, pairFor(s().factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
        return amounts;
    }

    function _swap(uint256[] memory amounts, address[] memory path, address _to) internal virtual {
        require(path.length <= s().maxPathLength, "Max path length exceeded");
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) = input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
            address to = i < path.length - 2 ? pairFor(s().factory, output, path[i + 2]) : _to;
            FacetSwapPairVdfd(pairFor(s().factory, input, output)).swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) internal {
        // bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            'TransferHelper::transferFrom: transferFrom failed'
        );
    }

    function getAmountsOut(address factory, uint256 amountIn, address[] memory path) public view returns (uint256[] memory amounts) {
        require(path.length >= 2, "FacetSwapV1Library: INVALID_PATH");
        require(path.length <= s().maxPathLength, "Max path length exceeded");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i; i < path.length - 1; i++) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public view returns (uint256) {
        require(amountIn > 0, "FacetSwapV1Library: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "FacetSwapV1Library: INSUFFICIENT_LIQUIDITY");
        uint256 lpFeeBPS = FacetSwapFactoryVac5(s().factory).lpFeeBPS();
        uint256 totalFeeFactor = 1000 - lpFeeBPS / 10;
        uint256 amountInWithFee = amountIn * totalFeeFactor;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        return numerator / denominator;
    }

    function getAmountsIn(address factory, uint256 amountOut, address[] memory path) public view returns (uint256[] memory amounts) {
        require(path.length >= 2, "FacetSwapV1Library: INVALID_PATH");
        require(path.length <= s().maxPathLength, "Max path length exceeded");
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint256 i = path.length - 1; i > 0; i--) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) public view returns (uint256) {
        require(amountOut > 0, "FacetSwapV1Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "FacetSwapV1Library: INSUFFICIENT_LIQUIDITY");
        uint256 lpFeeBPS = FacetSwapFactoryVac5(s().factory).lpFeeBPS();
        uint256 totalFeeFactor = 1000 - lpFeeBPS / 10;
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * totalFeeFactor;
        return (numerator / denominator) + 1;
    }

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) public pure returns (uint256 amountB) {
        require(amountA > 0, "FacetSwapV1Library: INSUFFICIENT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "FacetSwapV1Library: INSUFFICIENT_LIQUIDITY");
        amountB = (amountA * reserveB) / reserveA;
    }

    function getReserves(address factory, address tokenA, address tokenB) public view returns (uint256 reserveA, uint256 reserveB) {
        (address token0, ) = sortTokens(tokenA, tokenB);
        (uint256 reserve0, uint256 reserve1, ) = FacetSwapPairVdfd(pairFor(factory, tokenA, tokenB)).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    function pairFor(address factory, address tokenA, address tokenB) internal view returns (address pair) {
        return FacetSwapFactoryVac5(factory).getPair(tokenA, tokenB);
    }

    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, "FacetSwapV1Library: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "FacetSwapV1Library: ZERO_ADDRESS");
    }

    function calculateFeeAmount(uint256 amount) public view returns (uint256) {
        return (amount * s().protocolFeeBPS) / 10000;
    }

    function updateProtocolFee(uint256 protocolFeeBPS) public onlyOwner {
        require(protocolFeeBPS <= 10000, "Fee cannot be greater than 100%");
        s().protocolFeeBPS = protocolFeeBPS;
    }
    
    function getProtocolFeeBPS() public view returns (uint256) {
        return s().protocolFeeBPS;
    }

    function withdrawFees(address to) public onlyOwner {
        uint256 balance = ERC20(s().WETH).balanceOf(address(this));
        ERC20(s().WETH).transfer(to, balance);
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function userStats(
        address user,
        address tokenA,
        address tokenB
    ) public view returns (
        uint256 userTokenABalance,
        uint256 userTokenBBalance,
        string memory tokenAName,
        string memory tokenBName,
        uint256 tokenAReserves,
        uint256 tokenBReserves,
        uint256 userLPBalance,
        address pairAddress
    ) {
        tokenAReserves = 0;
        tokenBReserves = 0;
        userLPBalance = 0;
        if (FacetSwapFactoryVac5(s().factory).getPair(tokenA, tokenB) != address(0)) {
            (tokenAReserves, tokenBReserves) = getReserves(s().factory, tokenA, tokenB);
            pairAddress = FacetSwapFactoryVac5(s().factory).getPair(tokenA, tokenB);
            userLPBalance = FacetERC20(pairAddress).balanceOf(user);
        }
        userTokenABalance = ERC20(tokenA).balanceOf(user);
        userTokenBBalance = ERC20(tokenB).balanceOf(user);
        tokenAName = ERC20(tokenA).name();
        tokenBName = ERC20(tokenB).name();
    }
    
    function factory() public view returns (address) {
        return s().factory;
    }
    
    function _safeTransferFCT(address to, uint256 value) internal {
        SafeTransferLib.safeTransferETH(to, value);
    }
}
