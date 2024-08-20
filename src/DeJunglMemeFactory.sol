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
import {IPairFactory} from "src/interfaces/IPairFactory.sol";
import {IRouter} from "src/interfaces/IRouter.sol";
import {IVoter} from "src/interfaces/IVoter.sol";

import {DeJunglMemeToken} from "./tokens/DeJunglMemeToken.sol";

/**
 * @title DeJunglMemeFactory
 * @dev This contract allows the deployment of new DeJunglMemeToken contracts with specified parameters.
 */
contract DeJunglMemeFactory is UUPSUpgradeable, OwnableUpgradeable, IMemeFactory {
    using Checkpoints for Checkpoints.Trace208;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    address public constant BURN_ADDRESS = address(0);
    uint256 public constant FEE_PRECISION = 1e6; // 100%

    /// @custom:storage-location erc7201:dejungle.storage.DeJunglMemeFactory
    struct DeJunglMemeFactoryStorage {
        address router;
        address voter;
        address escrow;
        address payable feeRecipient;
        address zUSD;
        uint256 protocolFeePercentage;
        uint256 maxSupply;
        uint256 supplyThreshold;
        uint256 escrowAmount;
        uint256 initialVirtualReserveETH;
        uint256 slippage;
        EnumerableSet.AddressSet tokens;
        EnumerableSet.AddressSet dexPairs;
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
     * - `initialOwner_`, `router_`, `escrow_`, and `feeRecipient_` must not be the zero address.
     * - This function can only be called once due to the `initializer` modifier.
     *
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

    function setEscrow(address escrow_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.escrow = escrow_;
        emit EscrowUpdated(escrow_);
    }

    function setEscrowAmount(uint256 escrowAmount_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.escrowAmount = escrowAmount_;
        emit EscrowAmountUpdated(escrowAmount_);
    }

    function setFeeRecipient(address payable feeRecipient_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.feeRecipient = feeRecipient_;
        emit FeeRecipientUpdated(feeRecipient_);
    }

    function setInitialVirtualReserveETH(uint256 initialVirtualReserveETH_) external onlyOwner {
        if (initialVirtualReserveETH_ == 0) revert InvalidInitialETHReserve();
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.initialVirtualReserveETH = initialVirtualReserveETH_;
        emit InitialVirtualReserveETHUpdated(initialVirtualReserveETH_);
    }

    function setMaxSupply(uint256 maxSupply_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.maxSupply = maxSupply_;
        emit MaxSupplyUpdated(maxSupply_);
    }

    function setProtocolFeePercentage(uint256 protocolFeePercentage_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.protocolFeePercentage = protocolFeePercentage_;
        emit ProtocolFeePercentageUpdated(protocolFeePercentage_);
    }

    function setRouter(address router_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.router = router_;
        emit RouterUpdated(router_);
    }

    function setSlippage(uint256 slippage_) external onlyOwner {
        if (slippage_ > FEE_PRECISION) revert MaxSlippage();
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.slippage = slippage_;
        emit SlippageUpdated(slippage_);
    }

    function setSupplyThreshold(uint256 supplyThreshold_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.supplyThreshold = supplyThreshold_;
        emit SupplyThresholdUpdated(supplyThreshold_);
    }

    function setVoter(address voter_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.voter = voter_;
        emit VoterUpdated(voter_);
    }

    function setZUSDAddress(address zUSD_) external onlyOwner {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        $.zUSD = zUSD_;
        emit ZUSDAddressUpdated(zUSD_);
    }

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

    function calculateFee(uint256 amount) external view returns (uint256) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return (amount * $.protocolFeePercentage) / FEE_PRECISION;
    }

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

    function escrowAmount() external view returns (uint256) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.escrowAmount;
    }

    function initialVirtualReserveETH() external view returns (uint256) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.initialVirtualReserveETH;
    }

    function tokens(uint256 index) external view returns (address) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.tokens.at(index);
    }

    function tokensLength() external view returns (uint256) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.tokens.length();
    }

    function dexPairs(uint256 index) external view returns (address) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.dexPairs.at(index);
    }

    function dexPairsLength() external view returns (uint256) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.dexPairs.length();
    }

    function isToken(address token) external view returns (bool) {
        DeJunglMemeFactoryStorage storage $ = _getDeJunglMemeFactoryStorage();
        return $.tokens.contains(token);
    }

    function getCodeHash() public view returns (bytes32) {
        return keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon, "")));
    }

    function validateSalt(bytes32 salt) public view returns (bool) {
        address predictedAddress =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, getCodeHash())))));

        return _endsWith(predictedAddress, 0xBA5E) && !_isDeployed(predictedAddress);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

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

        DeJunglMemeToken(payable(proxyAddress)).initialize{value: msg.value}(name, symbol, tokenUri, deployer);

        $.tokens.add(proxyAddress);

        emit TokenDeployed(proxyAddress, deployer, salt, $.initialVirtualReserveETH);
    }

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

    function _getAmountWithSlippage(DeJunglMemeFactoryStorage storage $, uint256 amount)
        internal
        view
        returns (uint256 amountWithSlippage)
    {
        amountWithSlippage = amount - ((amount * $.slippage) / FEE_PRECISION);
    }

    function _endsWith(address _addr, uint16 _suffix) private pure returns (bool) {
        return uint16(uint160(_addr)) == _suffix;
    }

    function _isDeployed(address contractAddress) private view returns (bool isDeployed) {
        // slither-disable-next-line assembly
        assembly {
            let cs := extcodesize(contractAddress)
            if iszero(iszero(cs)) { isDeployed := true }
        }
    }
}
