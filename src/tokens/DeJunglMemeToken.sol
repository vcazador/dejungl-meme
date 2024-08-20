// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IMemeFactory} from "src/interfaces/IMemeFactory.sol";

/**
 * @title DeJunglMemeToken
 * @dev ERC20 token with Bancor bonding curve and Uniswap V3 liquidity provisioning.
 *      The contract also provides a mechanism for fee distribution and liquidity provisioning.
 */
contract DeJunglMemeToken is ERC20Upgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    uint256 public constant ETH_BOOTSTRAP = 1000_000_000;

    /// @custom:storage-location erc7201:dejungle.storage.DeJunglMemeToken
    struct DeJunglMemeTokenStorage {
        bool liquidityAdded;
        uint256 reserveMeme;
        uint256 reserveETH;
        uint256 k;
        uint256 virtualReserveETH;
        uint256 supplyThreshold;
        uint256 escrowAmount;
        string tokenURI;
    }

    // keccak256(abi.encode(uint256(keccak256("dejungle.storage.DeJunglMemeToken")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DeJunglMemeTokenStorageLocation =
        0x1031b85b249f5fe42bab3fb307e428a6c7f70c13b22dce78a6a1285c6a70da00;

    function _getDeJunglMemeTokenStorage() private pure returns (DeJunglMemeTokenStorage storage $) {
        assembly {
            $.slot := DeJunglMemeTokenStorageLocation
        }
    }

    IMemeFactory public immutable factory;

    /**
     * @dev Emitted when a trade is executed.
     * @param trader The address of the trader.
     * @param ethAmount The amount of ETH involved in the trade.
     * @param tokenAmount The amount of tokens involved in the trade.
     * @param fees The amount of fees collected in the trade.
     * @param isBuy Indicates whether the trade was a buy (true) or sell (false).
     */
    event Swap(address indexed trader, uint256 ethAmount, uint256 tokenAmount, uint256 fees, bool isBuy);

    /**
     * @dev Emitted when liquidity is provided to Uniswap and the LP tokens are burned.
     * @param tokenAmount The amount of the token provided as liquidity.
     * @param ethAmount The amount of ETH provided as liquidity.
     * @param zUSDAmount The amount of the zUSD token provided as liquidity.
     * @param liquidity The amount of liquidity provided in pool.
     */
    event LiquidityAddedAndBurned(uint256 tokenAmount, uint256 ethAmount, uint256 zUSDAmount, uint256 liquidity);

    error InitialETHSupplyTooLow();
    error InitialReserveTooHigh();
    error UnauthorizedCaller();

    constructor(address factory_) {
        factory = IMemeFactory(factory_);

        _disableInitializers();
    }

    /**
     * @dev Initializes the contract with specified parameters.
     * @param name_ The name of the token.
     * @param symbol_ The symbol of the token.
     * @param tokenUri The URI for the token's metadata.
     * @param deployer_ The address of the contract deployer.
     */
    function initialize(string memory name_, string memory symbol_, string memory tokenUri, address deployer_)
        external
        payable
        initializer
    {
        __ERC20_init(name_, symbol_);
        __Ownable_init(deployer_);
        __ReentrancyGuard_init();

        if (address(this).balance < ETH_BOOTSTRAP) revert InitialETHSupplyTooLow();

        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();

        _mint(address(this), factory.maxSupply());
        _transfer(address(this), _msgSender(), 1 ether);

        $.supplyThreshold = factory.supplyThreshold();
        $.escrowAmount = factory.escrowAmount();
        $.tokenURI = tokenUri;

        uint256 vrETH = factory.initialVirtualReserveETH();
        $.virtualReserveETH = vrETH;
        $.k = totalSupply() * vrETH;

        _syncReserves($);
    }

    /**
     * @notice Allows the deployer to update the token URI.
     * @param newTokenURI The new URI for the token.
     */
    function updateTokenURI(string calldata newTokenURI) external onlyOwner {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        $.tokenURI = newTokenURI;
    }

    /**
     * @notice Allows users to buy tokens by sending ETH to the contract.
     * @param minAmountOut The minimum amount of tokens expected to receive.
     * @return amountOut The amount of tokens transferred.
     */
    function buy(uint256 minAmountOut) external payable nonReentrant returns (uint256 amountOut) {
        require(msg.value > 0, "Ether value must be greater than 0");

        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();

        factory.trackAccountSpending(_msgSender(), int256(msg.value));

        uint256 fees = factory.calculateFee(msg.value);
        uint256 netEthValue = msg.value - fees;

        _sendValue(factory.feeRecipient(), fees);
        amountOut = _swapOut($, netEthValue, minAmountOut);

        // Sync reserves before liquidity check
        _syncReserves($);
        _checkAndAddLiquidity($);

        emit Swap(_msgSender(), netEthValue, amountOut, fees, true);
    }

    /**
     * @notice Allows users to sell tokens in exchange for ETH.
     * @param tokenAmount The amount of tokens to sell.
     * @param minEthOut The minimum amount of ETH expected to receive.
     * @return The amount of ETH received.
     */
    function sell(uint256 tokenAmount, uint256 minEthOut) external nonReentrant returns (uint256) {
        require(tokenAmount > 0, "Token amount must be greater than 0");
        require(balanceOf(_msgSender()) >= tokenAmount, "Insufficient token balance");

        _transfer(_msgSender(), address(this), tokenAmount);

        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        require(!$.liquidityAdded, "Liquidity moved to JUNGL dex");

        uint256 ethReturned = _swapIn($, tokenAmount, minEthOut);

        uint256 fees = factory.calculateFee(ethReturned);
        uint256 netEthValue = ethReturned - fees;

        _sendValue(payable(_msgSender()), netEthValue);
        _sendValue(factory.feeRecipient(), fees);

        factory.trackAccountSpending(_msgSender(), -int256(ethReturned));

        _syncReserves($);

        emit Swap(_msgSender(), netEthValue, tokenAmount, fees, false);
        return netEthValue;
    }

    function syncReserves() public {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        _syncReserves($);
    }

    function poke() external {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        _checkAndAddLiquidity($);
    }

    /**
     * @dev Internal function to mint tokens based on the ETH deposit.
     * @param $ The storage structure of the token.
     * @param ethDeposit The amount of ETH deposited.
     * @param amountOut The minimum amount of tokens expected to receive.
     * @return amountOut The amount of tokens out.
     */
    function _swapOut(DeJunglMemeTokenStorage storage $, uint256 ethDeposit, uint256 minAmountOut)
        internal
        returns (uint256 amountOut)
    {
        uint256 newReserveETH = $.reserveETH + ethDeposit;
        require(newReserveETH == address(this).balance, "!eth balance");

        amountOut = _calculatePurchaseReturn($, ethDeposit);
        require(amountOut > 0, "Insufficient liquidity for this trade");

        // Calculate the maximum amount that can still be transferred without exceeding the liquidity threshold
        uint256 remainingAmount = _getRemainingAmount($);
        require(remainingAmount > 0, "!supply");

        // If the calculated transferred amount exceeds the remaining transferred amount, cap it
        if (amountOut > remainingAmount) {
            amountOut = remainingAmount;
        }

        require(amountOut >= minAmountOut, "slippage");

        _transfer(address(this), _msgSender(), amountOut);

        return amountOut;
    }

    /**
     * @dev Internal function to burn tokens and return the equivalent ETH.
     * @param $ The storage structure of the token.
     * @param amountIn The amount of tokens to burn.
     * @param minEthOut The minimum amount of ETH expected to receive.
     * @return ethOut The amount of ETH reimbursed.
     */
    function _swapIn(DeJunglMemeTokenStorage storage $, uint256 amountIn, uint256 minEthOut)
        internal
        returns (uint256 ethOut)
    {
        uint256 newReserveMeme = $.reserveMeme + amountIn;

        ethOut = _calculateSalesReturn($, amountIn);
        require(ethOut > 0 && ethOut >= minEthOut, "slippage");

        // Update reserves
        $.reserveMeme = newReserveMeme;
        $.reserveETH -= ethOut;
    }

    /**
     * @dev Checks if the liquidity threshold is met and provides liquidity to Uniswap if so.
     * @param $ The storage structure of the token.
     */
    function _checkAndAddLiquidity(DeJunglMemeTokenStorage storage $) internal {
        if (_getRemainingAmount($) == 0 && !$.liquidityAdded) {
            _addLiquidity($);
            $.liquidityAdded = true;
        }
    }

    function _calculatePurchaseReturn(DeJunglMemeTokenStorage storage $, uint256 ethDeposit)
        internal
        view
        returns (uint256 amountOut)
    {
        uint256 newReserveETH = $.reserveETH + $.virtualReserveETH + ethDeposit;
        uint256 newReserveMeme = $.k / newReserveETH;
        amountOut = $.reserveMeme - newReserveMeme;
    }

    function _calculateSalesReturn(DeJunglMemeTokenStorage storage $, uint256 amountIn)
        internal
        view
        returns (uint256 amountOut)
    {
        uint256 newReserveMeme = $.reserveMeme + amountIn;
        uint256 newReserveETH = $.k / newReserveMeme;
        amountOut = $.reserveETH + $.virtualReserveETH - newReserveETH;
    }

    /**
     * @dev Provides liquidity to Uniswap and burns the LP tokens.
     * @param $ The storage structure of the token.
     */
    function _addLiquidity(DeJunglMemeTokenStorage storage $) internal {
        uint256 ethAmount = $.reserveETH;
        uint256 escrowAmount = $.escrowAmount;
        uint256 poolSupplyAmount = getPoolSupply();

        _transfer(address(this), factory.escrow(), escrowAmount);
        _approve(address(this), address(factory), poolSupplyAmount);

        try factory.createPair{value: ethAmount}(poolSupplyAmount, ethAmount) returns (
            uint256 amountToken, uint256 amountETH, uint256 amountZUSD, uint256 liquidity
        ) {
            emit LiquidityAddedAndBurned(amountToken, amountETH, amountZUSD, liquidity);
        } catch {}

        _syncReserves($);
    }

    function _syncReserves(DeJunglMemeTokenStorage storage $) internal {
        $.reserveMeme = balanceOf(address(this));
        $.reserveETH = address(this).balance;
    }

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://consensys.net/diligence/blog/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.8.0/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions
     * pattern].
     */
    function _sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");

        (bool success,) = recipient.call{value: amount}("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }

    function _getRemainingAmount(DeJunglMemeTokenStorage storage $) internal view returns (uint256) {
        uint256 poolAmount = totalSupply() - $.supplyThreshold;
        return balanceOf(address(this)) - poolAmount;
    }

    function getStoredTokenInfo() external pure returns (DeJunglMemeTokenStorage memory) {
        return _getDeJunglMemeTokenStorage();
    }

    function tokenURI() public view returns (string memory) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return $.tokenURI;
    }

    /**
     * @notice Returns the remaining amount of tokens that can be transferred before reaching the supply threshold.
     * @return The remaining amount of tokens that can be transferred.
     */
    function getRemainingAmount() public view returns (uint256) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return _getRemainingAmount($);
    }

    function getPoolSupply() public view returns (uint256) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return totalSupply() - $.supplyThreshold - $.escrowAmount;
    }

    function getEscrowAmount() public view returns (uint256) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return $.escrowAmount;
    }

    function liquidityAdded() public view returns (bool) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return $.liquidityAdded;
    }

    function getTokenPrice() public view returns (uint256) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return ($.reserveETH + $.virtualReserveETH) * decimals() / $.reserveMeme;
    }

    function getReserveETH() public view returns (uint256) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return $.reserveETH;
    }

    function getReserveMeme() public view returns (uint256) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return $.reserveMeme;
    }

    function getVirtualReserveETH() public view returns (uint256) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return $.virtualReserveETH;
    }

    receive() external payable {
        if (_msgSender() != address(factory)) revert UnauthorizedCaller();
        syncReserves();
    }
}
