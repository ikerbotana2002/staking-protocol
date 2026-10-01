// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract StakingProtocol is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken;

    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public userRewardPerTokenPaid;

    uint256 public totalStaked;

    // 100 BPS = 1% diario
    uint256 public rewardRateBps = 100;

    // Índice global de rewards por token.
    uint256 public rewardPerTokenStored;

    // Último momento en el que consolidamos el índice global.
    uint256 public lastGlobalUpdateTime;

    // Rewards generadas globalmente y todavía no pagadas.
    uint256 public totalRewardLiability;

    // Resto de precisión que no llega todavía a formar
    // una unidad mínima completa de reward.
    uint256 public rewardLiabilityRemainder;

    event Staked(address indexed user, uint256 amount);

    event Unstaked(address indexed user, uint256 amount);

    event RewardsClaimed(address indexed user, uint256 amount);

    event RewardRateUpdated(uint256 oldRateBps, uint256 newRateBps);

    event RewardPoolFunded(address indexed funder, uint256 amount);

    event UnusedRewardsWithdrawn(address indexed owner, uint256 amount);

    constructor(address tokenAddress) Ownable(msg.sender) {
        require(tokenAddress != address(0), "Invalid token address");

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

        require(reward <= rewardPoolBalance(), "Insufficient reward pool");

        rewards[msg.sender] = 0;

        // Ya hemos pagado esta deuda.
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

    // Tokens físicamente disponibles para rewards.
    // No incluye el principal stakeado.
    function rewardPoolBalance() public view returns (uint256) {
        uint256 contractBalance = stakingToken.balanceOf(address(this));

        if (contractBalance <= totalStaked) {
            return 0;
        }

        return contractBalance - totalStaked;
    }

    // Deuda actual incluyendo rewards generadas
    // desde la última actualización global.
    function currentRewardLiability() public view returns (uint256) {
        (uint256 pendingRewards,) = _pendingGlobalLiability();

        return totalRewardLiability + pendingRewards;
    }

    // Rewards que realmente puede retirar el owner.
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

        // Primero consolidamos toda la deuda
        // generada hasta este instante.
        _updateGlobalReward();

        require(amount <= withdrawableRewards(), "Rewards already owed to users");

        stakingToken.safeTransfer(owner(), amount);

        emit UnusedRewardsWithdrawn(owner(), amount);
    }

    function setRewardRate(uint256 newRateBps) external onlyOwner {
        require(newRateBps <= 10_000, "Reward rate too high");

        // Cerramos el tramo con la tasa antigua.
        _updateGlobalReward();

        uint256 oldRate = rewardRateBps;

        rewardRateBps = newRateBps;

        emit RewardRateUpdated(oldRate, newRateBps);
    }

    function _updateGlobalReward() internal {
        uint256 newRewardPerToken = rewardPerToken();

        (uint256 newGlobalRewards, uint256 newRemainder) = _pendingGlobalLiability();

        totalRewardLiability += newGlobalRewards;

        rewardLiabilityRemainder = newRemainder;

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

    function _pendingGlobalLiability() internal view returns (uint256 pendingRewards, uint256 newRemainder) {
        if (totalStaked == 0) {
            return (0, rewardLiabilityRemainder);
        }

        uint256 timeElapsed = block.timestamp - lastGlobalUpdateTime;

        uint256 denominator = 10_000 * 1 days;

        uint256 numerator = (totalStaked * timeElapsed * rewardRateBps) + rewardLiabilityRemainder;

        pendingRewards = numerator / denominator;

        newRemainder = numerator % denominator;
    }
}
