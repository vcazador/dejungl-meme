// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IRouter {
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
}
