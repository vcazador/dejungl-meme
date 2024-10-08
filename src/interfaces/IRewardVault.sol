// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

interface IRewardVault {
    function getLastCollectedData() external view returns (uint256 rewardAmount, uint256 timeSinceLastCollect);
}
