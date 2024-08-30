// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

interface ITraderRewards {
    /// @custom:storage-location erc7201:dejungle.storage.ITraderRewards
    struct TraderRewardsStorage {
        address factory;
        address rewardToken;
        address depositor;
        mapping(address => uint256) totalClaimed;
        mapping(uint256 => uint256) rewardPerPeriod;
        mapping(address => uint48) nextUserClaim;
    }

    error InvalidDistributionWindow();
    error Unauthorized();

    event RewardClaimed(address indexed user, uint256 amount, uint256 totalClaimed);
    event RewardDeposited(address indexed depositor, uint256 amount, uint256 from, uint256 to);

    function claimReward() external returns (uint256 amount);
    function depositReward(uint256 amount) external;
    function depositReward(uint256 amount, uint256 from, uint256 to) external;

    function claimableReward(address account) external view returns (uint256 amount, uint256 volume);
    function depositor() external view returns (address);
    function factory() external view returns (address);
    function nextUserClaim(address) external view returns (uint48);
    function rewardPerPeriod(uint256) external view returns (uint256);
    function rewardToken() external view returns (address);
    function totalClaimed(address) external view returns (uint256);
}
