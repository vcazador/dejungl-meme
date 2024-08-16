// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Test, console} from "forge-std/Test.sol";

import {IRouter} from "src/interfaces/IRouter.sol";

import {DeJunglMemeToken} from "src/tokens/DeJunglMemeToken.sol";
import {DeJunglMemeTokenBeacon} from "src/tokens/DeJunglMemeTokenBeacon.sol";
import {DeJunglMemeFactory} from "src/DeJunglMemeFactory.sol";

contract DeJunglMemeFactoryTest is Test {
    DeJunglMemeFactory public factory;

    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");

    address weth = makeAddr("weth");
    address router = makeAddr("router");
    address escrow = makeAddr("escrow");
    address voter = makeAddr("voter");
    address payable feeRecipient = payable(makeAddr("feeReceipient"));

    uint256 initVirtualReserveMeme = 0 ether;
    uint256 initVirtualReserveETH = 0.8475714 ether;

    function setUp() public {
        vm.mockCall(router, abi.encodeCall(IRouter.weth, ()), abi.encode(weth));

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
        salts[0] = bytes32(uint256(25816)); // _findSalt(address(proxy), 0);

        factory = DeJunglMemeFactory(address(proxy));
        factory.addSalts(salts, false);
    }

    function test_createToken() public {
        deal(alice, 1 ether);
        vm.startPrank(alice);

        address tokenAddress = factory.createToken{value: 0.001 ether}("Test Token", "TEST", "test.png");

        DeJunglMemeToken token = DeJunglMemeToken(payable(tokenAddress));

        vm.assertEq(factory.tokensLength(), 1);
        vm.assertEq(uint16(uint160(factory.tokens(0))), 0xBA5E);
        vm.assertEq(token.owner(), alice);
        vm.assertEq(token.name(), "Test Token");
        vm.assertEq(token.symbol(), "TEST");
        vm.assertEq(token.tokenURI(), "test.png");
        vm.assertEq(token.totalSupply(), 1000_000_000 ether); // 1 Billion
        vm.assertEq(token.getRemainingAmount(), 699_999_999 ether); // 699 million
        vm.assertFalse(token.liquidityAdded());
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
}
