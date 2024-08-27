// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IMemeFactory} from "src/interfaces/IMemeFactory.sol";
import {ITraderRewards} from "src/interfaces/ITraderRewards.sol";

import {EPOCH_DURATION, DISTRIBUTION_PERIOD} from "src/utils/Epoch.sol";

/**
 * @title Trader Rewards Contract
 * @dev Manages the distribution of trading rewards based on user activity tracked by a MemeFactory contract.
 *      Rewards are calculated daily and distributed based on the volume of trading activity.
 * @notice This contract allows users to claim rewards for trading activities tracked via the connected factory.
 */
contract TraderRewards is Ownable, ITraderRewards {
    using SafeERC20 for IERC20;

    address public immutable factory;
    address public immutable rewardToken;

    address public depositor;

    mapping(address => uint256) public totalClaimed;
    mapping(uint256 => uint256) public rewardPerPeriod;
    mapping(address => uint48) public nextUserClaim;

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
        depositor = initialOwner;
    }

    /**
     * @notice Sets the depositor address for the contract.
     * @dev Only the owner can set the depositor address.
     * @param _depositor The address to set as the depositor.
     */
    function setDepositor(address _depositor) external onlyOwner {
        depositor = _depositor;
    }

    /**
     * @notice Deposits rewards for distribution starting from the next day.
     * @dev Automatically sets the reward distribution period from the next day for a week.
     * @param amount The total amount of rewards to be distributed.
     */
    function depositReward(uint256 amount) external {
        uint256 today = _currentPeriod();
        uint256 from = today + DISTRIBUTION_PERIOD;
        uint256 to = from + EPOCH_DURATION;
        depositReward(amount, from, to);
    }

    /**
     * @notice Deposits a specified amount of rewards to be distributed over a specified period.
     * @dev Transfers the specified reward amount from the caller and distributes it evenly over the specified period.
     * @param amount The total amount of rewards to be distributed.
     * @param from The start timestamp of the reward distribution period.
     * @param to The end timestamp of the reward distribution period.
     * @custom:error InvalidDistributionWindow Thrown if the specified distribution period is not valid.
     * @custom:error Unauthorized Thrown if the caller is not the depositor or the owner.
     */
    function depositReward(uint256 amount, uint256 from, uint256 to) public {
        if (msg.sender != depositor && msg.sender != owner()) {
            revert Unauthorized();
        }

        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);

        uint256 today = _currentPeriod();
        uint256 firstPeriod = _startOfPeriod(from);
        uint256 periods = (to - from) / DISTRIBUTION_PERIOD;

        if (firstPeriod <= today || periods == 0) {
            revert InvalidDistributionWindow();
        }

        uint256 amountPerPeriod = amount / periods;
        uint256 remainingAmount = amount;
        uint256 period = firstPeriod;

        while (periods != 0) {
            rewardPerPeriod[period] += amountPerPeriod;
            unchecked {
                periods--;
                remainingAmount -= amountPerPeriod;
                period += DISTRIBUTION_PERIOD;
            }
        }

        if (remainingAmount != 0) {
            rewardPerPeriod[firstPeriod] += remainingAmount;
        }

        emit RewardDeposited(msg.sender, amount, firstPeriod, period);
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
        uint48 today = _currentPeriod();
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
        amount = volume * rewardPerPeriod[today] / totalVolume;
    }

    /**
     * @notice Allows a user to claim their accrued trading rewards.
     * @dev Claims all available rewards for the sender, updates the claim timestamp, and transfers the rewards.
     * @return amount The amount of rewards claimed by the caller.
     */
    function claimReward() external returns (uint256 amount) {
        address user = msg.sender;

        (amount,) = claimableReward(user);

        nextUserClaim[user] = _currentPeriod();

        uint256 _totalClaimed = totalClaimed[user];
        uint256 newTotalClaimed = _totalClaimed + amount;
        totalClaimed[user] = newTotalClaimed;

        if (amount != 0) {
            IERC20(rewardToken).safeTransfer(user, amount);
        }

        emit RewardClaimed(user, amount, newTotalClaimed);
    }

    /**
     * @notice Gets the current period.
     * @dev Helper function to obtain the timestamp at the start of the current period.
     * @return The timestamp at the start of the current period.
     */
    function _currentPeriod() private view returns (uint48) {
        return _startOfPeriod(block.timestamp);
    }

    /**
     * @notice Converts a timestamp to the start of the period.
     * @dev Helper function to round down a timestamp to the nearest period.
     * @param timestamp The timestamp to convert.
     * @return The timestamp at the start of the given period.
     */
    function _startOfPeriod(uint256 timestamp) private pure returns (uint48) {
        return uint48((timestamp / DISTRIBUTION_PERIOD) * DISTRIBUTION_PERIOD);
    }
}
