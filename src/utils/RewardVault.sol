// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMemeFactory} from "src/interfaces/IMemeFactory.sol";
import {IPairFactory} from "src/interfaces/IPairFactory.sol";
import {IVoter} from "src/interfaces/IVoter.sol";
import {IGuage} from "src/interfaces/IGuage.sol";

import "./Epoch.sol";

contract RewardVault is UUPSUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    struct RewardInfo {
        uint256 rewardPerSecond;
        uint256 amount;
        uint256 collectedAmount;
        uint256 lastCollected;
        uint256 nextEpoch;
    }

    /// @custom:storage-location erc7201:dejungle.storage.RewardVault
    struct RewardVaultStorage {
        address factory;
        address pairFactory;
        address voter;
        address WETH;
        address manager;
        address rewardToken;
        uint256 emittedTokensLength;
        uint256 emissionBatchLen;
        RewardInfo emissionsReward;
    }

    // keccak256(abi.encode(uint256(keccak256("dejungle.storage.RewardVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RewardVaultStorageLocation =
        0xe5b68798d6b8748fbef32b03801632651091c73338e914df6df468cdbb74d200;

    function _getRewardVaultStorageLocation() private pure returns (RewardVaultStorage storage $) {
        assembly {
            $.slot := RewardVaultStorageLocation
        }
    }

    event EmissionBatchLenUpdated(uint256 length);
    event ManagerUpdated(address indexed manager);
    event RewardsUpdated(uint256 tradingReward, uint256 emissionReward);
    event EmissionsRewardCollected(
        address indexed token, address indexed pool, address indexed gauge, uint256 rewardAmount
    );

    error ZeroAddress();
    error Unauthorized();
    error OnePerHour();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        address factory,
        address pairFactory,
        address voter,
        address weth,
        address token
    ) public initializer {
        if (
            initialOwner == address(0) || factory == address(0) || pairFactory == address(0) || weth == address(0)
                || token == address(0)
        ) {
            revert ZeroAddress();
        }

        __UUPSUpgradeable_init();
        __Ownable_init(initialOwner);

        RewardVaultStorage storage $ = _getRewardVaultStorageLocation();
        $.factory = factory;
        $.pairFactory = pairFactory;
        $.voter = voter;
        $.WETH = weth;
        $.rewardToken = token;
        $.manager = initialOwner;
        $.emissionBatchLen = 50;
    }

    modifier onlyAllowed() {
        _onlyAllowed();
        _;
    }

    function setManager(address _manager) external onlyOwner {
        RewardVaultStorage storage $ = _getRewardVaultStorageLocation();
        $.manager = _manager;
        emit ManagerUpdated(_manager);
    }

    function setEmissionBatch(uint256 len) external {
        RewardVaultStorage storage $ = _getRewardVaultStorageLocation();
        $.emissionBatchLen = len;
        emit EmissionBatchLenUpdated(len);
    }

    function notifyRewardAmount(uint256 _tradingReward, uint256 _emissionsReward) external onlyAllowed {
        uint256 totalRewards = _tradingReward + _emissionsReward;

        RewardVaultStorage storage $ = _getRewardVaultStorageLocation();

        IERC20($.rewardToken).safeTransferFrom(address(this), _msgSender(), totalRewards);

        // TODO: notify _tradingReward to trade distributor

        uint256 totalEmissionsReward = _updateEmssionReward($, _emissionsReward);

        emit RewardsUpdated(_tradingReward, totalEmissionsReward);
    }

    function _updateEmssionReward(RewardVaultStorage storage $, uint256 totalEmissionsReward)
        internal
        returns (uint256)
    {
        totalEmissionsReward += $.emissionsReward.amount - $.emissionsReward.collectedAmount;
        $.emissionsReward.amount = totalEmissionsReward;
        // Set new hourly reward rates
        $.emissionsReward.rewardPerSecond = totalEmissionsReward / EPOCH_DURATION;
        // Reset collected rewards
        $.emissionsReward.collectedAmount = 0;

        return totalEmissionsReward;
    }

    function distribute() external {
        RewardVaultStorage storage $ = _getRewardVaultStorageLocation();

        uint256 timeSinceLastCollect = block.timestamp - $.emissionsReward.lastCollected;
        if (timeSinceLastCollect < HOUR) revert OnePerHour();

        uint256 rewardAmount = timeSinceLastCollect * $.emissionsReward.rewardPerSecond;

        // Update the reward amount and timestamp
        $.emissionsReward.collectedAmount += rewardAmount;
        $.emissionsReward.lastCollected = block.timestamp;

        uint256 emittedLen;

        {
            address factory = $.factory;
            uint256 distributionLen = IMemeFactory(factory).tokensLength() - $.emittedTokensLength;

            if (distributionLen > 0) {
                uint256 amount = rewardAmount / distributionLen;
                address rewardToken = $.rewardToken;

                for (distributionLen; distributionLen != 0;) {
                    unchecked {
                        distributionLen--;
                    }
                    address token = IMemeFactory(factory).tokens(distributionLen);
                    (address pair, address gauge) = _getPairAndGauge($, token);

                    IERC20(rewardToken).approve(gauge, amount);
                    IGuage(gauge).notifyRewardAmount(rewardToken, amount);
                    emittedLen++;

                    emit EmissionsRewardCollected(token, pair, gauge, amount);
                }

                $.emittedTokensLength += emittedLen;
            }
        }
    }

    function checker() external view returns (bool canExec, bytes memory execPayload) {
        RewardVaultStorage storage $ = _getRewardVaultStorageLocation();

        uint256 nextSchedule = $.emissionsReward.lastCollected + HOUR;
        canExec = (IMemeFactory($.factory).tokensLength() > $.emittedTokensLength && nextSchedule > block.timestamp);

        if (canExec) {
            execPayload = abi.encodeWithSelector(RewardVault.distribute.selector);
        } else {
            execPayload = abi.encode(IMemeFactory($.factory).tokensLength());
        }
    }

    function _getPairAndGauge(RewardVaultStorage storage $, address token)
        internal
        view
        returns (address pair, address gauge)
    {
        pair = IPairFactory($.pairFactory).getPair(token, $.WETH, false);
        IVoter voter = IVoter($.voter);
        gauge = voter.gauges(pair);
    }

    function _onlyAllowed() internal view {
        RewardVaultStorage storage $ = _getRewardVaultStorageLocation();
        if (_msgSender() != owner() || _msgSender() != $.manager) revert Unauthorized();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
