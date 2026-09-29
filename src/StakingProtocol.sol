// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract StakingProtocol is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken;

    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public rewards;

    // Último rewardPerToken que ya se contabilizó para cada usuario
    mapping(address => uint256) public userRewardPerTokenPaid;

    uint256 public totalStaked;

    // 100 BPS = 1% diario
    uint256 public rewardRateBps = 100;

    // Acumulador global.
    // Usamos 1e18 para mantener precisión decimal.
    uint256 public rewardPerTokenStored;

    // Última vez que actualizamos el acumulador global
    uint256 public lastGlobalUpdateTime;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);

    event RewardRateUpdated(uint256 oldRateBps, uint256 newRateBps);

    event RewardPoolFunded(address indexed funder, uint256 amount);

    event UnusedRewardsWithdrawn(address indexed owner, uint256 amount);

    constructor(address tokenAddress) Ownable(msg.sender) {
        stakingToken = IERC20(tokenAddress);
        lastGlobalUpdateTime = block.timestamp;
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

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }

        uint256 timeElapsed = block.timestamp - lastGlobalUpdateTime;

        uint256 increase = (timeElapsed * rewardRateBps * 1e18) / (10_000 * 1 days);

        return rewardPerTokenStored + increase;
    }

    function earned(address user) public view returns (uint256) {
        uint256 rewardPerTokenDifference = rewardPerToken() - userRewardPerTokenPaid[user];

        uint256 newRewards = (stakedBalance[user] * rewardPerTokenDifference) / 1e18;

        return rewards[user] + newRewards;
    }

    function rewardPoolBalance() public view returns (uint256) {
        uint256 contractBalance = stakingToken.balanceOf(address(this));

        if (contractBalance <= totalStaked) {
            return 0;
        }

        return contractBalance - totalStaked;
    }

    function fundRewardPool(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        emit RewardPoolFunded(msg.sender, amount);
    }

    function withdrawUnusedRewards(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than 0");

        require(amount <= rewardPoolBalance(), "Insufficient reward pool");

        stakingToken.safeTransfer(owner(), amount);

        emit UnusedRewardsWithdrawn(owner(), amount);
    }

    function setRewardRate(uint256 newRateBps) external onlyOwner {
        require(newRateBps <= 10_000, "Reward rate too high");

        // Consolidamos el periodo anterior
        // usando la tasa antigua.
        _updateGlobalReward();

        uint256 oldRate = rewardRateBps;
        rewardRateBps = newRateBps;

        emit RewardRateUpdated(oldRate, newRateBps);
    }

    function _updateGlobalReward() internal {
        rewardPerTokenStored = rewardPerToken();
        lastGlobalUpdateTime = block.timestamp;
    }

    function _updateReward(address user) internal {
        _updateGlobalReward();

        uint256 rewardPerTokenDifference = rewardPerTokenStored - userRewardPerTokenPaid[user];

        uint256 newRewards = (stakedBalance[user] * rewardPerTokenDifference) / 1e18;

        rewards[user] += newRewards;

        userRewardPerTokenPaid[user] = rewardPerTokenStored;
    }
}
