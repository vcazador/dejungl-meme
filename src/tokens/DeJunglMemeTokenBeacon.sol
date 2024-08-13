// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract DeJunglMemeTokenBeacon is UpgradeableBeacon {
    constructor(address _implementation) UpgradeableBeacon(_implementation, _msgSender()) {}
}
