// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

interface IRouter {
    struct route {
        address from;
        address to;
        bool stable;
    }

    function pairFor(address tokenA, address tokenB, bool stable) external view returns (address pair);

    function factory() external view returns (address);

    function addLiquidityETH(
        address token,
        bool stable,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    function weth() external view returns (address);

    function getAmountsOut(uint256 amountIn, route[] memory routes) external view returns (uint256[] memory amounts);

    function swapExactETHForTokens(uint256 amountOutMin, route[] calldata routes, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts);

    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}
