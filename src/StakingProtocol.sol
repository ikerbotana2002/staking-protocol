// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract StakingProtocol {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken;

    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public lastUpdateTime;

    uint256 public totalStaked;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);

    constructor(address tokenAddress) {
        stakingToken = IERC20(tokenAddress);
    }

    function stake(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");

        _updateReward(msg.sender);

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        stakedBalance[msg.sender] += amount;
        totalStaked += amount;

        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        require(stakedBalance[msg.sender] >= amount, "Insufficient staked balance");

        _updateReward(msg.sender);

        stakedBalance[msg.sender] -= amount;
        totalStaked -= amount;

        stakingToken.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    function claimRewards() external {
        _updateReward(msg.sender);

        uint256 reward = rewards[msg.sender];

        require(reward > 0, "No rewards");

        require(reward <= rewardPoolBalance(), "Insufficient reward pool");

        rewards[msg.sender] = 0;

        stakingToken.safeTransfer(msg.sender, reward);

        emit RewardsClaimed(msg.sender, reward);
    }

    function earned(address user) public view returns (uint256) {
        uint256 storedRewards = rewards[user];
        uint256 lastUpdate = lastUpdateTime[user];

        if (lastUpdate == 0) {
            return storedRewards;
        }

        uint256 timeElapsed = block.timestamp - lastUpdate;

        uint256 pendingReward = (stakedBalance[user] * timeElapsed) / (100 * 1 days);

        return storedRewards + pendingReward;
    }

    function rewardPoolBalance() public view returns (uint256) {
        uint256 contractBalance = stakingToken.balanceOf(address(this));

        if (contractBalance <= totalStaked) {
            return 0;
        }

        return contractBalance - totalStaked;
    }

    function _updateReward(address user) internal {
        if (lastUpdateTime[user] == 0) {
            lastUpdateTime[user] = block.timestamp;
            return;
        }

        rewards[user] = earned(user);
        lastUpdateTime[user] = block.timestamp;
    }
}
