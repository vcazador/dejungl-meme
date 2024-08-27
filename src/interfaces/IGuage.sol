// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IGuage {
    function notifyRewardAmount(address token, uint256 amount) external;
}
