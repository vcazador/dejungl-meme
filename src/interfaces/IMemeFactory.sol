// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

interface IMemeFactory {
    struct PairData {
        address token;
        address weth;
        address zUSD;
        address pair;
        uint256 tokenAmount;
        uint256 zUSDAmount;
        uint256 amountToken;
        uint256 amountETH;
        uint256 amountZUSD;
        uint256 liquidity;
    }

    error InvalidInitialETHReserve();
    error InvalidSalt(bytes32 salt);
    error MaxSlippage();
    error UnauthorizedCaller();
    error ZeroAddress();

    /**
     * @dev Emitted when an account's spending is tracked.
     * @param account The address of the account.
     * @param token The address of the token that was bought or sold.
     * @param amount The amount of ETH spent or received.
     */
    event AccountSpendingTracked(address indexed account, address indexed token, int256 amount);

    /**
     * @dev Emitted when liquidity is provided to Uniswap and the LP tokens are burned.
     * @param token The address of the token provided as liquidity.
     * @param burnAddress The address where the LP token is burned.
     * @param tokenAmount The amount of the token provided as liquidity.
     * @param zUSDAmount The amount of the zUSD token provided as liquidity.
     * @param ethAmount The amount of ETH.
     * @param liquidity The amount of liquidity provided in pool.
     */
    event LiquidityAddedAndBurned(
        address indexed token,
        address indexed burnAddress,
        uint256 tokenAmount,
        uint256 zUSDAmount,
        uint256 ethAmount,
        uint256 liquidity
    );

    event EscrowAmountUpdated(uint256 escrowAmount);
    event EscrowUpdated(address escrow);
    event FeeRecipientUpdated(address feeRecipient);
    event InitialVirtualReserveETHUpdated(uint256 initialVirtualReserveETH);
    event MaxSupplyUpdated(uint256 maxSupply);
    event ProtocolFeePercentageUpdated(uint256 protocolFeePercentage);
    event RouterUpdated(address router);
    event SlippageUpdated(uint256 slippage);
    event SupplyThresholdUpdated(uint256 supplyThreshold);
    event VoterUpdated(address voter);
    event ZUSDAddressUpdated(address zUSD);

    /**
     * @dev Emitted when a new DeJunglMemeToken is deployed.
     * @param tokenAddress The address of the deployed token.
     * @param deployer The address that called the createToken function.
     * @param salt The salt used to deploy the token.
     * @param initialVirtualReserveETH The minimum liquidity for the bonding curve provided as virtual reserve
     */
    event TokenDeployed(
        address indexed tokenAddress, address indexed deployer, bytes32 salt, uint256 initialVirtualReserveETH
    );

    function BURN_ADDRESS() external view returns (address);
    function FEE_PRECISION() external view returns (uint256);

    function createPair(uint256 tokenAmount, uint256 ethAmount)
        external
        payable
        returns (uint256, uint256, uint256, uint256);

    function createToken(string memory name, string memory symbol, string memory tokenUri, bytes32 salt)
        external
        payable
        returns (address proxyAddress);

    function setEscrow(address escrow_) external;
    function setEscrowAmount(uint256 escrowAmount_) external;
    function setFeeRecipient(address payable feeRecipient_) external;
    function setInitialVirtualReserveETH(uint256 initialVirtualReserveETH_) external;
    function setMaxSupply(uint256 maxSupply_) external;
    function setProtocolFeePercentage(uint256 protocolFeePercentage_) external;
    function setRouter(address router_) external;
    function setSlippage(uint256 slippage_) external;
    function setSupplyThreshold(uint256 supplyThreshold_) external;
    function setVoter(address voter_) external;
    function setZUSDAddress(address zUSD_) external;
    function trackAccountSpending(address account, int256 amount) external;

    function calculateFee(uint256 amount) external view returns (uint256);
    function dexPairs(uint256 index) external view returns (address);
    function dexPairsLength() external view returns (uint256);
    function escrow() external view returns (address);
    function escrowAmount() external view returns (uint256);
    function feeRecipient() external view returns (address payable);

    function getAccountSpending(address account, uint48 window)
        external
        view
        returns (uint208 totalBuys, uint208 totalSells);

    function getCodeHash() external view returns (bytes32);
    function initialVirtualReserveETH() external view returns (uint256);
    function isToken(address token) external view returns (bool);
    function maxSupply() external view returns (uint256);
    function protocolFeePercentage() external view returns (uint256);
    function router() external view returns (address);
    function supplyThreshold() external view returns (uint256);
    function tokens(uint256 index) external view returns (address);
    function tokensLength() external view returns (uint256);
    function validateSalt(bytes32 salt) external view returns (bool);
}
