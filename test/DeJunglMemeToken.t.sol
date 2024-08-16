// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Test, console} from "forge-std/Test.sol";

import {IRouter} from "src/interfaces/IRouter.sol";

import {DeJunglMemeToken} from "src/tokens/DeJunglMemeToken.sol";
import {DeJunglMemeTokenBeacon} from "src/tokens/DeJunglMemeTokenBeacon.sol";
import {DeJunglMemeFactory} from "src/DeJunglMemeFactory.sol";

import {IPairFactory} from "src/interfaces/IPairFactory.sol";
import {IVoter} from "src/interfaces/IVoter.sol";

contract DeJunglMemeTokenTest is Test {
    DeJunglMemeFactory public factory;
    DeJunglMemeToken memeToken;

    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");

    address weth = 0x4200000000000000000000000000000000000006;
    address router = 0x378926A27B15410dCf91723a4450a8316FF25cb6;
    address pairFactory = 0x7c676073854fB01a960a4AD8F72321C63F496353;
    address voter = 0xf50aA5B9f6173B85B641b420B6401C381bA330AF;
    address escrow = makeAddr("escrow");
    address payable feeRecipient = payable(makeAddr("feeReceipient"));

    string BASE_SEPOLIA_RPC_URL = vm.envString("BASE_SEPOLIA_RPC_URL");

    uint256 initVirtualReserveMeme = 0 ether;
    uint256 initVirtualReserveETH = 1.27184 ether;

    function setUp() public {
        vm.createSelectFork(BASE_SEPOLIA_RPC_URL, 14_015_000);

        vm.mockCall(router, abi.encodeCall(IRouter.weth, ()), abi.encode(weth));

        deal(deployer, 1 ether);
        vm.startPrank(deployer);

        address factoryAddress = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 3);
        DeJunglMemeToken tokenImpl = new DeJunglMemeToken(factoryAddress);
        DeJunglMemeTokenBeacon beacon = new DeJunglMemeTokenBeacon(address(tokenImpl));
        DeJunglMemeFactory factoryImpl = new DeJunglMemeFactory(address(beacon));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                DeJunglMemeFactory.initialize,
                (deployer, router, voter, escrow, feeRecipient, initVirtualReserveMeme, initVirtualReserveETH)
            )
        );

        bytes32[] memory salts = new bytes32[](1);
        salts[0] = bytes32(uint256(9980)); // _findSalt(address(proxy), 0);

        factory = DeJunglMemeFactory(address(proxy));
        factory.addSalts(salts);

        address tokenAddress = factory.createToken{value: 0.001 ether}("Test Token", "TEST", "test.png");
        memeToken = DeJunglMemeToken(payable(tokenAddress));

        vm.startPrank(IPairFactory(pairFactory).owner());
        IPairFactory(pairFactory).updatePairManager(address(factory), true);
        IVoter(voter).setGovernor(address(factory));
        vm.stopPrank();
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
        uint256 virtualReserveMeme = memeToken.getVirtualReserveMeme();

        assertEq(virtualReserveETH, initVirtualReserveETH);
        assertEq(virtualReserveMeme, initVirtualReserveMeme);
        assertEq(reserveETH, 0.991 ether);
        assertGt(reserveMeme, 600_000_000); // 600 million
    }

    function testSellMemeToken() public {
        deal(alice, 100 ether);

        uint256 minOut = 0.1 ether;

        // Alice buys and then sells MemeToken
        vm.startPrank(alice);
        memeToken.buy{value: 1 ether}(minOut);
        uint256 aliceBalance = memeToken.balanceOf(alice);
        memeToken.sell(aliceBalance, minOut);
        vm.stopPrank();

        // Check alice's balance
        aliceBalance = memeToken.balanceOf(alice);
        assertEq(aliceBalance, 0);

        // Check reserves
        uint256 reserveETH = memeToken.getReserveETH();
        uint256 reserveMeme = memeToken.getReserveMeme();

        assertApproxEqAbs(reserveETH, 0.001 ether, 10);
        assertEq(reserveMeme, 999_999_999 ether); // 999.9 million
    }

    function testBuyAndSupplyLiquidity() public {
        deal(alice, 100 ether);

        // Alice buys MemeToken
        vm.startPrank(alice);
        memeToken.buy{value: 3 ether}(1 ether);
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
        // Create an array of ETH amounts that sum to exactly 3 ETH
        uint256[] memory ethAmounts = generateRandomAmountArray(50, 3 ether);
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
        memeToken.buy{value: 1 ether}(1 ether);

        uint256 aliceBalance = memeToken.balanceOf(alice);

        uint256[] memory tokenAmounts = generateRandomAmountArray(100, aliceBalance);
        for (uint256 i = 0; i < tokenAmounts.length; i++) {
            memeToken.sell(tokenAmounts[i], 0);
        }
        vm.stopPrank();

        uint256 reserveETH = memeToken.getReserveETH();
        uint256 reserveMeme = memeToken.getReserveMeme();

        assertApproxEqAbs(reserveETH, 0.001 ether, 100);
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
        assertApproxEqAbs(reserveETH, 0.001 ether, 100);
        assertEq(reserveMeme, 999_999_999 ether);
    }
}
