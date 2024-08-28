// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {EPOCH_DURATION} from "src/utils/Epoch.sol";
import {IBribe} from "src/interfaces/IBribe.sol";
import {IMemeFactory} from "src/interfaces/IMemeFactory.sol";
import {IPairFactory} from "src/interfaces/IPairFactory.sol";
import {IVoter} from "src/interfaces/IVoter.sol";

/**
 * @title Escrow Vault
 * @dev This contract holds MemeTokens in escrow for bribe distribution.
 */
contract EscrowVault is UUPSUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    struct RewardInfo {
        uint256 rewardsPerWeek;
        uint256 totalAmount;
        uint256 totalDisbursed;
        uint256 lastCollected;
    }

    /// @custom:storage-location erc7201:dejungle.storage.EscrowVault
    struct EscrowVaultStorage {
        address WETH;
        uint256 numWEEK;
        IMemeFactory memeFactory;
        IPairFactory pairFactory;
        IVoter voter;
        mapping(address => RewardInfo) rewards;
    }

    // keccak256(abi.encode(uint256(keccak256("dejungle.storage.EscrowVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EscrowVaultStorageLocation =
        0x8f15531755499675ef9d2087336901da5facec64d69a488ffe423a5d814cc300;

    function _getEscrowVaultStorageLocation() private pure returns (EscrowVaultStorage storage $) {
        assembly {
            $.slot := EscrowVaultStorageLocation
        }
    }

    /**
     * @dev Emitted when a bribe is collected.
     * @param token address of the token
     * @param amount bribe amount collected from escrow.
     */
    event BibeAdded(address indexed token, uint256 amount);

    /**
     * @dev Emitted when a manager collect tokens.
     * @param token Address of the bribe token.
     * @param pair Address of the token pair.
     * @param bribe Address of the bribe recipient.
     * @param amount Amount of tokens claimed.
     */
    event BribeCollected(address indexed token, address indexed pair, address indexed bribe, uint256 amount);

    error ZeroAddress();
    error UnauthorizedCaller();
    error InsufficientBalance();
    error AlreadyClaimed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with the necessary addresses and parameters.
     *         This function can only be called once, during contract initialization.
     * @dev Sets the initial owner to the deployer and initializes key addresses and supply parameters.
     *      The `initializer` modifier ensures that this function can only be called once.
     *
     * Requirements:
     * - `initialOwner` must not be the zero address.
     * - `memeFactory` must not be the zero address.
     * - `pairFactory` must not be the zero address.
     * - `voter` must not be the zero address.
     * - `weth` must not be the zero address.
     * - This function can only be called once due to the `initializer` modifier.
     *
     */
    function initialize(address initialOwner, address memeFactory, address pairFactory, address voter, address weth)
        public
        initializer
    {
        if (initialOwner == address(0) || memeFactory == address(0) || pairFactory == address(0) || weth == address(0))
        {
            revert ZeroAddress();
        }

        __UUPSUpgradeable_init();
        __Ownable_init(initialOwner);

        EscrowVaultStorage storage $ = _getEscrowVaultStorageLocation();
        $.pairFactory = IPairFactory(pairFactory);
        $.memeFactory = IMemeFactory(memeFactory);
        $.voter = IVoter(voter);
        $.WETH = weth;
        $.numWEEK = 4;
    }

    function notifyRewardAmount(address token, uint256 amount) external {
        EscrowVaultStorage storage $ = _getEscrowVaultStorageLocation();
        require($.memeFactory.isToken(_msgSender()), "!allowed");

        RewardInfo storage rewardinfo = $.rewards[token];
        require(rewardinfo.rewardsPerWeek == 0, "reward added");

        IERC20(token).safeTransferFrom(_msgSender(), address(this), amount);

        rewardinfo.rewardsPerWeek = amount / $.numWEEK;
        rewardinfo.totalAmount = amount;
        rewardinfo.lastCollected = getDistributionTime();

        emit BibeAdded(token, amount);
    }

    /**
     * @notice Allows a manager to collect bribe tokens.
     * @dev Only addresses set as managers can call this function.
     * @param token The address of tokens to collect.
     */
    function collectBribe(address token) external {
        EscrowVaultStorage storage $ = _getEscrowVaultStorageLocation();
        RewardInfo memory rewardinfo = $.rewards[token];

        if ($.rewards[token].lastCollected + EPOCH_DURATION > block.timestamp) revert AlreadyClaimed();
        if (rewardinfo.rewardsPerWeek < IERC20(token).balanceOf(address(this))) revert InsufficientBalance();

        // Update amount and increment week claimed
        $.rewards[token].totalDisbursed += rewardinfo.rewardsPerWeek;
        $.rewards[token].lastCollected = getDistributionTime();

        (address pair, address bribe) = _getPairAndBribe($, token);
        IERC20(token).forceApprove(bribe, rewardinfo.rewardsPerWeek);
        IBribe(bribe).notifyRewardAmount(token, rewardinfo.rewardsPerWeek);

        emit BribeCollected(token, pair, bribe, rewardinfo.rewardsPerWeek);
    }

    function getBribeAmount(address token) external view returns (uint256) {
        EscrowVaultStorage storage $ = _getEscrowVaultStorageLocation();
        RewardInfo memory rewardinfo = $.rewards[token];

        if (
            $.rewards[token].lastCollected + EPOCH_DURATION > block.timestamp
                || rewardinfo.totalAmount < rewardinfo.totalDisbursed
        ) return 0;

        return rewardinfo.rewardsPerWeek;
    }

    function _getPairAndBribe(EscrowVaultStorage storage $, address token)
        internal
        view
        returns (address pair, address bribe)
    {
        pair = $.pairFactory.getPair(token, $.WETH, false);
        IVoter voter = $.voter;
        address gauge = voter.gauges(pair);
        bribe = voter.internal_bribes(gauge);
    }

    function getDistributionTime() public view returns (uint256) {
        return (block.timestamp / EPOCH_DURATION) * EPOCH_DURATION;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
