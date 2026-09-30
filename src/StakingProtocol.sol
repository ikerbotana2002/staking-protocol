// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract StakingProtocol is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken;

    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public userRewardPerTokenPaid;

    uint256 public totalStaked;

    // 100 BPS = 1% diario
    uint256 public rewardRateBps = 100;

    uint256 public rewardPerTokenStored;
    uint256 public lastGlobalUpdateTime;

    // Rewards generadas globalmente y todavía no pagadas.
    uint256 public totalRewardLiability;

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

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Amount must be greater than 0");

        _updateReward(msg.sender);

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        stakedBalance[msg.sender] += amount;
        totalStaked += amount;

        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");

        require(stakedBalance[msg.sender] >= amount, "Insufficient staked balance");

        _updateReward(msg.sender);

        stakedBalance[msg.sender] -= amount;
        totalStaked -= amount;

        stakingToken.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    function claimRewards() external nonReentrant whenNotPaused {
        _updateReward(msg.sender);

        uint256 reward = rewards[msg.sender];

        require(reward > 0, "No rewards");

        // Aquí usamos el pool FÍSICO, porque estas rewards
        // ya forman parte de las liabilities.
        require(reward <= rewardPoolBalance(), "Insufficient reward pool");

        rewards[msg.sender] = 0;

        // Dejamos de deber estas rewards porque ya las pagamos.
        totalRewardLiability -= reward;

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

    // Rewards físicamente presentes:
    // balance del contrato - principal de usuarios.
    function rewardPoolBalance() public view returns (uint256) {
        uint256 contractBalance = stakingToken.balanceOf(address(this));

        if (contractBalance <= totalStaked) {
            return 0;
        }

        return contractBalance - totalStaked;
    }

    // Deuda total actual, incluyendo lo generado
    // desde la última actualización global.
    function currentRewardLiability() public view returns (uint256) {
        if (totalStaked == 0) {
            return totalRewardLiability;
        }

        uint256 currentRewardPerToken = rewardPerToken();

        uint256 difference = currentRewardPerToken - rewardPerTokenStored;

        uint256 pendingGlobalRewards = (totalStaked * difference) / 1e18;

        return totalRewardLiability + pendingGlobalRewards;
    }

    // Rewards realmente libres para el owner.
    function withdrawableRewards() public view returns (uint256) {
        uint256 pool = rewardPoolBalance();
        uint256 liability = currentRewardLiability();

        if (pool <= liability) {
            return 0;
        }

        return pool - liability;
    }

    function fundRewardPool(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        emit RewardPoolFunded(msg.sender, amount);
    }

    function withdrawUnusedRewards(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Amount must be greater than 0");

        // Consolidamos primero todas las rewards
        // generadas hasta este instante.
        _updateGlobalReward();

        require(amount <= withdrawableRewards(), "Rewards already owed to users");

        stakingToken.safeTransfer(owner(), amount);

        emit UnusedRewardsWithdrawn(owner(), amount);
    }

    function setRewardRate(uint256 newRateBps) external onlyOwner {
        require(newRateBps <= 10_000, "Reward rate too high");

        _updateGlobalReward();

        uint256 oldRate = rewardRateBps;
        rewardRateBps = newRateBps;

        emit RewardRateUpdated(oldRate, newRateBps);
    }

    function _updateGlobalReward() internal {
        uint256 newRewardPerToken = rewardPerToken();

        uint256 difference = newRewardPerToken - rewardPerTokenStored;

        if (totalStaked > 0) {
            uint256 newGlobalRewards = (totalStaked * difference) / 1e18;

            totalRewardLiability += newGlobalRewards;
        }

        rewardPerTokenStored = newRewardPerToken;

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
