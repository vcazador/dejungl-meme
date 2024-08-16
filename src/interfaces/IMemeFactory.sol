// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

interface IMemeFactory {
    function calculateFee(uint256 amount) external view returns (uint256);
    function router() external view returns (address);
    function escrow() external view returns (address);
    function protocolFeePercentage() external view returns (uint256);
    function feeRecipient() external view returns (address payable);
    function maxSupply() external view returns (uint256);
    function supplyThreshold() external view returns (uint256);
    function initialVirtualReserveMeme() external view returns (uint256);
    function initialVirtualReserveETH() external view returns (uint256);
    function trackAccountSpending(address account, int256 amount) external;
    function createPair(uint256 tokenAmount, uint256 ethAmount)
        external
        payable
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}
