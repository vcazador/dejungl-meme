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
    address payable feeRecipient = payable(makeAddr("feeReceipient"));

    function setUp() public {
        vm.mockCall(router, abi.encodeCall(IRouter.weth, ()), abi.encode(weth));

        vm.startPrank(deployer);

        address factoryAddress = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 3);
        DeJunglMemeToken tokenImpl = new DeJunglMemeToken(factoryAddress);
        DeJunglMemeTokenBeacon beacon = new DeJunglMemeTokenBeacon(address(tokenImpl));
        DeJunglMemeFactory factoryImpl = new DeJunglMemeFactory(address(beacon));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(DeJunglMemeFactory.initialize, (deployer, router, escrow, feeRecipient))
        );

        bytes32[] memory salts = new bytes32[](1);
        salts[0] = bytes32(uint256(25816)); // _findSalt(address(proxy), 0);

        factory = DeJunglMemeFactory(address(proxy));
        factory.addSalts(salts);
    }

    function test_createToken() public {
        vm.startPrank(alice);

        address tokenAddress = factory.createToken("Test Token", "TEST", "test.png", 1_000_000 ether, 10_000);

        DeJunglMemeToken token = DeJunglMemeToken(tokenAddress);

        vm.assertEq(factory.tokensLength(), 1);
        vm.assertEq(uint16(uint160(factory.tokens(0))), 0xBA5E);
        vm.assertEq(token.owner(), alice);
        vm.assertEq(token.name(), "Test Token");
        vm.assertEq(token.symbol(), "TEST");
        vm.assertEq(token.tokenURI(), "test.png");
        vm.assertEq(token.totalSupply(), 1 ether);
        vm.assertEq(token.reserveRatio(), 10_000);
        vm.assertEq(token.getRemainingMintableAmount(), 799_999_999 ether);
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
