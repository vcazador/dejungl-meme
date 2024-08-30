// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.25;

import {Script, console} from "forge-std/Script.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {DeJunglMemeToken} from "src/tokens/DeJunglMemeToken.sol";
import {DeJunglMemeFactory} from "src/DeJunglMemeFactory.sol";
import {EscrowVault} from "src/utils/EscrowVault.sol";
import {RewardVault} from "src/rewards/RewardVault.sol";
import {TraderRewards} from "src/rewards/TraderRewards.sol";

// forge script ./script/Deploy.s.sol --rpc-url $RPC_URL --slow --broadcast --verify
contract DeployScript is Script {
    bytes32 constant SALT = keccak256("dejungl-meme-dev-v1");

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

        address factory = _deployMemeFactory();
        address traderRewards = _deployTraderRewardsDistributor();
        address rewardVault = _deployRewardVault();

        if (TraderRewards(traderRewards).depositor() != rewardVault) {
            TraderRewards(traderRewards).setDepositor(rewardVault);
        }

        if (keccak256(abi.encodePacked(getChain(block.chainid).chainAlias)) == keccak256("base_sepolia")) {
            if (DeJunglMemeFactory(factory).initialVirtualReserveETH() != 0.002 ether) {
                DeJunglMemeFactory(factory).setInitialVirtualReserveETH(0.002 ether);
            }
        }
    }

    function _deployMemeFactory() internal returns (address factoryAddress) {
        bytes32 initCodeHash = hashInitCode(type(DeJunglMemeFactory).creationCode);
        factoryAddress = vm.computeCreate2Address(SALT, initCodeHash);

        address tokenImplementation = _deployTokenImplementation(factoryAddress);
        address beacon = _deployBeacon(tokenImplementation);
        address escrowVault = _deployEscrowVault(factoryAddress);

        DeJunglMemeFactory factory;

        if (!_isDeployed(factoryAddress)) {
            factory = new DeJunglMemeFactory{salt: SALT}();
            assert(address(factory) == factoryAddress);
        } else {
            factory = DeJunglMemeFactory(factoryAddress);
        }

        _saveDeploymentAddress("DeJunglMemeFactoryImplementation", factoryAddress);

        factoryAddress = _deployProxy(
            "DeJunglMemeFactory",
            factoryAddress,
            abi.encodeCall(
                factory.initialize,
                (deployer, beacon, ROUTER, VOTER, escrowVault, FEE_RECIPIENT, zUSD, initVirtualReserveETH)
            )
        );
        factory = DeJunglMemeFactory(factoryAddress);

        if (factory.escrow() != escrowVault) {
            factory.setEscrow(escrowVault);
        }
    }

    function _deployBeacon(address tokenImplementation) internal returns (address beaconAddress) {
        bytes32 initCodeHash =
            hashInitCode(type(UpgradeableBeacon).creationCode, abi.encode(tokenImplementation, deployer));
        beaconAddress = vm.computeCreate2Address(SALT, initCodeHash);

        UpgradeableBeacon beacon;

        if (!_isDeployed(beaconAddress)) {
            beacon = new UpgradeableBeacon{salt: SALT}(tokenImplementation, deployer);
            assert(address(beacon) == beaconAddress);
        } else {
            beacon = UpgradeableBeacon(beaconAddress);
        }

        if (beacon.implementation() != tokenImplementation) {
            beacon.upgradeTo(tokenImplementation);
        }

        _saveDeploymentAddress("DeJunglMemeTokenBeacon", beaconAddress);
    }

    function _deployTokenImplementation(address factory) internal returns (address tokenImplementationAddress) {
        bytes32 initCodeHash = hashInitCode(type(DeJunglMemeToken).creationCode, abi.encode(factory));
        tokenImplementationAddress = vm.computeCreate2Address(SALT, initCodeHash);

        DeJunglMemeToken tokenImpl;

        if (!_isDeployed(tokenImplementationAddress)) {
            tokenImpl = new DeJunglMemeToken{salt: SALT}(factory);
            assert(address(tokenImpl) == tokenImplementationAddress);
        } else {
            tokenImpl = DeJunglMemeToken(payable(tokenImplementationAddress));
        }

        _saveDeploymentAddress("DeJunglMemeTokenImplementation", tokenImplementationAddress);
    }

    function _deployEscrowVault(address factory) internal returns (address escrowAddress) {
        bytes32 initCodeHash = hashInitCode(type(EscrowVault).creationCode);
        escrowAddress = vm.computeCreate2Address(SALT, initCodeHash);

        EscrowVault escrowVault;

        if (!_isDeployed(escrowAddress)) {
            escrowVault = new EscrowVault{salt: SALT}();
            assert(address(escrowVault) == escrowAddress);
        } else {
            escrowVault = EscrowVault(escrowAddress);
        }

        _saveDeploymentAddress("EscrowVaultImplementation", escrowAddress);

        escrowAddress = _deployProxy(
            "EscrowVault",
            escrowAddress,
            abi.encodeCall(EscrowVault.initialize, (deployer, factory, PAIR_FACTORY, VOTER, WETH))
        );
        escrowVault = EscrowVault(escrowAddress);
    }

    function _deployTraderRewardsDistributor() internal returns (address rewardsAddress) {
        address factory = _loadDeploymentAddress("DeJunglMemeFactory");

        bytes32 initCodeHash = hashInitCode(type(TraderRewards).creationCode);
        rewardsAddress = vm.computeCreate2Address(SALT, initCodeHash);

        TraderRewards traderRewards;

        if (!_isDeployed(rewardsAddress)) {
            traderRewards = new TraderRewards{salt: SALT}();
            assert(address(traderRewards) == rewardsAddress);
        } else {
            traderRewards = TraderRewards(rewardsAddress);
        }

        _saveDeploymentAddress("TraderRewardsImplementation", rewardsAddress);

        rewardsAddress = _deployProxy(
            "TraderRewards", rewardsAddress, abi.encodeCall(TraderRewards.initialize, (deployer, factory, JUNGL))
        );
        traderRewards = TraderRewards(rewardsAddress);
    }

    function _deployRewardVault() internal returns (address vaultAddress) {
        address factory = _loadDeploymentAddress("DeJunglMemeFactory");
        address traderRewards = _loadDeploymentAddress("TraderRewards");

        bytes32 initCodeHash = hashInitCode(type(RewardVault).creationCode);
        vaultAddress = vm.computeCreate2Address(SALT, initCodeHash);

        RewardVault rewardVault;

        if (!_isDeployed(vaultAddress)) {
            rewardVault = new RewardVault{salt: SALT}();
            assert(address(rewardVault) == vaultAddress);
        } else {
            rewardVault = RewardVault(vaultAddress);
        }

        _saveDeploymentAddress("RewardVaultImplementation", vaultAddress);

        vaultAddress = _deployProxy(
            "RewardVault",
            vaultAddress,
            abi.encodeCall(RewardVault.initialize, (deployer, factory, PAIR_FACTORY, traderRewards, VOTER, WETH, JUNGL))
        );
        rewardVault = RewardVault(vaultAddress);

        if (rewardVault.traderRewards() != traderRewards) {
            rewardVault.setTraderRewards(traderRewards);
        }
    }

    function _deployProxy(string memory name, address implementation, bytes memory data)
        internal
        returns (address proxyAddress)
    {
        proxyAddress = _loadDeploymentAddress(name);

        if (_isDeployed(proxyAddress)) {
            address impl = address(uint160(uint256(vm.load(proxyAddress, ERC1967Utils.IMPLEMENTATION_SLOT))));
            if (impl != implementation) {
                UUPSUpgradeable(proxyAddress).upgradeToAndCall(implementation, "");
            }
        } else {
            bytes32 initCodeHash = hashInitCode(type(ERC1967Proxy).creationCode, abi.encode(implementation, data));
            proxyAddress = vm.computeCreate2Address(SALT, initCodeHash);

            ERC1967Proxy proxy;

            if (!_isDeployed(proxyAddress)) {
                proxy = new ERC1967Proxy{salt: SALT}(implementation, data);
                assert(address(proxy) == proxyAddress);
            } else {
                proxy = ERC1967Proxy(payable(proxyAddress));
            }

            _saveDeploymentAddress(name, proxyAddress);
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
