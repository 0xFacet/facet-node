// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "src/libraries/Upgradeable.sol";
import "./FacetSwapPairV2b2.sol";
import "./FacetSwapFactoryVe7f.sol";
import "src/libraries/FacetERC20.sol";
import "solady/utils/Initializable.sol";

contract FacetSwapRouterV099 is Initializable, Upgradeable {
    struct FacetSwapRouterStorage {
        address factory;
        address WETH;
        uint256 maxPathLength;
    }

    function s() internal pure returns (FacetSwapRouterStorage storage rs) {
        bytes32 position = keccak256("FacetSwapRouterStorage.contract.storage.v1");
        assembly {
            rs.slot := position
        }
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address _factory, address _WETH) public initializer {
        s().factory = _factory;
        s().WETH = _WETH;
        s().maxPathLength = 3;
        _initializeUpgradeAdmin(msg.sender);
    }

    function getFactory() public view returns (address) {
        return s().factory;
    }

    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal virtual returns (uint256 amountA, uint256 amountB) {
        if (FacetSwapFactoryVe7f(s().factory).getPair(tokenA, tokenB) == address(0)) {
            FacetSwapFactoryVe7f(s().factory).createPair(tokenA, tokenB);
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
    ) public virtual returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        require(deadline >= block.timestamp, "FacetSwapV1Router: EXPIRED");
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = pairFor(s().factory, tokenA, tokenB);
        _safeTransferFrom(tokenA, msg.sender, pair, amountA);
        _safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = FacetSwapPairV2b2(pair).mint(to);
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) public virtual returns (uint256 amountA, uint256 amountB) {
        require(deadline >= block.timestamp, "FacetSwapV1Router: EXPIRED");
        address pair = pairFor(s().factory, tokenA, tokenB);
        FacetSwapPairV2b2(pair).transferFrom(msg.sender, pair, liquidity);
        (uint256 amount0, uint256 amount1) = FacetSwapPairV2b2(pair).burn(to);
        (address token0, ) = sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin, "FacetSwapV1Router: INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "FacetSwapV1Router: INSUFFICIENT_B_AMOUNT");
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) public virtual returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "FacetSwapV1Router: EXPIRED");
        amounts = getAmountsOut(s().factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "FacetSwapV1Router: INSUFFICIENT_OUTPUT_AMOUNT");
        _safeTransferFrom(path[0], msg.sender, pairFor(s().factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) public virtual returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "FacetSwapV1Router: EXPIRED");
        amounts = getAmountsIn(s().factory, amountOut, path);
        require(amounts[0] <= amountInMax, "FacetSwapV1Router: EXCESSIVE_INPUT_AMOUNT");
        _safeTransferFrom(path[0], msg.sender, pairFor(s().factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    function _swap(uint256[] memory amounts, address[] memory path, address _to) internal virtual {
        require(path.length <= s().maxPathLength, "Max path length exceeded");
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) = input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
            address to = i < path.length - 2 ? pairFor(s().factory, output, path[i + 2]) : _to;
            FacetSwapPairV2b2(pairFor(s().factory, input, output)).swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) private {
        bool result = ERC20(token).transferFrom(from, to, value);
        require(result, "FacetSwapV1: TRANSFER_FAILED");
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

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256 amountOut) {
        require(amountIn > 0, "FacetSwapV1Library: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "FacetSwapV1Library: INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
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

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256 amountIn) {
        require(amountOut > 0, "FacetSwapV1Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "FacetSwapV1Library: INSUFFICIENT_LIQUIDITY");
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) public pure returns (uint256 amountB) {
        require(amountA > 0, "FacetSwapV1Library: INSUFFICIENT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "FacetSwapV1Library: INSUFFICIENT_LIQUIDITY");
        amountB = (amountA * reserveB) / reserveA;
    }

    function getReserves(address factory, address tokenA, address tokenB) public view returns (uint256 reserveA, uint256 reserveB) {
        (address token0, ) = sortTokens(tokenA, tokenB);
        (uint256 reserve0, uint256 reserve1, ) = FacetSwapPairV2b2(pairFor(factory, tokenA, tokenB)).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    function pairFor(address factory, address tokenA, address tokenB) internal view returns (address pair) {
        return FacetSwapFactoryVe7f(factory).getPair(tokenA, tokenB);
    }

    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, "FacetSwapV1Library: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "FacetSwapV1Library: ZERO_ADDRESS");
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
        if (FacetSwapFactoryVe7f(s().factory).getPair(tokenA, tokenB) != address(0)) {
            (tokenAReserves, tokenBReserves) = getReserves(s().factory, tokenA, tokenB);
            pairAddress = FacetSwapFactoryVe7f(s().factory).getPair(tokenA, tokenB);
            userLPBalance = FacetERC20(pairAddress).balanceOf(user);
        }
        userTokenABalance = ERC20(tokenA).balanceOf(user);
        userTokenBBalance = ERC20(tokenB).balanceOf(user);
        tokenAName = ERC20(tokenA).name();
        tokenBName = ERC20(tokenB).name();
    }
}
