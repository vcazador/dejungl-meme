// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract TraderRewards is Ownable {
    using SafeERC20 for IERC20;

    address public immutable rewardToken;

    address public offchainComputer;

    bytes32 public currentMerkleRoot;
    string public ipfsHash;

    mapping(address => uint256) public totalClaimed;
    mapping(uint256 => uint256) public rewardPerDay;

    event MerkleRootUpdated(bytes32 indexed newMerkleRoot, string ipfsHash);
    event OffchainComputerUpdated(address indexed newOffchainComputer);
    event RewardClaimed(address indexed user, uint256 amount, uint256 totalClaimed);
    event RewardDeposited(address indexed depositor, uint256 amount, uint256 from, uint256 to);

    error InvalidDistributionWindow();
    error InvalidProof();
    error UnauthorizedCaller();

    constructor(address _rewardToken, address initialOwner) Ownable(initialOwner) {
        rewardToken = _rewardToken;
    }

    function depositReward(uint256 amount) external {
        uint256 today = (block.timestamp / 1 days) * 1 days;
        uint256 from = today + 1 days;
        uint256 to = from + 7 days;
        depositReward(amount, from, to);
    }

    function depositReward(uint256 amount, uint256 from, uint256 to) public onlyOwner {
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);

        uint256 today = (block.timestamp / 1 days) * 1 days;
        uint256 firstDay = (from / 1 days) * 1 days;
        uint256 numDays = (to - from) / 1 days;

        if (firstDay <= today || numDays == 0) {
            revert InvalidDistributionWindow();
        }

        uint256 amountPerDay = amount / numDays;
        uint256 remainingAmount = amount;

        for (uint256 i = firstDay; numDays != 0; i += 1 days) {
            rewardPerDay[i] += amountPerDay;
            unchecked {
                numDays--;
                remainingAmount -= amountPerDay;
            }
        }

        if (remainingAmount != 0) {
            rewardPerDay[firstDay] += remainingAmount;
        }

        emit RewardDeposited(msg.sender, amount, firstDay, firstDay + numDays * 1 days);
    }

    function updateMerkleRoot(bytes32 merkleRoot, string memory _ipfsHash) external {
        if (msg.sender != offchainComputer) {
            revert UnauthorizedCaller();
        }
        currentMerkleRoot = merkleRoot;
        ipfsHash = _ipfsHash;
        emit MerkleRootUpdated(merkleRoot, _ipfsHash);
    }

    function updateOffchainComputer(address newOffchainComputer) external onlyOwner {
        offchainComputer = newOffchainComputer;
        emit OffchainComputerUpdated(newOffchainComputer);
    }

    function claimReward(uint256 amount, uint256 claimed, bytes32[] memory proof)
        external
        returns (uint256 adjustedAmount)
    {
        address user = msg.sender;

        _verifyProof(proof, keccak256(abi.encodePacked(user, amount, claimed)));

        uint256 _totalClaimed = totalClaimed[user];

        if (_totalClaimed == claimed) {
            adjustedAmount = amount;
        } else {
            uint256 diff = _totalClaimed - claimed;
            adjustedAmount = amount - diff;
        }

        uint256 newTotalClaimed = _totalClaimed + adjustedAmount;
        totalClaimed[user] = newTotalClaimed;

        IERC20(rewardToken).safeTransfer(user, amount);

        emit RewardClaimed(user, adjustedAmount, newTotalClaimed);
    }

    function _verifyProof(bytes32[] memory proof, bytes32 leaf) internal view {
        bytes32 computedHash = leaf;
        uint256 i;
        uint256 j = proof.length;
        while (i != j) {
            computedHash = keccak256(abi.encodePacked(computedHash, proof[i]));
            unchecked {
                i++;
            }
        }
        if (computedHash != currentMerkleRoot) {
            revert InvalidProof();
        }
    }
}
