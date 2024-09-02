// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {Test, console} from "forge-std/Test.sol";

import {DeJunglMemeToken} from "src/tokens/DeJunglMemeToken.sol";
import {DeJunglMemeFactory} from "src/DeJunglMemeFactory.sol";
import {EscrowVault} from "src/utils/EscrowVault.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPairFactory} from "src/interfaces/IPairFactory.sol";
import {IVoter} from "src/interfaces/IVoter.sol";
import {IRouter} from "src/interfaces/IRouter.sol";

contract DeJunglMemeTokenTest is Test {
    DeJunglMemeFactory public factory;
    DeJunglMemeToken memeToken;
    EscrowVault escrow;

    uint256 constant INIT_DONATE = 0.001 ether;

    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");

    address weth = 0x4200000000000000000000000000000000000006;
    address router = 0x378926A27B15410dCf91723a4450a8316FF25cb6;
    address pairFactory = 0x7c676073854fB01a960a4AD8F72321C63F496353;
    address voter = 0xf50aA5B9f6173B85B641b420B6401C381bA330AF;
    address zUSD = 0x8BAf86620AF5164Be426315Ddf09e2e6Aa183E96;
    address payable feeRecipient = payable(makeAddr("feeReceipient"));

    string BASE_SEPOLIA_RPC_URL = vm.envString("BASE_SEPOLIA_RPC_URL");

    uint256 initVirtualReserveMeme = 0 ether;
    // uint256 initVirtualReserveETH = 0.8475714 ether;
    uint256 initVirtualReserveETH = 1 ether;

    function setUp() public {
        vm.createSelectFork(BASE_SEPOLIA_RPC_URL, 14122658);

        vm.mockCall(router, abi.encodeCall(IRouter.weth, ()), abi.encode(weth));

        deal(deployer, 1 ether);
        vm.startPrank(deployer);

        address factoryAddress = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 5);

        EscrowVault escrowImpl = new EscrowVault();
        ERC1967Proxy proxy2 = new ERC1967Proxy(
            address(escrowImpl),
            abi.encodeCall(EscrowVault.initialize, (deployer, factoryAddress, pairFactory, voter, weth))
        );
        escrow = EscrowVault(address(proxy2));

        DeJunglMemeToken tokenImpl = new DeJunglMemeToken(factoryAddress);
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(tokenImpl), deployer);
        DeJunglMemeFactory factoryImpl = new DeJunglMemeFactory();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                DeJunglMemeFactory.initialize,
                (deployer, router, voter, feeRecipient, zUSD, initVirtualReserveETH)
            )
        );

        factory = DeJunglMemeFactory(payable(address(proxy)));
        factory.setBeacon(address(beacon));
        factory.setEscrow(address(escrow));

        bytes32 testSalt = bytes32(uint256(37965)); // _findSalt(address(proxy), 0);
        address tokenAddress = factory.createToken{value: INIT_DONATE}("Test Token", "TEST", "test.png", testSalt);
        memeToken = DeJunglMemeToken(payable(tokenAddress));

        vm.startPrank(IPairFactory(pairFactory).owner());
        IPairFactory(pairFactory).updatePairManager(address(factory), true);
        IVoter(voter).setGovernor(address(factory));
        vm.stopPrank();

        _addLiquidity();
    }

    function _addLiquidity() internal {
        deal(alice, 100 ether);
        deal(zUSD, alice, 100_000 ether);

        vm.startPrank(alice);
        IERC20(zUSD).approve(router, 100_000 ether);
        IRouter(router).addLiquidityETH{value: 100 ether}(
            zUSD, false, 100_000 ether, 0, 0, alice, block.timestamp + 10 minutes
        );
        vm.stopPrank();
    }

    function _findSalt(address factory_, uint256 start) internal view returns (bytes32) {
        while (true) {
            if (DeJunglMemeFactory(factory_).validateSalt(bytes32(start))) {
                return bytes32(start);
            }
            start++;
        }
        revert();
    }

    function generateRandomAmountArray(uint256 size, uint256 amount) internal view returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](size);
        uint256 remainingETH = amount;

        for (uint256 i = 0; i < size - 1; i++) {
            // Generate a random value between 0 and the remaining ETH
            uint256 maxAmount = remainingETH / (size - i);
            amounts[i] = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, i))) % maxAmount;
            remainingETH -= amounts[i];
        }

        // Assign the remaining ETH to the last element
        amounts[size - 1] = remainingETH;

        uint256 sum = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            sum += amounts[i];
        }

        require(sum == amount, "!amount");
        return amounts;
    }

    function testETHInAmountOut() public view {
        uint256 amountOut = memeToken.getAmountOut(1 ether, address(0));
        assertGt(amountOut, 490_000_000 ether);
    }

    function testETHOutAmountOut() public {
        deal(alice, 100 ether);

        // Alice buys MemeToken
        vm.startPrank(alice);
        memeToken.buy{value: 1 ether}(1 ether);
        vm.stopPrank();

        uint256 memeBalance = memeToken.balanceOf(alice);
        uint256 amountOut = memeToken.getAmountOut(memeBalance, address(memeToken));
        assertEq(amountOut, 0.98108999901 ether);
    }

    function testBuyMemeTokenEqualSteps() public {
        uint256 ethStep = 0.1 ether;
        uint256 maxEth = 2.4 ether;
        uint256 totalEthSpent = 0;

        for (uint256 i = 0; i < 24; i++) {
            vm.deal(address(this), ethStep);
            memeToken.buy{value: ethStep}(0);
            totalEthSpent += ethStep;
            // console.log("ETH %s memeToken %s", totalEthSpent, memeToken.balanceOf(address(this)));
        }

        uint256 reserveETH = memeToken.getReserveETH();
        uint256 reserveMeme = memeToken.getReserveMeme();
        uint256 memeBalance = memeToken.balanceOf(address(memeToken));
        assertEq(reserveETH, 0);
        assertEq(reserveMeme, 0);
        assertEq(memeBalance, reserveMeme);

        assertEq(totalEthSpent, maxEth, "Total ETH spent should be 2.4 ETH");
    }

    function testBuyMemeToken() public {
        deal(alice, 100 ether);

        // Alice buys MemeToken
        vm.startPrank(alice);
        memeToken.buy{value: 1 ether}(1 ether);
        vm.stopPrank();

        // Check alice's balance
        uint256 aliceBalance = memeToken.balanceOf(alice);
        assertGt(aliceBalance, 200_000_000 ether); // 200 million

        // Check reserves
        uint256 reserveETH = memeToken.getReserveETH();
        uint256 reserveMeme = memeToken.getReserveMeme();
        uint256 virtualReserveETH = memeToken.getVirtualReserveETH();

        assertEq(virtualReserveETH, initVirtualReserveETH);
        assertEq(reserveETH, 0.991 ether);
        assertGt(reserveMeme, 600_000_000); // 600 million
    }

    function testSellMemeToken() public {
        deal(alice, 100 ether);

        uint256 minOut = 0.1 ether;

        uint256 reserveETH = memeToken.getReserveETH();
        assertApproxEqAbs(reserveETH, INIT_DONATE, 10);

        // Alice buys and then sells MemeToken
        vm.startPrank(alice);
        memeToken.buy{value: 2.35585 ether}(minOut);
        uint256 aliceBalance = memeToken.balanceOf(alice);
        memeToken.sell(aliceBalance, minOut);
        vm.stopPrank();

        // Check alice's balance
        aliceBalance = memeToken.balanceOf(alice);
        assertEq(aliceBalance, 0);

        // Check reserves
        reserveETH = memeToken.getReserveETH();
        uint256 reserveMeme = memeToken.getReserveMeme();

        assertApproxEqAbs(reserveETH, 1000000001, 10);
        assertEq(reserveMeme, 999_999_999 ether); // 999.9 million
    }

    function testBuyAndSupplyLiquidity() public {
        deal(alice, 100 ether);

        // Alice buys MemeToken
        vm.startPrank(alice);
        memeToken.buy{value: 2.357 ether}(1 ether);
        vm.stopPrank();

        // Check alice's balance
        uint256 aliceBalance = memeToken.balanceOf(alice);
        assertGt(aliceBalance, 600_000_000 ether); // 600 million

        // Check reserves
        uint256 reserveETH = memeToken.getReserveETH();
        uint256 reserveMeme = memeToken.getReserveMeme();
        uint256 memeBalance = memeToken.balanceOf(address(memeToken));

        assertEq(reserveETH, 0);
        assertEq(reserveMeme, 0);
        assertEq(memeBalance, reserveMeme);
    }

    function testBuyAndSupplyLiquidityWithRandomAmount() public {
        // Create an array of ETH amounts that sum to exactly 2 ETH
        uint256[] memory ethAmounts = generateRandomAmountArray(50, 2.357 ether);
        deal(alice, 10 ether);

        vm.startPrank(alice);
        for (uint256 i = 0; i < ethAmounts.length; i++) {
            uint256 maxOut = (ethAmounts[i] * 9500) / 10000;
            memeToken.buy{value: ethAmounts[i]}(maxOut);
        }
        vm.stopPrank();

        uint256 reserveETH = memeToken.getReserveETH();
        uint256 reserveMeme = memeToken.getReserveMeme();

        assertEq(reserveETH, 0 ether);
        assertEq(reserveMeme, 0 ether);
    }

    function testSellWithRandomAmount() public {
        deal(alice, 10 ether);

        // Alice buys MemeToken
        vm.startPrank(alice);
        memeToken.buy{value: 1.5 ether}(1 ether);

        uint256 aliceBalance = memeToken.balanceOf(alice);

        uint256[] memory tokenAmounts = generateRandomAmountArray(100, aliceBalance);
        for (uint256 i = 0; i < tokenAmounts.length; i++) {
            memeToken.sell(tokenAmounts[i], 0);
        }
        vm.stopPrank();

        uint256 reserveETH = memeToken.getReserveETH();
        uint256 reserveMeme = memeToken.getReserveMeme();

        assertApproxEqAbs(reserveETH, 1000000001, 10);
        assertEq(reserveMeme, 999_999_999 ether);
    }

    function testBuyAndSellWithRandomAmounts() public {
        uint256[] memory ethAmounts = generateRandomAmountArray(30, 1 ether);

        deal(alice, 10 ether);
        vm.startPrank(alice);
        for (uint256 i = 0; i < ethAmounts.length; i++) {
            uint256 maxOut = (ethAmounts[i] * 9500) / 10000;
            memeToken.buy{value: ethAmounts[i]}(maxOut);
        }

        uint256 reserveETH = memeToken.getReserveETH();
        uint256 reserveMeme = memeToken.getReserveMeme();

        assertApproxEqAbs(reserveETH, 0.991 ether, 100);
        assertGt(reserveMeme, 600_000_000);

        uint256 aliceBalance = memeToken.balanceOf(alice);
        uint256[] memory tokenAmounts = generateRandomAmountArray(60, aliceBalance);
        for (uint256 i = 0; i < tokenAmounts.length; i++) {
            memeToken.sell(tokenAmounts[i], 0);
        }
        vm.stopPrank();

        reserveETH = memeToken.getReserveETH();
        reserveMeme = memeToken.getReserveMeme();
        assertApproxEqAbs(reserveETH, 1000000001, 10);
        assertEq(reserveMeme, 999_999_999 ether);
    }
}
