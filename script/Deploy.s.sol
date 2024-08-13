// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.25;

import {Script, console} from "forge-std/Script.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {DeJunglMemeToken} from "src/tokens/DeJunglMemeToken.sol";
import {DeJunglMemeTokenBeacon} from "src/tokens/DeJunglMemeTokenBeacon.sol";
import {DeJunglMemeFactory} from "src/DeJunglMemeFactory.sol";

// forge script ./script/Deploy.s.sol --rpc-url $RPC_URL --slow --broadcast
contract DeployScript is Script {
    address constant ROUTER = 0x8528308C9177A83cf9dcF80DC6cFA04FCDFC3FcA;
    address constant ESCROW = 0x8528308C9177A83cf9dcF80DC6cFA04FCDFC3FcA; // TODO
    address payable constant FEE_RECIPIENT = payable(0x8528308C9177A83cf9dcF80DC6cFA04FCDFC3FcA); // TODO

    uint256 privateKey;
    address deployer;

    function setUp() public {
        privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.addr(privateKey);
    }

    function run() public {
        vm.startBroadcast(privateKey);
        _deployMemeFactory();
    }

    function _deployMemeFactory() internal returns (address factoryAddress) {
        factoryAddress = _loadDeploymentAddress("DeJunglMemeFactory");

        if (factoryAddress == address(0) || !_isDeployed(factoryAddress)) {
            factoryAddress = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 3);
            DeJunglMemeToken tokenImpl = new DeJunglMemeToken(factoryAddress);
            DeJunglMemeTokenBeacon beacon = new DeJunglMemeTokenBeacon(address(tokenImpl));
            DeJunglMemeFactory factoryImpl = new DeJunglMemeFactory(address(beacon));
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(factoryImpl),
                abi.encodeCall(DeJunglMemeFactory.initialize, (deployer, ROUTER, ESCROW, FEE_RECIPIENT))
            );

            assert(address(proxy) == factoryAddress);

            _saveDeploymentAddress("DeJunglMemeTokenImplementation", address(tokenImpl));
            _saveDeploymentAddress("DeJunglMemeTokenBeacon", address(beacon));
            _saveDeploymentAddress("DeJunglMemeFactoryImplementation", address(factoryImpl));
            _saveDeploymentAddress("DeJunglMemeFactory", factoryAddress);
        } else {
            {
                bytes memory deployedCode = _getDeployedCode(factoryAddress);
                bytes memory deployableCode = vm.getDeployedCode("DeJunglMemeToken");

                if (keccak256(deployedCode) != keccak256(deployableCode)) {
                    // DeJunglMemeToken implementation has changed
                    address beaconAddress = _loadDeploymentAddress("DeJunglMemeTokenBeacon");
                    DeJunglMemeTokenBeacon beacon = new DeJunglMemeTokenBeacon(beaconAddress);
                    DeJunglMemeToken tokenImpl = new DeJunglMemeToken(factoryAddress);
                    beacon.upgradeTo(address(tokenImpl));
                }
            }
            {
                address factoryImplementationAddress = _loadDeploymentAddress("DeJunglMemeFactoryImplementation");
                bytes memory deployedCode = _getDeployedCode(factoryImplementationAddress);
                bytes memory deployableCode = vm.getDeployedCode("DeJunglMemeFactory");

                if (keccak256(deployedCode) != keccak256(deployableCode)) {
                    // DeJunglMemeFactory implementation has changed
                    address beaconAddress = _loadDeploymentAddress("DeJunglMemeTokenBeacon");
                    DeJunglMemeFactory factoryImpl = new DeJunglMemeFactory(beaconAddress);
                    UUPSUpgradeable(factoryAddress).upgradeToAndCall(address(factoryImpl), "");
                }
            }
        }
    }

    function _getDeployedCode(address addr) internal view returns (bytes memory code) {
        assembly {
            let size := extcodesize(addr)
            code := mload(0x40)
            mstore(0x40, add(code, and(add(add(size, 0x20), 0x1f), not(0x1f))))
            mstore(code, size)
            extcodecopy(addr, add(code, 0x20), 0, size)
        }
    }

    function _loadDeploymentAddress(string memory name) internal returns (address) {
        Chain memory _chain = getChain(block.chainid);
        string memory chainAlias = _chain.chainAlias;
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/deployments/", chainAlias, ".json");
        string memory json;
        string[] memory keys;

        if (vm.exists(path)) {
            json = vm.readFile(path);
            keys = vm.parseJsonKeys(json, "$");
        } else {
            return address(0);
        }

        for (uint256 i; i < keys.length; i++) {
            if (keccak256(bytes(keys[i])) == keccak256(bytes(name))) {
                return vm.parseJsonAddress(json, string.concat(".", keys[i]));
            }
        }

        return address(0);
    }

    function _saveDeploymentAddress(string memory name, address addr) internal {
        Chain memory _chain = getChain(block.chainid);
        string memory chainAlias = _chain.chainAlias;
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/deployments/", chainAlias, ".json");
        string memory json;
        string memory output;
        string[] memory keys;

        if (vm.exists(path)) {
            json = vm.readFile(path);
            keys = vm.parseJsonKeys(json, "$");
        } else {
            keys = new string[](0);
        }

        bool serialized;

        for (uint256 i; i < keys.length; i++) {
            if (keccak256(bytes(keys[i])) == keccak256(bytes(name))) {
                output = vm.serializeAddress(chainAlias, name, addr);
                serialized = true;
            } else {
                address value = vm.parseJsonAddress(json, string.concat(".", keys[i]));
                output = vm.serializeAddress(chainAlias, keys[i], value);
            }
        }

        if (!serialized) {
            output = vm.serializeAddress(chainAlias, name, addr);
        }

        vm.writeJson(output, path);
    }

    function _isDeployed(address contractAddress) internal view returns (bool isDeployed) {
        // slither-disable-next-line assembly
        assembly {
            let cs := extcodesize(contractAddress)
            if iszero(iszero(cs)) { isDeployed := true }
        }
    }
}
