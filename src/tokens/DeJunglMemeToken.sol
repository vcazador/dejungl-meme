// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IMemeFactory} from "src/interfaces/IMemeFactory.sol";
import {IMemeToken} from "src/interfaces/IMemeToken.sol";

/**
 * @title DeJungl Meme Token
 * @notice ERC20 token that integrates with a Bancor-like bonding curve for dynamic pricing and Uniswap V3 for liquidity
 *         provisioning. This contract serves multiple purposes including fee collection and automated liquidity
 *         management, making it a comprehensive tool for managing meme token economics in a decentralized environment.
 * @dev The contract uses OpenZeppelin's upgradeable contracts suite to ensure that future improvements can be made
 *      without redeploying. It includes functionalities such as fee distribution and automated liquidity adjustments to
 *      maintain healthy economic dynamics.
 *      The use of a separate storage structure using Yul ensures efficient gas utilization and reduced risk of storage
 *      clashes in an upgradeable setting.
 */
contract DeJunglMemeToken is ERC20Upgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable, IMemeToken {
    uint256 public constant ETH_BOOTSTRAP = 1_000_000_000;

    // keccak256(abi.encode(uint256(keccak256("dejungle.storage.IMemeToken")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DeJunglMemeTokenStorageLocation =
        0x28d59b0b94da8a33664e88a4dd73a15682de6cc867122e4608b0ca05dda02900;

    function _getDeJunglMemeTokenStorage() private pure returns (DeJunglMemeTokenStorage storage $) {
        assembly {
            $.slot := DeJunglMemeTokenStorageLocation
        }
    }

    IMemeFactory public immutable factory;

    /**
     * @notice Fallback function to handle incoming ETH transfers.
     * @dev This function only accepts ETH from the factory address, ensuring that only authorized sources can add
     *      liquidity directly. It syncs reserves after receiving ETH to keep the contract's state consistent.
     * @custom:error UnauthorizedCaller Thrown if any address other than the factory tries to send ETH directly to the
     * contract.
     */
    receive() external payable {
        if (_msgSender() != address(factory)) revert UnauthorizedCaller();
        syncReserves();
    }

    /**
     * @notice Constructs the DeJunglMemeToken contract.
     * @dev Sets the factory address, which controls the token mechanics and interactions.
     *      It immediately disables initializers from OpenZeppelin to prevent re-initialization.
     * @param factory_ Address of the IMemeFactory contract that will manage this token's interactions.
     */
    constructor(address factory_) {
        factory = IMemeFactory(factory_);
        _disableInitializers();
    }

    /**
     * @notice Initializes the DeJunglMemeToken with necessary startup parameters.
     * @dev This function sets up the initial state of the token including its name, symbol, and token URI.
     *      It also mints the initial supply and sets up the reserves based on the factory settings.
     *      The contract must have received enough ETH to meet the bootstrap requirement before calling this function.
     * @param name_ Name of the token.
     * @param symbol_ Symbol of the token.
     * @param tokenUri URI for the token metadata.
     * @param deployer_ Address that will be granted initial ownership of the token.
     * @custom:error InitialETHSupplyTooLow Thrown if the contract does not hold enough ETH to meet the bootstrap
     * requirement.
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
     * @notice Updates the URI for token metadata.
     * @dev This function allows the owner to change the token's metadata URI. This could be necessary for updating
     *      metadata or migrating to a new metadata storage system. Access is restricted to the contract owner.
     * @param newTokenURI The new metadata URI to set for the token.
     * @custom:error UnauthorizedCaller Thrown if any address other than the factory tries to call this function.
     */
    function updateTokenURI(string calldata newTokenURI) external onlyOwner {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        $.tokenURI = newTokenURI;
    }

    /**
     * @notice Allows users to purchase tokens by sending ETH to the contract.
     * @dev This function calculates the amount of tokens to be minted based on the amount of ETH sent.
     *      It deducts a transaction fee, adds liquidity, and ensures the user receives at least the minimum expected
     *      amount of tokens.
     * @param minAmountOut Minimum amount of tokens that the user expects to receive. This prevents slippage issues.
     * @return amountOut Actual amount of tokens minted and transferred to the user.
     * @custom:event Swap Emitted when a trade is executed.
     * @custom:error MissingETH Thrown if no ETH is sent with the call.
     * @custom:error InsufficientOutputAmount Thrown if the tokens minted are less than minAmountOut after calculating
     * the purchase return.
     */
    function buy(uint256 minAmountOut) external payable nonReentrant returns (uint256 amountOut) {
        if (msg.value == 0) {
            revert MissingETH();
        }

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
     * @notice Allows users to sell tokens back to the contract in exchange for ETH.
     * @dev Calculates the amount of ETH to return based on the number of tokens sold. It also handles fees deduction
     *      and ensures minimum ETH return.
     * @param tokenAmount Amount of tokens the user wants to sell.
     * @param minEthOut Minimum amount of ETH that the user expects to receive to protect against slippage.
     * @return The amount of ETH sent back to the user after fees.
     * @custom:event Swap Emitted when a trade is executed.
     * @custom:error ZeroAmount Thrown if the token amount to sell is zero.
     * @custom:error InsufficientBalance Thrown if the user's balance is less than the amount they want to sell.
     * @custom:error LiquidityAlreadyAdded Thrown if liquidity has already been added and the contract is in liquidity
     * lock-up.
     */
    function sell(uint256 tokenAmount, uint256 minEthOut) external nonReentrant returns (uint256) {
        address seller = _msgSender();
        uint256 balance = balanceOf(seller);

        if (tokenAmount == 0) revert ZeroAmount(address(this));
        if (balance < tokenAmount) revert InsufficientBalance(address(this), tokenAmount, balance);

        _transfer(seller, address(this), tokenAmount);

        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        if ($.liquidityAdded) revert LiquidityAlreadyAdded();

        uint256 ethReturned = _swapIn($, tokenAmount, minEthOut);

        uint256 fees = factory.calculateFee(ethReturned);
        uint256 netEthValue = ethReturned - fees;

        _sendValue(payable(seller), netEthValue);
        _sendValue(factory.feeRecipient(), fees);

        factory.trackAccountSpending(seller, -int256(ethReturned));

        _syncReserves($);

        emit Swap(_msgSender(), netEthValue, tokenAmount, fees, false);
        return netEthValue;
    }

    /**
     * @notice Synchronizes the token and ETH reserves with the actual balances held by the contract.
     * @dev This function updates the storage variables to reflect the current balances. This is crucial for maintaining
     *      accurate pricing calculations and ensuring contract stability. It should be called after any action that
     *      alters the contract's balance of ETH or tokens.
     */
    function syncReserves() public {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        _syncReserves($);
    }

    /**
     * @notice Triggers a check and potentially adds liquidity to Uniswap if certain conditions are met.
     * @dev This function is part of the liquidity management strategy. It checks if the token reserves meet the
     *      threshold for adding liquidity and performs the action if necessary. This is a maintenance function that can
     *      be called by anyone.
     */
    function poke() external {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        _checkAndAddLiquidity($);
    }

    /**
     * @notice Returns the current amount of tokens held in escrow.
     * @return The amount of tokens currently held in escrow.
     */
    function getEscrowAmount() external view returns (uint256) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return $.escrowAmount;
    }

    /**
     * @notice Calculates the remaining amount of tokens that can be transferred without breaching the supply threshold.
     * @return The remaining amount of tokens that can be safely transferred.
     */
    function getRemainingAmount() external view returns (uint256) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return _getRemainingAmount($);
    }

    /**
     * @notice Provides the current ETH reserves held by the contract.
     * @return The amount of ETH currently held as reserves.
     */
    function getReserveETH() external view returns (uint256) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return $.reserveETH;
    }

    /**
     * @notice Provides the current token reserves held by the contract.
     * @return The amount of tokens currently held as reserves.
     */
    function getReserveMeme() external view returns (uint256) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return $.reserveMeme;
    }

    /**
     * @notice Calculates the current price of the token based on the reserves.
     * @return The current price of the token in ETH.
     */
    function getTokenPrice() external view returns (uint256) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return ($.reserveETH + $.virtualReserveETH) * decimals() / $.reserveMeme;
    }

    /**
     * @notice Returns the amount of virtual ETH reserves used in pricing calculations.
     * @return The amount of virtual ETH reserves.
     */
    function getVirtualReserveETH() external view returns (uint256) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return $.virtualReserveETH;
    }

    /**
     * @notice Indicates whether liquidity has already been added to the DEX for this token.
     * @return True if liquidity has been added, otherwise false.
     */
    function liquidityAdded() external view returns (bool) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return $.liquidityAdded;
    }

    /**
     * @notice Provides the current URI for accessing token metadata.
     * @return The URI string for the token metadata.
     */
    function tokenURI() external view returns (string memory) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return $.tokenURI;
    }

    /**
     * @notice Provides detailed information about the token's internal state from storage.
     * @return The storage structure containing detailed token information.
     */
    function getStoredTokenInfo() external pure returns (DeJunglMemeTokenStorage memory) {
        return _getDeJunglMemeTokenStorage();
    }

    /**
     * @notice Calculates the supply of tokens available for liquidity provisioning.
     * @dev This function subtracts the supply threshold and escrow amount from the total supply to determine
     *      how many tokens are available to be paired with ETH in liquidity pools.
     * @return The amount of tokens available for adding to liquidity pools.
     */
    function getPoolSupply() public view returns (uint256) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return totalSupply() - $.supplyThreshold - $.escrowAmount;
    }

    /**
     * @notice Adds liquidity to the DEX and burns the liquidity provider (LP) tokens received.
     * @dev This internal function is triggered by `_checkAndAddLiquidity` under certain conditions.
     *      It transfers the necessary tokens and ETH to Uniswap, creates the LP tokens, and then burns them
     *      to lock liquidity permanently.
     * @param $ The storage structure of the token representing various state variables.
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

    /**
     * @notice Checks the token reserve conditions and adds liquidity if the threshold is met.
     * @dev This internal function is part of the automated liquidity management strategy.
     *      It ensures liquidity is only added when the reserves have reached a predefined threshold,
     *      preventing premature liquidity provisioning.
     * @param $ The storage structure of the token representing various state variables.
     */
    function _checkAndAddLiquidity(DeJunglMemeTokenStorage storage $) internal {
        if (_getRemainingAmount($) == 0 && !$.liquidityAdded) {
            _addLiquidity($);
            $.liquidityAdded = true;
        }
    }

    /**
     * @notice Sends ETH to a specified recipient.
     * @dev This internal function manages the sending of ETH values to addresses. It is used primarily in the buy and
     *      sell functions to handle transfers of ETH to users and fees to the designated recipient. It ensures all
     *      transfers are successful, reverting the transaction if any send fails.
     * @param recipient The payable address of the recipient.
     * @param amount The amount of ETH to be sent.
     */
    function _sendValue(address payable recipient, uint256 amount) internal {
        if (address(this).balance < amount) {
            revert InsufficientBalance(address(0), amount, address(this).balance);
        }

        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert ETHTransferFailed();
    }

    /**
     * @notice Burns tokens in exchange for ETH based on the current reserve ratio.
     * @dev This internal function is used during a sell operation to calculate the amount of ETH a user receives for
     *      their tokens. It adjusts the reserves accordingly and ensures that the transaction respects the minimum ETH
     *      output constraint.
     * @param $ The storage structure of the token representing various state variables.
     * @param amountIn The amount of tokens to be burned.
     * @param minEthOut The minimum ETH output to guard against price slippage.
     * @return ethOut The amount of ETH returned to the user.
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
     * @notice Mints tokens in exchange for ETH based on the current reserve ratio.
     * @dev This internal function is used during a buy operation to calculate the amount of tokens a user receives for
     *      their ETH. It adjusts the reserves accordingly and ensures that the transaction respects the minimum token
     *      output constraint.
     * @param $ The storage structure of the token representing various state variables.
     * @param ethDeposit The amount of ETH deposited by the user.
     * @param minAmountOut The minimum token output to guard against price slippage.
     * @return amountOut The amount of tokens minted for the user.
     */
    function _swapOut(DeJunglMemeTokenStorage storage $, uint256 ethDeposit, uint256 minAmountOut)
        internal
        returns (uint256 amountOut)
    {
        uint256 newReserveETH = $.reserveETH + ethDeposit;
        if (newReserveETH != address(this).balance) revert UnexpectedETHBalance(newReserveETH, address(this).balance);

        amountOut = _calculatePurchaseReturn($, ethDeposit);
        if (amountOut == 0) revert InsufficientLiquidity();

        // Calculate the maximum amount that can still be transferred without exceeding the liquidity threshold
        uint256 remainingAmount = _getRemainingAmount($);
        if (remainingAmount == 0) revert InsufficientSupply();

        // If the calculated transferred amount exceeds the remaining transferred amount, cap it
        if (amountOut > remainingAmount) {
            amountOut = remainingAmount;
        }

        if (amountOut < minAmountOut) revert InsufficientOutputAmount();

        _transfer(address(this), _msgSender(), amountOut);

        return amountOut;
    }

    /**
     * @notice Synchronizes the internal reserve trackers with actual balances held by the contract.
     * @dev Updates the token and ETH reserves to match the current balance of this contract. This function supports
     *      accurate pricing and reserve tracking across the contract's operations.
     * @param $ The storage structure representing the current state of reserves.
     */
    function _syncReserves(DeJunglMemeTokenStorage storage $) internal {
        $.reserveMeme = balanceOf(address(this));
        $.reserveETH = address(this).balance;
    }

    /**
     * @notice Calculates the amount of tokens a user gets in return for their ETH deposit.
     * @dev Uses the bonding curve formula to determine the token output based on the current and virtual ETH reserves.
     *      It's crucial for ensuring the token price adjusts dynamically with each transaction.
     * @param $ The storage structure of the token.
     * @param ethDeposit The amount of ETH deposited by the user.
     * @return amountOut The number of tokens that should be minted and given to the user.
     */
    function _calculatePurchaseReturn(DeJunglMemeTokenStorage storage $, uint256 ethDeposit)
        internal
        view
        returns (uint256 amountOut)
    {
        uint256 newReserveETH = $.reserveETH + $.virtualReserveETH + ethDeposit;
        uint256 newReserveMeme = $.k / newReserveETH;
        amountOut = $.reserveMeme - newReserveMeme;
    }

    /**
     * @notice Calculates the amount of ETH a user receives in return for burning their tokens.
     * @dev This function applies the bonding curve formula to calculate the ETH returned when tokens are burned.
     *      It's critical for maintaining the token's economic model and ensuring fair returns on token sales.
     * @param $ The storage structure of the token.
     * @param amountIn The amount of tokens being sold back to the contract.
     * @return amountOut The amount of ETH to be paid out.
     */
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
     * @notice Determines the remaining amount of tokens that can be issued without exceeding the supply threshold.
     * @dev This view function helps manage the issuance of new tokens, ensuring the total circulating supply doesn't
     *      breach predefined limits.
     * @param $ The storage structure of the token.
     * @return The number of tokens that can still be minted and issued.
     */
    function _getRemainingAmount(DeJunglMemeTokenStorage storage $) internal view returns (uint256) {
        uint256 poolAmount = totalSupply() - $.supplyThreshold;
        return balanceOf(address(this)) - poolAmount;
    }
}
