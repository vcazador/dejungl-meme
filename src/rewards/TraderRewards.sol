// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IMemeFactory} from "src/interfaces/IMemeFactory.sol";

/**
 * @title Trader Rewards Contract
 * @dev Manages the distribution of trading rewards based on user activity tracked by a MemeFactory contract.
 *      Rewards are calculated daily and distributed based on the volume of trading activity.
 * @notice This contract allows users to claim rewards for trading activities tracked via the connected factory.
 */
contract TraderRewards is Ownable {
    using SafeERC20 for IERC20;

    address public immutable factory;
    address public immutable rewardToken;

    mapping(address => uint256) public totalClaimed;
    mapping(uint256 => uint256) public rewardPerDay;
    mapping(address => uint48) public nextUserClaim;

    event RewardClaimed(address indexed user, uint256 amount, uint256 totalClaimed);
    event RewardDeposited(address indexed depositor, uint256 amount, uint256 from, uint256 to);

    error InvalidDistributionWindow();

    /**
     * @notice Initializes the TraderRewards contract with necessary addresses and owner.
     * @dev Sets the immutable addresses for the factory and reward token, and sets the initial owner of the contract.
     * @param _factory Address of the MemeFactory contract used to track trading volumes.
     * @param _rewardToken ERC20 token address used as the reward currency.
     * @param initialOwner Address that will own the contract initially, passed to the Ownable constructor.
     */
    constructor(address _factory, address _rewardToken, address initialOwner) Ownable(initialOwner) {
        factory = _factory;
        rewardToken = _rewardToken;
    }

    /**
     * @notice Deposits rewards for distribution starting from the next day.
     * @dev Automatically sets the reward distribution period from the next day for a week.
     * @param amount The total amount of rewards to be distributed.
     */
    function depositReward(uint256 amount) external {
        uint256 today = _today();
        uint256 from = today + 1 days;
        uint256 to = from + 7 days;
        depositReward(amount, from, to);
    }

    /**
     * @notice Deposits a specified amount of rewards to be distributed over a specified period.
     * @dev Transfers the specified reward amount from the caller and distributes it evenly over the specified period.
     * @param amount The total amount of rewards to be distributed.
     * @param from The start timestamp of the reward distribution period.
     * @param to The end timestamp of the reward distribution period.
     * @custom:error InvalidDistributionWindow Thrown if the specified distribution period is not valid.
     */
    function depositReward(uint256 amount, uint256 from, uint256 to) public onlyOwner {
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);

        uint256 today = _today();
        uint256 firstDay = _midnight(from);
        uint256 numDays = (to - from) / 1 days;

        if (firstDay <= today || numDays == 0) {
            revert InvalidDistributionWindow();
        }

        uint256 amountPerDay = amount / numDays;
        uint256 remainingAmount = amount;
        uint256 day = firstDay;

        while (numDays != 0) {
            rewardPerDay[day] += amountPerDay;
            unchecked {
                numDays--;
                remainingAmount -= amountPerDay;
                day += 1 days;
            }
        }

        if (remainingAmount != 0) {
            rewardPerDay[firstDay] += remainingAmount;
        }

        emit RewardDeposited(msg.sender, amount, firstDay, day);
    }

    /**
     * @notice Calculates the reward an account can claim based on their trading volume.
     * @dev Calculates claimable rewards by comparing user-specific trading volume against total trading volume.
     * @param account The account to calculate claimable rewards for.
     * @return amount The amount of rewards that the account can claim.
     * @return volume The total trading volume of the account that contributes to the reward calculation.
     */
    function claimableReward(address account) public view returns (uint256 amount, uint256 volume) {
        uint48 from = nextUserClaim[account];
        uint48 today = _today();
        if (from >= today) {
            return (0, 0);
        }
        (uint256 totalBuys, uint256 totalSells) = IMemeFactory(factory).getAccountSpending(account, from, today - 1);
        volume = totalBuys + totalSells;
        if (volume == 0) {
            return (0, 0);
        }
        (totalBuys, totalSells) = IMemeFactory(factory).getTotalSpending(from, today - 1);
        uint256 totalVolume = totalBuys + totalSells;
        amount = volume * rewardPerDay[today] / totalVolume;
    }

    /**
     * @notice Allows a user to claim their accrued trading rewards.
     * @dev Claims all available rewards for the sender, updates the claim timestamp, and transfers the rewards.
     * @return amount The amount of rewards claimed by the caller.
     */
    function claimReward() external returns (uint256 amount) {
        address user = msg.sender;

        (amount,) = claimableReward(user);

        nextUserClaim[user] = _today();

        uint256 _totalClaimed = totalClaimed[user];
        uint256 newTotalClaimed = _totalClaimed + amount;
        totalClaimed[user] = newTotalClaimed;

        if (amount != 0) {
            IERC20(rewardToken).safeTransfer(user, amount);
        }

        emit RewardClaimed(user, amount, newTotalClaimed);
    }

    /**
     * @notice Gets today's date rounded down to the nearest day.
     * @dev Helper function to obtain the timestamp at midnight of the current day.
     * @return The timestamp at midnight today.
     */
    function _today() private view returns (uint48) {
        return _midnight(block.timestamp);
    }

    /**
     * @notice Converts a timestamp to the start of the day (midnight).
     * @dev Helper function to round down a timestamp to the nearest day.
     * @param timestamp The timestamp to convert.
     * @return The timestamp at midnight of the given day.
     */
    function _midnight(uint256 timestamp) private pure returns (uint48) {
        return uint48((timestamp / 1 days) * 1 days);
    }
}
