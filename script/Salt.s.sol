// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.25;

import {Script, console} from "forge-std/Script.sol";

import {DeJunglMemeFactory} from "src/DeJunglMemeFactory.sol";

// forge script ./script/Salt.s.sol \
//     --sig $(cast calldata "generateSalts(address,uint256,uint256)" $FACTORY 1000 100) \
//     --rpc-url $RPC_URL --slow --broadcast
contract SaltScript is Script {
    uint256 privateKey;
    address signer;

    event OwnerCall(address target, bytes data);

    function setUp() public {
        privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        signer = vm.addr(privateKey);
    }

    function generateSalts(address factory_, uint256 numSalts, uint256 batchSize) public {
        require(numSalts != 0, "numSalts must be greater than 0");
        require(batchSize != 0, "batchSize must be greater than 0");
        DeJunglMemeFactory factory = DeJunglMemeFactory(factory_);
        bool signerIsOwner = factory.owner() == signer;
        bytes32[] memory salts = new bytes32[](batchSize);
        uint256 salt;
        uint256 nextIndex;
        try factory.lastSalt() returns (bytes32 result) {
            salt = uint256(result) + 1;
        } catch {}
        uint256 newSaltsFound;
        while (newSaltsFound < numSalts) {
            if (factory.validateSalt(bytes32(salt))) {
                salts[nextIndex] = bytes32(salt);
                newSaltsFound++;
                console.log("Found salt %d of %d: %s", newSaltsFound, numSalts, salt);
                nextIndex = newSaltsFound % batchSize;
                if (nextIndex == 0) {
                    _addSalts(factory, salts, batchSize, signerIsOwner);
                }
            }
            salt++;
        }
        if (nextIndex != 0) {
            _addSalts(factory, salts, nextIndex, signerIsOwner);
        }
    }

    function _addSalts(DeJunglMemeFactory factory, bytes32[] memory salts, uint256 numSalts, bool execute) internal {
        bytes32[] memory saltsToAdd;

        if (numSalts == salts.length) {
            saltsToAdd = salts;
        } else {
            saltsToAdd = new bytes32[](numSalts);
            for (uint256 i; i < numSalts; i++) {
                saltsToAdd[i] = salts[i];
            }
        }
        if (execute) {
            vm.broadcast(privateKey);
            factory.addSalts(saltsToAdd);
        } else {
            emit OwnerCall(address(factory), abi.encodeCall(factory.addSalts, (saltsToAdd)));
        }
    }
}
