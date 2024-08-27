// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

interface IGauge {
    function notifyRewardAmount(address token, uint256 amount) external;
}
