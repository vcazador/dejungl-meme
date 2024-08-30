// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IMemeFactory} from "src/interfaces/IMemeFactory.sol";
import {ITraderRewards} from "src/interfaces/ITraderRewards.sol";

import {EPOCH_DURATION, DISTRIBUTION_PERIOD} from "src/utils/Epoch.sol";

/**
 * @title Trader Rewards Contract
 * @dev Manages the distribution of trading rewards based on user activity tracked by a MemeFactory contract.
 *      Rewards are calculated daily and distributed based on the volume of trading activity.
 * @notice This contract allows users to claim rewards for trading activities tracked via the connected factory.
 */
contract TraderRewards is OwnableUpgradeable, UUPSUpgradeable, ITraderRewards {
    using SafeERC20 for IERC20;

    // keccak256(abi.encode(uint256(keccak256("dejungle.storage.ITraderRewards")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TraderRewardsStorageLocation =
        0x79bc9948bc7d2be9511b1d223c41a352c94ee9578db38d228b5cca2cb9993000;

    function _getTraderRewardsStorage() private pure returns (TraderRewardsStorage storage $) {
        assembly {
            $.slot := TraderRewardsStorageLocation
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the TraderRewards contract with necessary addresses and owner.
     * @dev Sets the addresses for the factory and reward token, and sets the initial owner of the contract.
     * @param initialOwner Address that will own the contract initially, passed to the Ownable constructor.
     * @param _factory Address of the MemeFactory contract used to track trading volumes.
     * @param _rewardToken ERC20 token address used as the reward currency.
     */
    function initialize(address initialOwner, address _factory, address _rewardToken) external initializer {
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();

        TraderRewardsStorage storage $ = _getTraderRewardsStorage();
        $.factory = _factory;
        $.rewardToken = _rewardToken;
        $.depositor = initialOwner;
    }

    /**
     * @notice Sets the depositor address for the contract.
     * @dev Only the owner can set the depositor address.
     * @param _depositor The address to set as the depositor.
     */
    function setDepositor(address _depositor) external onlyOwner {
        TraderRewardsStorage storage $ = _getTraderRewardsStorage();
        $.depositor = _depositor;
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
     * @notice Allows a user to claim their accrued trading rewards.
     * @dev Claims all available rewards for the sender, updates the claim timestamp, and transfers the rewards.
     * @return amount The amount of rewards claimed by the caller.
     */
    function claimReward() external returns (uint256 amount) {
        TraderRewardsStorage storage $ = _getTraderRewardsStorage();
        address user = msg.sender;

        (amount,) = claimableReward(user);

        $.nextUserClaim[user] = _currentPeriod();

        uint256 _totalClaimed = $.totalClaimed[user];
        uint256 newTotalClaimed = _totalClaimed + amount;
        $.totalClaimed[user] = newTotalClaimed;

        if (amount != 0) {
            IERC20($.rewardToken).safeTransfer(user, amount);
        }

        emit RewardClaimed(user, amount, newTotalClaimed);
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
        TraderRewardsStorage storage $ = _getTraderRewardsStorage();

        if (msg.sender != $.depositor && msg.sender != owner()) {
            revert Unauthorized();
        }

        IERC20($.rewardToken).safeTransferFrom(msg.sender, address(this), amount);

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
            $.rewardPerPeriod[period] += amountPerPeriod;
            unchecked {
                periods--;
                remainingAmount -= amountPerPeriod;
                period += DISTRIBUTION_PERIOD;
            }
        }

        if (remainingAmount != 0) {
            $.rewardPerPeriod[firstPeriod] += remainingAmount;
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
        TraderRewardsStorage storage $ = _getTraderRewardsStorage();
        uint48 from = $.nextUserClaim[account];
        uint48 today = _currentPeriod();
        if (from >= today) {
            return (0, 0);
        }
        uint48 to = today - uint48(DISTRIBUTION_PERIOD) - 1;
        address factory_ = $.factory;
        (uint256 totalBuys, uint256 totalSells) = IMemeFactory(factory_).getAccountSpending(account, from, to);
        volume = totalBuys + totalSells;
        if (volume == 0) {
            return (0, 0);
        }
        (totalBuys, totalSells) = IMemeFactory(factory_).getTotalSpending(from, to);
        uint256 totalVolume = totalBuys + totalSells;
        amount = volume * $.rewardPerPeriod[today] / totalVolume;
    }

    /**
     * @notice Gets the address of the depositor account for the rewards.
     * @return The address of the depositor account.
     */
    function depositor() external view override returns (address) {
        return _getTraderRewardsStorage().depositor;
    }

    /**
     * @notice Gets the address of the factory contract used to track trading volumes.
     * @return The address of the factory contract.
     */
    function factory() external view override returns (address) {
        return _getTraderRewardsStorage().factory;
    }

    /**
     * @notice Gets the timestamp of the next claim period for a user.
     * @param account The account to check the next claim period for.
     * @return The timestamp of the next claim period for the account.
     */
    function nextUserClaim(address account) external view override returns (uint48) {
        return _getTraderRewardsStorage().nextUserClaim[account];
    }

    /**
     * @notice Gets the reward amount per period.
     * @param period The period to get the reward amount for.
     * @return The reward amount for the specified period.
     */
    function rewardPerPeriod(uint256 period) external view override returns (uint256) {
        return _getTraderRewardsStorage().rewardPerPeriod[period];
    }

    /**
     * @notice Gets the address of the reward token used for rewards.
     * @return The address of the reward token.
     */
    function rewardToken() external view override returns (address) {
        return _getTraderRewardsStorage().rewardToken;
    }

    /**
     * @notice Gets the total claimed rewards for an account.
     * @param account The account to get the total claimed rewards for.
     * @return The total claimed rewards for the account.
     */
    function totalClaimed(address account) external view override returns (uint256) {
        return _getTraderRewardsStorage().totalClaimed[account];
    }

    /**
     * @notice Internal function to authorize contract upgrades.
     * @dev Overrides the UUPSUpgradeable's _authorizeUpgrade to restrict upgrade authority to the contract owner.
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}

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
