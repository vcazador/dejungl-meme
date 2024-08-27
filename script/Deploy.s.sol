// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.25;

import {Script, console} from "forge-std/Script.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {DeJunglMemeToken} from "src/tokens/DeJunglMemeToken.sol";
import {DeJunglMemeFactory} from "src/DeJunglMemeFactory.sol";
import {EscrowVault} from "src/utils/EscrowVault.sol";
import {TraderRewards} from "src/rewards/TraderRewards.sol";

// forge script ./script/Deploy.s.sol --rpc-url $RPC_URL --slow --broadcast --verify
contract DeployScript is Script {
    address constant ROUTER = 0xbb4Bd284eE0C5075D97403e2e4b377b39E5BD324;
    address constant VOTER = 0xf50aA5B9f6173B85B641b420B6401C381bA330AF;
    address constant zUSD = 0xcCf17c47B8C21C9cFE1C31339F5EABA90dF62DDc;
    address constant JUNGL = 0x96Ebd195d703b874e606F6225B89738886282e7F;
    address payable constant FEE_RECIPIENT = payable(0xEBc5FF890E549203b9C1C7C290262fB40C3B790D); // TODO
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant PAIR_FACTORY = 0x7c676073854fB01a960a4AD8F72321C63F496353;

    uint256 privateKey;
    address deployer;

    uint256 initVirtualReserveETH = 1 ether;

    function setUp() public {
        privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.addr(privateKey);
    }

    function run() public {
        vm.startBroadcast(privateKey);
        _deployMemeFactory();
        _deployTraderRewardsDistributor();
    }

    function _deployMemeFactory() internal returns (address factoryAddress) {
        factoryAddress = _loadDeploymentAddress("DeJunglMemeFactory");

        if (factoryAddress == address(0) || !_isDeployed(factoryAddress)) {
            factoryAddress = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 5);

            EscrowVault escrowImpl = new EscrowVault();
            ERC1967Proxy escrowProxy = new ERC1967Proxy(
                address(escrowImpl),
                abi.encodeCall(EscrowVault.initialize, (deployer, factoryAddress, PAIR_FACTORY, VOTER, WETH))
            );

            DeJunglMemeToken tokenImpl = new DeJunglMemeToken(factoryAddress);
            UpgradeableBeacon beacon = new UpgradeableBeacon(address(tokenImpl), deployer);
            DeJunglMemeFactory factoryImpl = new DeJunglMemeFactory(address(beacon));
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(factoryImpl),
                abi.encodeCall(
                    DeJunglMemeFactory.initialize,
                    (deployer, ROUTER, VOTER, address(escrowProxy), FEE_RECIPIENT, zUSD, initVirtualReserveETH)
                )
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
                    DeJunglMemeToken tokenImpl = new DeJunglMemeToken(factoryAddress);
                    UpgradeableBeacon(beaconAddress).upgradeTo(address(tokenImpl));
                    _saveDeploymentAddress("DeJunglMemeTokenImplementation", address(tokenImpl));
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
                    _saveDeploymentAddress("DeJunglMemeFactoryImplementation", address(factoryImpl));
                }
            }
        }
    }

    function _deployTraderRewardsDistributor() internal {
        address rewardsAddress = _loadDeploymentAddress("TraderRewards");

        if (rewardsAddress == address(0) || !_isDeployed(rewardsAddress)) {
            TraderRewards rewards = new TraderRewards(JUNGL, deployer);
            rewards.updateOffchainComputer(deployer);
            _saveDeploymentAddress("TraderRewards", address(rewards));
        } else {
            vm.stopBroadcast();

            TraderRewards newRewards = new TraderRewards(JUNGL, deployer);
            bytes memory deployableCode = _getDeployedCode(address(newRewards));

            vm.startBroadcast(privateKey);

            bytes memory deployedCode = _getDeployedCode(rewardsAddress);

            if (keccak256(deployedCode) != keccak256(deployableCode)) {
                // TraderRewards implementation has changed
                TraderRewards rewards = new TraderRewards(JUNGL, deployer);
                rewards.updateOffchainComputer(deployer);
                _saveDeploymentAddress("TraderRewards", address(rewards));
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
