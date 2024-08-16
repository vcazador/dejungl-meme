// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
/**
 * @title Escrow Vault
 * @dev This contract holds MemeTokens in escrow for bribe distribution.
 */

contract EscrowVault is UUPSUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:dejungle.storage.EscrowVault
    struct EscrowVaultStorage {
        mapping(address => bool) managers;
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
     * @dev Emitted when a manager is added or removed.
     * @param manager Address of the manager.
     * @param isManager Whether the address is a manager or not.
     */
    event ManagerUpdated(address indexed manager, bool isManager);

    /**
     * @dev Emitted when a manager claims tokens.
     * @param manager Address of the manager who claimed the tokens.
     * @param token Address of the bribe token.
     * @param to Address of the recipient.
     * @param amount Amount of tokens claimed.
     */
    event CollectBribe(address indexed manager, address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error UnauthorizedCaller();
    error InsufficientBalance();

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
     * - This function can only be called once due to the `initializer` modifier.
     *
     */
    function initialize(address initialOwner) public initializer {
        if (initialOwner == address(0)) {
            revert ZeroAddress();
        }

        __UUPSUpgradeable_init();
        __Ownable_init(initialOwner);
    }

    /**
     * @notice Adds or removes a manager.
     * @dev Only the contract owner can call this function.
     * @param manager The address to add or remove as a manager.
     * @param isManager Whether to add or remove the manager.
     */
    function updateManagers(address manager, bool isManager) external onlyOwner {
        EscrowVaultStorage storage $ = _getEscrowVaultStorageLocation();
        $.managers[manager] = isManager;
        emit ManagerUpdated(manager, isManager);
    }

    /**
     * @notice Allows a manager to collect bribe tokens.
     * @dev Only addresses set as managers can call this function.
     * @param amount The amount of tokens to collect.
     */
    function collectBribe(address token, address to, uint256 amount) external {
        EscrowVaultStorage storage $ = _getEscrowVaultStorageLocation();
        if (!$.managers[_msgSender()]) revert UnauthorizedCaller();

        IERC20 rewardToken = IERC20(token);

        if (amount < rewardToken.balanceOf(address(this))) revert InsufficientBalance();

        rewardToken.safeTransfer(to, amount);

        emit CollectBribe(_msgSender(), token, to, amount);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
