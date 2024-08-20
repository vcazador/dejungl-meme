// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IMemeFactory} from "./IMemeFactory.sol";

interface IMemeToken {
    /// @custom:storage-location erc7201:dejungle.storage.IMemeToken
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

    error ETHTransferFailed();
    error InitialETHSupplyTooLow();
    error InitialReserveTooHigh();
    error InsufficientBalance(address token, uint256 required, uint256 balance);
    error InsufficientLiquidity();
    error InsufficientOutputAmount();
    error InsufficientSupply();
    error LiquidityAlreadyAdded();
    error MissingETH();
    error UnauthorizedCaller();
    error UnexpectedETHBalance(uint256 expected, uint256 actual);
    error ZeroAmount(address token);

    /**
     * @dev Emitted when liquidity is provided to Uniswap and the LP tokens are burned.
     * @param tokenAmount The amount of the token provided as liquidity.
     * @param ethAmount The amount of ETH provided as liquidity.
     * @param zUSDAmount The amount of the zUSD token provided as liquidity.
     * @param liquidity The amount of liquidity provided in pool.
     */
    event LiquidityAddedAndBurned(uint256 tokenAmount, uint256 ethAmount, uint256 zUSDAmount, uint256 liquidity);

    /**
     * @dev Emitted when a trade is executed.
     * @param trader The address of the trader.
     * @param ethAmount The amount of ETH involved in the trade.
     * @param tokenAmount The amount of tokens involved in the trade.
     * @param fees The amount of fees collected in the trade.
     * @param isBuy Indicates whether the trade was a buy (true) or sell (false).
     */
    event Swap(address indexed trader, uint256 ethAmount, uint256 tokenAmount, uint256 fees, bool isBuy);

    function ETH_BOOTSTRAP() external view returns (uint256);

    function initialize(string memory name, string memory symbol, string memory tokenUri, address deployer)
        external
        payable;

    function buy(uint256 minAmountOut) external payable returns (uint256 amountOut);
    function sell(uint256 tokenAmount, uint256 minEthOut) external returns (uint256);
    function syncReserves() external;
    function poke() external;
    function updateTokenURI(string memory newTokenURI) external;

    function factory() external view returns (IMemeFactory);
    function getEscrowAmount() external view returns (uint256);
    function getPoolSupply() external view returns (uint256);
    function getRemainingAmount() external view returns (uint256);
    function getReserveETH() external view returns (uint256);
    function getReserveMeme() external view returns (uint256);
    function getTokenPrice() external view returns (uint256);
    function getVirtualReserveETH() external view returns (uint256);
    function liquidityAdded() external view returns (bool);
    function tokenURI() external view returns (string memory);
    function getStoredTokenInfo() external pure returns (DeJunglMemeTokenStorage memory);
}
