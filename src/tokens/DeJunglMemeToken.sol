// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {BancorFormula} from "src/bancor/BancorFormula.sol";

import {IMemeFactory} from "src/interfaces/IMemeFactory.sol";
import {IPair} from "src/interfaces/IPair.sol";
import {IPairFactory} from "src/interfaces/IPairFactory.sol";
import {IRouter} from "src/interfaces/IRouter.sol";

/**
 * @title DeJunglMemeToken
 * @dev ERC20 token with Bancor bonding curve and Uniswap V3 liquidity provisioning.
 *      The contract also provides a mechanism for fee distribution and liquidity provisioning.
 */
contract DeJunglMemeToken is ERC20Upgradeable, OwnableUpgradeable, BancorFormula {
    address public constant BURN_ADDRESS = address(0);

    /// @custom:storage-location erc7201:dejungle.storage.DeJunglMemeToken
    struct DeJunglMemeTokenStorage {
        bool liquidityAdded;
        uint32 reserveRatio;
        uint256 initialReserveBalance;
        uint256 currentReserveBalance;
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
     * @param isBuy Indicates whether the trade was a buy (true) or sell (false).
     */
    event Swap(address indexed trader, uint256 ethAmount, uint256 tokenAmount, bool isBuy);

    /**
     * @dev Emitted when liquidity is provided to Uniswap and the LP tokens are burned.
     * @param tokenAmount The amount of the token provided as liquidity.
     * @param ethAmount The amount of ETH provided as liquidity.
     * @param burnAddress The address where the LP token is burned.
     */
    event LiquidityAddedAndBurned(uint256 tokenAmount, uint256 ethAmount, address indexed burnAddress);

    error InvalidReserveRatio();
    error InitialReserveTooHigh();

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
     * @param initialReserve The initial reserve balance.
     * @param reserveRatio_ The reserve ratio for the bonding curve.
     */
    function initialize(
        string memory name_,
        string memory symbol_,
        string memory tokenUri,
        address deployer_,
        uint256 initialReserve,
        uint32 reserveRatio_
    ) external initializer {
        __ERC20_init(name_, symbol_);
        __Ownable_init(deployer_);

        if (reserveRatio_ > MAX_WEIGHT) {
            revert InvalidReserveRatio();
        }

        if (initialReserve > factory.supplyThreshold()) {
            revert InitialReserveTooHigh();
        }

        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        $.initialReserveBalance = initialReserve;
        $.currentReserveBalance = initialReserve;
        $.reserveRatio = reserveRatio_;
        $.tokenURI = tokenUri;

        _mint(factory.feeRecipient(), 1 ether);
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
     * @param minTokensOut The minimum amount of tokens expected to receive.
     * @return The amount of tokens minted.
     */
    function buyTokens(uint256 minTokensOut) external payable returns (uint256) {
        require(msg.value > 0, "Ether value must be greater than 0");

        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();

        // Check if the total supply has reached or exceeded the liquidity threshold
        require(totalSupply() < factory.supplyThreshold(), "Liquidity threshold reached");

        uint256 fee = factory.calculateFee(msg.value);
        uint256 netValue = msg.value - fee;

        _sendValue(factory.feeRecipient(), fee);
        uint256 mintedTokens = _mintTokens($, netValue, minTokensOut);

        emit Swap(_msgSender(), netValue, mintedTokens, true);
        return mintedTokens;
    }

    /**
     * @notice Allows users to sell tokens in exchange for ETH.
     * @param tokenAmount The amount of tokens to sell.
     * @param minEthOut The minimum amount of ETH expected to receive.
     * @return The amount of ETH received.
     */
    function sellTokens(uint256 tokenAmount, uint256 minEthOut) external returns (uint256) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();

        uint256 ethReturned = _burnTokens($, tokenAmount, minEthOut);

        uint256 fee = factory.calculateFee(ethReturned);
        uint256 netEth = ethReturned - fee;

        _sendValue(payable(_msgSender()), netEth);
        _sendValue(factory.feeRecipient(), fee);

        emit Swap(_msgSender(), ethReturned, tokenAmount, false);
        return netEth;
    }

    function liquidityAdded() public view returns (bool) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return $.liquidityAdded;
    }

    function reserveRatio() public view returns (uint32) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return $.reserveRatio;
    }

    function initialReserveBalance() public view returns (uint256) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return $.initialReserveBalance;
    }

    function currentReserveBalance() public view returns (uint256) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return $.currentReserveBalance;
    }

    function tokenURI() public view returns (string memory) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return $.tokenURI;
    }

    /**
     * @notice Returns the remaining amount of tokens that can be minted before reaching the supply threshold.
     * @return The remaining amount of tokens that can be minted.
     */
    function getRemainingMintableAmount() public view returns (uint256) {
        return factory.supplyThreshold() - totalSupply();
    }

    /**
     * @notice Calculates the number of tokens that will be minted for a given ETH amount.
     * @param ethAmount The amount of ETH to be used for minting.
     * @return mintAmount The amount of tokens that will be minted.
     */
    function calculateMintReturn(uint256 ethAmount) public view returns (uint256 mintAmount) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return calculatePurchaseReturn(totalSupply(), $.currentReserveBalance, $.reserveRatio, ethAmount);
    }

    /**
     * @notice Calculates the amount of ETH that will be returned for burning a given amount of tokens.
     * @param tokenAmount The amount of tokens to burn.
     * @return reimbursedAmount The amount of ETH that will be reimbursed.
     */
    function calculateBurnReturn(uint256 tokenAmount) public view returns (uint256 reimbursedAmount) {
        DeJunglMemeTokenStorage storage $ = _getDeJunglMemeTokenStorage();
        return calculateSaleReturn(totalSupply(), $.currentReserveBalance, $.reserveRatio, tokenAmount);
    }

    /**
     * @dev Internal function to mint tokens based on the ETH deposit.
     * @param $ The storage structure of the token.
     * @param ethDeposit The amount of ETH deposited.
     * @param minTokensOut The minimum amount of tokens expected to receive.
     * @return The amount of tokens minted.
     */
    function _mintTokens(DeJunglMemeTokenStorage storage $, uint256 ethDeposit, uint256 minTokensOut)
        internal
        returns (uint256)
    {
        require(ethDeposit > 0, "ETH deposit must be greater than 0");

        uint256 mintedAmount = calculateMintReturn(ethDeposit);

        // Calculate the maximum amount that can still be minted without exceeding the liquidity threshold
        uint256 remainingMintableAmount = getRemainingMintableAmount();

        // If the calculated minted amount exceeds the remaining mintable amount, cap it
        if (mintedAmount > remainingMintableAmount) {
            mintedAmount = remainingMintableAmount;
        }

        require(mintedAmount >= minTokensOut, "slippage");

        _mint(_msgSender(), mintedAmount);
        $.currentReserveBalance += ethDeposit;

        _checkAndAddLiquidity($);
        return mintedAmount;
    }

    /**
     * @dev Internal function to burn tokens and return the equivalent ETH.
     * @param $ The storage structure of the token.
     * @param tokenAmount The amount of tokens to burn.
     * @param minEthOut The minimum amount of ETH expected to receive.
     * @return The amount of ETH reimbursed.
     */
    function _burnTokens(DeJunglMemeTokenStorage storage $, uint256 tokenAmount, uint256 minEthOut)
        internal
        returns (uint256)
    {
        require(tokenAmount > 0, "Token amount must be greater than 0");
        require(balanceOf(_msgSender()) >= tokenAmount, "Insufficient token balance");

        uint256 ethReimbursed = calculateBurnReturn(tokenAmount);
        require(ethReimbursed >= minEthOut, "slippage");

        $.currentReserveBalance -= ethReimbursed;
        _burn(_msgSender(), tokenAmount);
        return ethReimbursed;
    }

    /**
     * @dev Checks if the liquidity threshold is met and provides liquidity to Uniswap if so.
     * @param $ The storage structure of the token.
     */
    function _checkAndAddLiquidity(DeJunglMemeTokenStorage storage $) internal {
        if ($.currentReserveBalance - $.initialReserveBalance >= factory.supplyThreshold() && !$.liquidityAdded) {
            _addLiquidity($);
            $.liquidityAdded = true;
        }
    }

    /**
     * @dev Provides liquidity to Uniswap and burns the LP tokens.
     * @param $ The storage structure of the token.
     */
    function _addLiquidity(DeJunglMemeTokenStorage storage $) internal {
        IRouter router = IRouter(factory.router());
        IPairFactory pairFactory = IPairFactory(router.factory());
        address weth = router.weth();
        address pair = pairFactory.getPair(address(this), weth, false);

        if (pair == address(0)) {
            pair = pairFactory.createPair(address(this), weth, false);
        }

        uint256 ethAmount = $.currentReserveBalance - $.initialReserveBalance;
        uint256 tokenAmount = 200_000_000 * (10 ** decimals());

        // TODO: send tokens to escrow account

        _mint(address(this), tokenAmount);

        // uint256 tokenAmount = (ethAmount * balanceOf(pair)) /
        //     IPair(pair).balanceOf(WETH);

        _approve(address(this), address(router), tokenAmount);

        try router.addLiquidityETH{value: ethAmount}(
            address(this),
            false,
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            BURN_ADDRESS,
            block.timestamp + 10 minutes
        ) returns (uint256 amountToken, uint256 amountETH, uint256) {
            emit LiquidityAddedAndBurned(amountToken, amountETH, BURN_ADDRESS);
        } catch {}
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
}
