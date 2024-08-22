// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMemeFactory} from "./interfaces/IMemeFactory.sol";
import {IMemeToken} from "./interfaces/IMemeToken.sol";
import {IPairFactory} from "src/interfaces/IPairFactory.sol";
import {IRouter} from "src/interfaces/IRouter.sol";
import {IVoter} from "src/interfaces/IVoter.sol";

/**
 * @title DeJungl Meme Token Factory
 * @dev Manages the creation and configuration of DeJunglMemeToken instances, paired liquidity, and protocol
 *      configurations.
 *      This contract utilizes a beacon proxy pattern for deploying meme tokens, allowing for minimal
 *      deployment costs and upgradability. It also integrates with external router and voting systems to manage
 *      liquidity and governance interactions.
 * @notice This factory contract is responsible for deploying new DeJunglMemeToken contracts via a beacon proxy,
 *         managing liquidity pools on a DEX, and handling protocol-wide settings such as fees and reserves.
 */
contract DeJunglMemeFactory is UUPSUpgradeable, OwnableUpgradeable, IMemeFactory {
    using Checkpoints for Checkpoints.Trace208;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    address public constant BURN_ADDRESS = address(0);
    uint256 public constant FEE_PRECISION = 1e6; // 100%

    // keccak256(abi.encode(uint256(keccak256("dejungle.storage.IMemeFactory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DeJunglMemeFactoryStorageLocation =
        0xfb50bc60646deedfa9f054036de8a144186b478b76a0467a6eb275d121255300;

    function _getDeJunglMemeFactoryStorage() private pure returns (DeJunglMemeFactoryStorage storage $) {
        assembly {
            $.slot := DeJunglMemeFactoryStorageLocation
        }
    }

    address public immutable beacon;

    /**
     * @notice Constructs the DeJunglMemeFactory and sets the beacon address for creating new tokens.
     * @dev The constructor initializes the beacon address which points to the implementation contract used by all
     *      proxies created.
     *      It disables initializers to prevent re-initialization post deployment.
     * @param _beacon The address of the beacon contract which holds the address of the implementation logic for tokens.
     * @custom:oz-upgrades-unsafe-allow constructor Allows constructor execution in upgradeable contracts which is
     * generally discouraged in OpenZeppelin.
     */
    constructor(address _beacon) {
        beacon = _beacon;
        _disableInitializers();
    }

    /**
     * @notice Initializes the DeJunglMemeFactory with necessary operational parameters.
     * @dev Sets up initial configurations including router, escrow, fee recipient, and other parameters important for
     *      operational functionality.
     *      This function is meant to be called immediately after deployment to configure the factory settings.
     * @param initialOwner The initial owner of the contract with administrative privileges.
     * @param router_ The primary router address for interacting with decentralized exchanges.
     * @param voter_ The address of the voting contract for governance-related functionality.
     * @param escrow_ Address where the escrowed funds or tokens will be held.
     * @param feeRecipient_ Address where transaction fees are sent.
     * @param zUSD_ The address of the stablecoin used within the platform.
     * @param initialVirtualReserveETH_ Initial virtual ETH reserve used in pricing calculations for the bonding curve.
     * @custom:error ZeroAddress Thrown if any essential address is zero.
     * @custom:error InvalidInitialETHReserve Thrown if the initial virtual ETH reserve is set to zero, which is
     * invalid.
     */
    function initialize(
        address initialOwner,
        address router_,
        address voter_,
        address escrow_,
        address payable feeRecipient_,
        address zUSD_,
        uint256 initialVirtualReserveETH_
    ) public initializer {
        if (initialOwner == address(0) || router_ == address(0) || escrow_ == address(0) || feeRecipient_ == address(0))
        {
            revert ZeroAddress();
        }

        if (initialVirtualReserveETH_ == 0) revert InvalidInitialETHReserve();

        __UUPSUpgradeable_init();
        __Ownable_init(initialOwner);

        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.router = router_;
        $.voter = voter_;
        $.escrow = escrow_;
        $.protocolFeePercentage = 0.01e6;
        $.feeRecipient = feeRecipient_;
        $.zUSD = zUSD_;

        $.slippage = 0.02e6; // 2% slippage
        $.maxSupply = 1_000_000_000 ether; // 1 Billion
        $.supplyThreshold = 700_000_000 ether; // 700 Million
        $.escrowAmount = 100_000_000 ether; // 100 Million
        $.initialVirtualReserveETH = initialVirtualReserveETH_;

        emit RouterUpdated(router_);
        emit VoterUpdated(voter_);
        emit EscrowUpdated(escrow_);
        emit ProtocolFeePercentageUpdated($.protocolFeePercentage);
        emit FeeRecipientUpdated(feeRecipient_);
        emit ZUSDAddressUpdated(zUSD_);
        emit SlippageUpdated($.slippage);
        emit MaxSupplyUpdated($.maxSupply);
        emit SupplyThresholdUpdated($.supplyThreshold);
        emit EscrowAmountUpdated($.escrowAmount);
        emit InitialVirtualReserveETHUpdated(initialVirtualReserveETH_);
    }

    /**
     * @notice Updates the address of the escrow contract.
     * @dev Allows the contract owner to change the address where escrowed funds are held.
     * @param escrow_ The new escrow address.
     */
    function setEscrow(address escrow_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.escrow = escrow_;
        emit EscrowUpdated(escrow_);
    }

    /**
     * @notice Sets the amount of tokens to be held in escrow for liquidity provisions.
     * @dev Adjusts the token quantity reserved in escrow, impacting future liquidity operations.
     * @param escrowAmount_ The new amount of tokens to be escrowed.
     */
    function setEscrowAmount(uint256 escrowAmount_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.escrowAmount = escrowAmount_;
        emit EscrowAmountUpdated(escrowAmount_);
    }

    /**
     * @notice Designates a new address to receive protocol fees.
     * @dev This function updates the recipient address for transaction fees collected by the factory.
     * @param feeRecipient_ The payable address to which fees will be sent.
     */
    function setFeeRecipient(address payable feeRecipient_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.feeRecipient = feeRecipient_;
        emit FeeRecipientUpdated(feeRecipient_);
    }

    /**
     * @notice Sets the initial virtual ETH reserve used in the bonding curve calculations for new tokens.
     * @dev Adjusts the initial ETH value that influences the pricing curve of newly minted tokens.
     * @param initialVirtualReserveETH_ The new amount of virtual ETH reserves.
     * @custom:error InvalidInitialETHReserve Thrown if the new reserve amount is zero, which is not allowed.
     */
    function setInitialVirtualReserveETH(uint256 initialVirtualReserveETH_) external onlyOwner {
        if (initialVirtualReserveETH_ == 0) revert InvalidInitialETHReserve();
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.initialVirtualReserveETH = initialVirtualReserveETH_;
        emit InitialVirtualReserveETHUpdated(initialVirtualReserveETH_);
    }

    /**
     * @notice Updates the maximum supply of tokens that can be minted.
     * @dev Modifies the cap for the total number of tokens that can be issued by the factory.
     * @param maxSupply_ The new maximum supply limit.
     */
    function setMaxSupply(uint256 maxSupply_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.maxSupply = maxSupply_;
        emit MaxSupplyUpdated(maxSupply_);
    }

    /**
     * @notice Adjusts the percentage of transaction fees collected by the protocol.
     * @dev Changes the fee rate applied to transactions processed through tokens created by the factory.
     * @param protocolFeePercentage_ The new protocol fee percentage, scaled by `FEE_PRECISION`.
     */
    function setProtocolFeePercentage(uint256 protocolFeePercentage_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.protocolFeePercentage = protocolFeePercentage_;
        emit ProtocolFeePercentageUpdated(protocolFeePercentage_);
    }

    /**
     * @notice Sets the router address used for swapping and liquidity operations.
     * @dev Updates the address of the router that interfaces with the decentralized exchange.
     * @param router_ The address of the new router.
     */
    function setRouter(address router_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.router = router_;
        emit RouterUpdated(router_);
    }

    /**
     * @notice Configures the slippage tolerance used in liquidity transactions.
     * @dev Defines how much price slippage is acceptable when performing swaps and adding liquidity.
     * @param slippage_ The new slippage tolerance, as a percentage of `FEE_PRECISION`.
     * @custom:error MaxSlippage Thrown if the slippage percentage exceeds the maximum allowed (100%).
     */
    function setSlippage(uint256 slippage_) external onlyOwner {
        if (slippage_ > FEE_PRECISION) revert MaxSlippage();
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.slippage = slippage_;
        emit SlippageUpdated(slippage_);
    }

    /**
     * @notice Updates the threshold at which the supply mechanism activates additional provisions.
     * @dev Adjusts the point at which certain supply-based actions, like liquidity additions, are triggered.
     * @param supplyThreshold_ The new supply threshold.
     */
    function setSupplyThreshold(uint256 supplyThreshold_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.supplyThreshold = supplyThreshold_;
        emit SupplyThresholdUpdated(supplyThreshold_);
    }

    /**
     * @notice Updates the voter contract address used in governance interactions.
     * @dev Sets a new address for the voter contract that participates in governance decisions related to token
     *      operations.
     * @param voter_ The new voter address.
     */
    function setVoter(address voter_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.voter = voter_;
        emit VoterUpdated(voter_);
    }

    /**
     * @notice Defines the stablecoin address used in the factory's operations.
     * @dev Updates the reference to the zUSD token, which is used for pairing and liquidity provisions.
     * @param zUSD_ The address of the zUSD stablecoin.
     */
    function setZUSDAddress(address zUSD_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.zUSD = zUSD_;
        emit ZUSDAddressUpdated(zUSD_);
    }

    /**
     * @notice Tracks the spending of an account in relation to buying or selling tokens.
     * @dev Records and updates the total amount of buys or sells for an account using checkpointing to track changes
     *      over time.
     * @param account The address of the account whose spending is being tracked.
     * @param amount The amount spent or received; positive values indicate buying, negative values indicate selling.
     * @custom:error UnauthorizedCaller Thrown if the caller is not a recognized token contract.
     */
    function trackAccountSpending(address account, int256 amount) external override {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        address token = _msgSender();
        if (!$.tokens.contains(token)) {
            revert UnauthorizedCaller();
        }
        if (amount > 0) {
            uint208 totalBuys = $.buys[account].latest() + uint208(uint256(amount));
            $.buys[account].push(uint48(block.timestamp), totalBuys);
        } else {
            uint208 totalSells = $.sells[account].latest() + uint208(uint256(-amount));
            $.sells[account].push(uint48(block.timestamp), totalSells);
        }
        emit AccountSpendingTracked(account, token, amount);
    }

    /**
     * @notice Deploys a new DeJunglMemeToken contract through a BeaconProxy.
     * @dev Creates a new token proxy and initializes it with the provided parameters and initial state.
     * @param name The name of the new token.
     * @param symbol The symbol of the new token.
     * @param tokenUri URI for the token metadata.
     * @param salt A unique salt used to create a deterministic address.
     * @return proxyAddress The address of the newly created token proxy.
     * @custom:error InvalidSalt Thrown if the provided salt does not meet the validity requirements.
     */
    function createToken(string memory name, string memory symbol, string memory tokenUri, bytes32 salt)
        external
        payable
        returns (address proxyAddress)
    {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        if (!validateSalt(salt)) {
            revert InvalidSalt(salt);
        }
        proxyAddress = _createToken($, name, symbol, tokenUri, salt);
    }

    /**
     * @notice Establishes liquidity for a newly created token by pairing it with zUSD in a decentralized exchange.
     * @dev Creates or adds to a liquidity pool for a new token and zUSD, utilizing the factory's router.
     * @param tokenAmount The amount of the new token to be added to the pool.
     * @param ethAmount The amount of ETH to be swapped for zUSD and added to the pool.
     * @return A tuple with the amounts added to the liquidity pool and the liquidity tokens minted.
     * @custom:error UnauthorizedCaller Thrown if the caller is not a recognized token.
     */
    function createPair(uint256 tokenAmount, uint256 ethAmount)
        external
        payable
        returns (uint256, uint256, uint256, uint256)
    {
        address token = _msgSender();

        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        if (!$.tokens.contains(token)) {
            revert UnauthorizedCaller();
        }

        PairData memory pData;
        pData.tokenAmount = tokenAmount;
        pData.token = token;
        pData.zUSD = $.zUSD;

        IRouter pairRouter = IRouter($.router);
        pData.weth = pairRouter.weth();

        // Swap eth for zUSD token
        pData.zUSDAmount = _swap($, pairRouter, pData.weth, pData.zUSD, ethAmount);

        // create pair
        pData = _createPair($, pairRouter, pData);

        // add pair to dex pool list
        $.dexPairs.add(pData.pair);

        IVoter($.voter).createGauge(pData.pair);
        emit LiquidityAddedAndBurned(
            pData.token, BURN_ADDRESS, pData.amountToken, pData.amountZUSD, pData.amountETH, pData.liquidity
        );
        return (pData.amountToken, pData.amountETH, pData.amountZUSD, pData.liquidity);
    }

    /**
     * @notice Calculates the protocol fee for a given transaction amount.
     * @dev Applies the current protocol fee percentage to the specified amount.
     * @param amount The transaction amount from which the fee will be calculated.
     * @return The calculated fee amount.
     */
    function calculateFee(uint256 amount) external view returns (uint256) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return (amount * $.protocolFeePercentage) / FEE_PRECISION;
    }

    /**
     * @notice Retrieves the total buys and sells for an account within a specified time window.
     * @dev Calculates the buying and selling activities of an account using checkpointed data to track changes over a
     *      period.
     * @param account The address of the account to query.
     * @param window The time window in seconds to look back for activity.
     * @return totalBuys The total amount bought by the account in the specified window.
     * @return totalSells The total amount sold by the account in the specified window.
     */
    function getAccountSpending(address account, uint48 window)
        external
        view
        returns (uint208 totalBuys, uint208 totalSells)
    {
        uint48 from = uint48(block.timestamp) - window;
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        Checkpoints.Trace208 storage buys = $.buys[account];
        Checkpoints.Trace208 storage sells = $.sells[account];
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

    /**
     * @notice Retrieves a DEX pair address by its index.
     * @dev Provides access to the list of DEX pair addresses managed by the factory.
     * @param index The index of the DEX pair in the storage array.
     * @return The address of the DEX pair at the specified index.
     */
    function dexPairs(uint256 index) external view returns (address) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.dexPairs.at(index);
    }

    /**
     * @notice Returns the total number of DEX pairs associated with tokens created by the factory.
     * @dev Provides the count of all liquidity pairs established through the factory's operations.
     * @return The total number of DEX pairs registered.
     */
    function dexPairsLength() external view returns (uint256) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.dexPairs.length();
    }

    /**
     * @notice Retrieves the address of the escrow contract.
     * @dev Returns the address used to hold funds or tokens in escrow for liquidity management.
     * @return The address of the escrow contract.
     */
    function escrow() external view returns (address) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.escrow;
    }

    /**
     * @notice Retrieves the amount of tokens held in escrow.
     * @dev Provides the amount of tokens currently locked in escrow, typically for liquidity or other operational
     * needs.
     * @return The amount of tokens held in escrow.
     */
    function escrowAmount() external view returns (uint256) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.escrowAmount;
    }

    /**
     * @notice Retrieves the address where transaction fees are sent.
     * @dev Returns the address designated to receive fees accrued from token operations.
     * @return The payable address of the fee recipient.
     */
    function feeRecipient() external view returns (address payable) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.feeRecipient;
    }

    /**
     * @notice Returns the initial virtual ETH reserve used in pricing calculations.
     * @dev Provides the initial virtual reserve amount of ETH considered in the bonding curve for token pricing.
     * @return The initial virtual reserve in ETH.
     */
    function initialVirtualReserveETH() external view returns (uint256) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.initialVirtualReserveETH;
    }

    /**
     * @notice Checks if a given address is a token created by the factory.
     * @dev Verifies if the specified address is part of the tokens managed by the factory.
     * @param token The address of the token to check.
     * @return True if the address is a token created by the factory, false otherwise.
     */
    function isToken(address token) external view returns (bool) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.tokens.contains(token);
    }

    /**
     * @notice Returns the maximum supply limit for tokens created by the factory.
     * @dev Provides the cap on the number of tokens that can be issued for any single token created through the
     * factory.
     * @return The maximum supply cap.
     */
    function maxSupply() external view returns (uint256) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.maxSupply;
    }

    /**
     * @notice Returns the current protocol fee percentage.
     * @dev Provides the percentage of transactions taken as a fee, expressed as a fraction of `FEE_PRECISION`.
     * @return The current protocol fee percentage.
     */
    function protocolFeePercentage() external view returns (uint256) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.protocolFeePercentage;
    }

    /**
     * @notice Retrieves the address of the router used for DEX interactions.
     * @dev Returns the router address where token swaps and liquidity operations are directed.
     * @return The address of the current router.
     */
    function router() external view returns (address) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.router;
    }

    /**
     * @notice Returns the slippage tolerance used in liquidity transactions.
     * @dev Provides the acceptable price slippage percentage for swaps and liquidity additions.
     * @return The current slippage tolerance.
     */
    function slippage() external view returns (uint256) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.slippage;
    }

    /**
     * @notice Returns the supply threshold for liquidity management.
     * @dev Provides the point at which automatic liquidity provisions are triggered.
     * @return The supply threshold.
     */
    function supplyThreshold() external view returns (uint256) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.supplyThreshold;
    }

    /**
     * @notice Retrieves a token address by its index in the factory's registry.
     * @dev Provides access to the list of token addresses created by the factory.
     * @param index The index of the token in the storage array.
     * @return The address of the token at the specified index.
     */
    function tokens(uint256 index) external view returns (address) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.tokens.at(index);
    }

    /**
     * @notice Returns the total number of tokens created by the factory.
     * @dev Provides the count of all tokens deployed through the factory's mechanisms.
     * @return The total number of tokens created.
     */
    function tokensLength() external view returns (uint256) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.tokens.length();
    }

    /**
     * @notice Retrieves the address of the voting contract used for governance.
     * @dev Returns the address of the contract responsible for managing governance interactions.
     * @return The address of the voter contract.
     */
    function voter() external view returns (address) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.voter;
    }

    /**
     * @notice Retrieves the address of the zUSD stablecoin used in the factory.
     * @dev Returns the address of the stablecoin used for liquidity pairing and other operations.
     * @return The address of the zUSD stablecoin.
     */
    function zUSD() external view returns (address) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.zUSD;
    }

    /**
     * @notice Computes the keccak256 hash of the BeaconProxy creation bytecode concatenated with the beacon address.
     * @dev This function generates the creation code hash used in calculating the deterministic address of new proxies.
     * @return The computed hash of the BeaconProxy creation code and the beacon address.
     */
    function getCodeHash() public view returns (bytes32) {
        return keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon, "")));
    }

    /**
     * @notice Validates a given salt for creating a new token contract through a BeaconProxy.
     * @dev Ensures that the salt results in a valid and not yet deployed proxy address when used with the factory's
     *      creation code.
     * @param salt The salt to validate.
     * @return True if the salt can be used to create a proxy at a unique, undeployed address.
     */
    function validateSalt(bytes32 salt) public view returns (bool) {
        address predictedAddress =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, getCodeHash())))));

        return _endsWith(predictedAddress, 0xBA5E) && !_isDeployed(predictedAddress);
    }

    /**
     * @notice Internal function to authorize contract upgrades.
     * @dev Overrides the UUPSUpgradeable's _authorizeUpgrade to restrict upgrade authority to the contract owner.
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**
     * @notice Creates a new token by deploying a BeaconProxy.
     * @dev Deploys a new BeaconProxy using the provided salt and initializes the token with the provided parameters.
     * @param $ The storage structure containing factory settings and states.
     * @param name The name for the new token.
     * @param symbol The symbol for the new token.
     * @param tokenUri The URI for the token's metadata.
     * @param salt The salt used to create a deterministic address for the proxy.
     * @return proxyAddress The address of the newly created token proxy.
     */
    function _createToken(
        DeJunglMemeFactoryStorage storage $,
        string memory name,
        string memory symbol,
        string memory tokenUri,
        bytes32 salt
    ) internal returns (address proxyAddress) {
        BeaconProxy proxy = new BeaconProxy{salt: salt}(beacon, "");
        proxyAddress = address(proxy);

        address deployer = _msgSender();

        IMemeToken(payable(proxyAddress)).initialize{value: msg.value}(name, symbol, tokenUri, deployer);

        $.tokens.add(proxyAddress);

        emit TokenDeployed(proxyAddress, deployer, salt, $.initialVirtualReserveETH);
    }

    /**
     * @notice Creates a new liquidity pair or adds to an existing pair on a decentralized exchange.
     * @dev Manages liquidity provisioning by interfacing with a DEX router to add liquidity.
     * @param $ The factory's storage structure with system settings.
     * @param pairRouter The router interface for liquidity management.
     * @param pData Struct containing pair data including tokens and amounts.
     * @return Updated pair data including amounts and liquidity tokens.
     */
    function _createPair(DeJunglMemeFactoryStorage storage $, IRouter pairRouter, PairData memory pData)
        internal
        returns (PairData memory)
    {
        IPairFactory pairFactory = IPairFactory(pairRouter.factory());
        pData.pair = pairFactory.getPair(pData.token, pData.zUSD, false);
        if (pData.pair == address(0)) {
            pData.pair = pairFactory.createPair(pData.token, pData.zUSD, false);
        }

        // Transfer and approve tokens for adding liquidity
        IERC20(pData.token).safeTransferFrom(_msgSender(), address(this), pData.tokenAmount);
        IERC20(pData.token).approve(address(pairRouter), pData.tokenAmount);
        IERC20(pData.zUSD).approve(address(pairRouter), pData.zUSDAmount);

        (pData.amountToken, pData.amountZUSD, pData.liquidity) = pairRouter.addLiquidity(
            pData.token,
            pData.zUSD,
            false,
            pData.tokenAmount,
            pData.zUSDAmount,
            _getAmountWithSlippage($, pData.tokenAmount),
            _getAmountWithSlippage($, pData.zUSDAmount),
            BURN_ADDRESS,
            block.timestamp
        );

        return pData;
    }

    /**
     * @notice Conducts a token swap using the specified router.
     * @dev Swaps ETH for another token (zUSD in this context), applying the current slippage settings.
     * @param $ The factory storage reference.
     * @param pairRouter The router interface to perform the swap.
     * @param token0 The address of the token to swap from (ETH).
     * @param token1 The address of the token to swap to (zUSD).
     * @param ethAmount The amount of ETH to swap.
     * @return zUSDAmount The amount of zUSD obtained from the swap.
     */
    function _swap(
        DeJunglMemeFactoryStorage storage $,
        IRouter pairRouter,
        address token0,
        address token1,
        uint256 ethAmount
    ) internal returns (uint256 zUSDAmount) {
        IRouter.route[] memory route = new IRouter.route[](1);
        route[0].from = token0;
        route[0].to = token1;

        uint256[] memory amounts = pairRouter.getAmountsOut(ethAmount, route);
        uint256 amountOutMin = amounts[amounts.length - 1]; // Return the last element (zUSD amount)

        amountOutMin = _getAmountWithSlippage($, amountOutMin);

        // Swap ETH for zUSD with slippage tolerance
        amounts =
            pairRouter.swapExactETHForTokens{value: ethAmount}(amountOutMin, route, address(this), block.timestamp);

        zUSDAmount = amounts[1];
    }

    /**
     * @notice Adjusts an amount by applying the currently configured slippage tolerance.
     * @dev Reduces the amount by the percentage defined in the slippage setting to provide a minimum acceptable outcome
     *      of operations.
     * @param $ The factory storage reference.
     * @param amount The original amount before applying slippage.
     * @return amountWithSlippage The new amount after slippage reduction.
     */
    function _getAmountWithSlippage(DeJunglMemeFactoryStorage storage $, uint256 amount)
        internal
        view
        returns (uint256 amountWithSlippage)
    {
        amountWithSlippage = amount - ((amount * $.slippage) / FEE_PRECISION);
    }

    /**
     * @notice Checks if the address ends with a specified suffix.
     * @dev Utility function used in address validation to ensure proper address formatting and uniqueness constraints.
     * @param _addr The address to check.
     * @param _suffix The expected suffix of the address.
     * @return True if the address ends with the given suffix, otherwise false.
     */
    function _endsWith(address _addr, uint16 _suffix) private pure returns (bool) {
        return uint16(uint160(_addr)) == _suffix;
    }

    /**
     * @notice Determines if a contract has been deployed at a given address.
     * @dev Checks the existence of code at an address to confirm if a contract is already deployed there.
     * @param contractAddress The address to check.
     * @return isDeployed True if there is contract code at the address, false otherwise.
     */
    function _isDeployed(address contractAddress) private view returns (bool isDeployed) {
        // slither-disable-next-line assembly
        assembly {
            let cs := extcodesize(contractAddress)
            if iszero(iszero(cs)) { isDeployed := true }
        }
    }
}
