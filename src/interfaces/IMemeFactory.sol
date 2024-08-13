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
    function trackAccountSpending(address account, int256 amount) external;
}
