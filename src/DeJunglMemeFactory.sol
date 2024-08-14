// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IMemeFactory} from "./interfaces/IMemeFactory.sol";
import {DeJunglMemeToken} from "./tokens/DeJunglMemeToken.sol";

/**
 * @title DeJunglMemeFactory
 * @dev This contract allows the deployment of new DeJunglMemeToken contracts with specified parameters.
 */
contract DeJunglMemeFactory is UUPSUpgradeable, OwnableUpgradeable, IMemeFactory {
    using Checkpoints for Checkpoints.Trace208;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant FEE_PRECISION = 1e6; // 100%

    /// @custom:storage-location erc7201:dejungle.storage.DeJunglMemeFactory
    struct DeJunglMemeFactoryStorage {
        address router;
        address escrow;
        address payable feeRecipient;
        uint256 protocolFeePercentage;
        uint256 maxSupply;
        uint256 supplyThreshold;
        uint256 nextSaltIndex;
        bytes32[] salts;
        EnumerableSet.AddressSet tokens;
        mapping(address account => Checkpoints.Trace208) buys;
        mapping(address account => Checkpoints.Trace208) sells;
    }

    // keccak256(abi.encode(uint256(keccak256("dejungle.storage.DeJunglMemeFactory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DeJunglMemeFactoryStorageLocation =
        0x3f5bb4a39f2e4659ade97b2f3651d02293b6ef81c8b2fefb6fc6ce2ed77c7600;

    function _getDeJunglMemeFactoryStorage() private pure returns (DeJunglMemeFactoryStorage storage $) {
        assembly {
            $.slot := DeJunglMemeFactoryStorageLocation
        }
    }

    address public immutable beacon;

    event AccountSpendingTracked(address indexed account, int256 amount);

    /**
     * @dev Emitted when a new DeJunglMemeToken is deployed.
     * @param tokenAddress The address of the deployed token.
     * @param deployer The address that called the createToken function.
     * @param initialReserve The initial reserve liquidity provided to the token.
     * @param reserveRatio The reserveRatio ratio used for liquidity calculations.
     */
    event TokenDeployed(
        address indexed tokenAddress, address indexed deployer, uint256 indexed initialReserve, uint256 reserveRatio
    );

    error InvalidProxyAddress(address proxyAddress);
    error InvalidSalt(bytes32 salt);
    error NoSaltAvailable();
    error UnauthorizedCaller();
    error ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _beacon) {
        beacon = _beacon;
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with the necessary addresses and parameters.
     *         This function can only be called once, during contract initialization.
     * @dev Sets the initial owner to the deployer and initializes key addresses and supply parameters.
     *      The `initializer` modifier ensures that this function can only be called once.
     * @param router_ The address of the Uniswap router or any other necessary external contract.
     * @param escrow_ The address of the escrow contract where funds or tokens may be held.
     * @param feeRecipient_ The address where fees will be sent.
     *
     * Requirements:
     * - `router_`, `escrow_`, and `feeRecipient_` must not be the zero address.
     * - This function can only be called once due to the `initializer` modifier.
     *
     */
    function initialize(address initialOwner, address router_, address escrow_, address payable feeRecipient_)
        public
        initializer
    {
        if (initialOwner == address(0) || router_ == address(0) || escrow_ == address(0) || feeRecipient_ == address(0))
        {
            revert ZeroAddress();
        }

        __UUPSUpgradeable_init();
        __Ownable_init(initialOwner);

        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.router = router_;
        $.escrow = escrow_;
        $.protocolFeePercentage = 0.01e6;
        $.feeRecipient = feeRecipient_;

        $.maxSupply = 1_000_000_000 ether; // 1 Billion
        $.supplyThreshold = 700_000_000 ether; // 700 Million
    }

    function setRouter(address router_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.router = router_;
    }

    function setEscrow(address escrow_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.escrow = escrow_;
    }

    function setFeeRecipient(address payable feeRecipient_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.feeRecipient = feeRecipient_;
    }

    function setProtocolFeePercentage(uint256 protocolFeePercentage_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.protocolFeePercentage = protocolFeePercentage_;
    }

    function setMaxSupply(uint256 maxSupply_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.maxSupply = maxSupply_;
    }

    function setSupplyThreshold(uint256 supplyThreshold_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.supplyThreshold = supplyThreshold_;
    }

    function addSalts(bytes32[] calldata newSalts) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        for (uint256 i; i < newSalts.length; i++) {
            bytes32 salt = newSalts[i];
            if (validateSalt(salt)) {
                $.salts.push(salt);
            } else {
                revert InvalidSalt(salt);
            }
        }
    }

    function createToken(
        string memory name,
        string memory symbol,
        string memory tokenUri,
        uint256 initialVirtualReserveMeme,
        uint32 initialVirtualReserveETH
    ) external returns (address proxyAddress) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        bytes32 salt = _nextSalt($);
        BeaconProxy proxy = new BeaconProxy{salt: salt}(beacon, "");
        proxyAddress = address(proxy);

        if (!_endsWith(proxyAddress, 0xBA5E)) {
            revert InvalidProxyAddress(proxyAddress);
        }

        address deployer = _msgSender();

        DeJunglMemeToken(proxyAddress).initialize(
            name, symbol, tokenUri, deployer, initialVirtualReserveMeme, initialVirtualReserveETH
        );

        $.tokens.add(proxyAddress);

        emit TokenDeployed(proxyAddress, deployer, initialVirtualReserveMeme, initialVirtualReserveETH);
    }

    function trackAccountSpending(address account, int256 amount) external override {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        if (!$.tokens.contains(_msgSender())) {
            revert UnauthorizedCaller();
        }
        if (amount > 0) {
            uint208 totalBuys = $.buys[account].latest() + uint208(uint256(amount));
            $.buys[account].push(uint48(block.timestamp), totalBuys);
        } else {
            uint208 totalSells = $.sells[account].latest() + uint208(uint256(-amount));
            $.sells[account].push(uint48(block.timestamp), totalSells);
        }
        emit AccountSpendingTracked(account, amount);
    }

    function getAccountSpending(uint48 window) external view returns (uint208 totalBuys, uint208 totalSells) {
        uint48 from = uint48(block.timestamp) - window;
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        Checkpoints.Trace208 storage buys = $.buys[_msgSender()];
        Checkpoints.Trace208 storage sells = $.sells[_msgSender()];
        {
            uint208 current = buys.latest();
            uint208 previous = buys.lowerLookup(from);
            totalBuys = current - previous;
        }
        {
            uint208 current = sells.latest();
            uint208 previous = sells.lowerLookup(from);
            totalSells = current - previous;
        }
    }

    function calculateFee(uint256 amount) public view returns (uint256) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return (amount * $.protocolFeePercentage) / FEE_PRECISION;
    }

    function router() external view returns (address) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.router;
    }

    function escrow() external view returns (address) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.escrow;
    }

    function protocolFeePercentage() external view returns (uint256) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.protocolFeePercentage;
    }

    function feeRecipient() external view returns (address payable) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.feeRecipient;
    }

    function maxSupply() external view returns (uint256) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.maxSupply;
    }

    function supplyThreshold() external view returns (uint256) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.supplyThreshold;
    }

    function lastSalt() external view returns (bytes32) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.salts[$.salts.length - 1];
    }

    function remainingSalts() external view returns (uint256) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.salts.length - $.nextSaltIndex;
    }

    function tokens(uint256 index) external view returns (address) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.tokens.at(index);
    }

    function tokensLength() external view returns (uint256) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.tokens.length();
    }

    function isToken(address token) external view returns (bool) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.tokens.contains(token);
    }

    function validateSalt(bytes32 salt) public view returns (bool) {
        address predictedAddress = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            salt,
                            keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon, "")))
                        )
                    )
                )
            )
        );

        return _endsWith(predictedAddress, 0xBA5E);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _nextSalt(DeJunglMemeFactoryStorage storage $) internal returns (bytes32) {
        uint256 index = $.nextSaltIndex;
        if (index >= $.salts.length) {
            revert NoSaltAvailable();
        }
        $.nextSaltIndex = index + 1;
        return $.salts[index];
    }

    function _endsWith(address _addr, uint16 _suffix) private pure returns (bool) {
        return uint16(uint160(_addr)) == _suffix;
    }
}
