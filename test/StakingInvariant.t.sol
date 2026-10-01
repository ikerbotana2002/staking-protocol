// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {StakingToken} from "../src/StakingToken.sol";
import {StakingProtocol} from "../src/StakingProtocol.sol";

contract StakingHandler is Test {
    StakingToken internal token;
    StakingProtocol internal staking;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    constructor(StakingToken _token, StakingProtocol _staking) {
        token = _token;
        staking = _staking;
    }

    function stakeAlice(uint256 amount) external {
        uint256 balance = token.balanceOf(ALICE);

        if (balance == 0) return;

        amount = bound(amount, 1, balance);

        vm.startPrank(ALICE);

        token.approve(address(staking), amount);
        staking.stake(amount);

        vm.stopPrank();
    }

    function stakeBob(uint256 amount) external {
        uint256 balance = token.balanceOf(BOB);

        if (balance == 0) return;

        amount = bound(amount, 1, balance);

        vm.startPrank(BOB);

        token.approve(address(staking), amount);
        staking.stake(amount);

        vm.stopPrank();
    }

    function unstakeAlice(uint256 amount) external {
        uint256 staked = staking.stakedBalance(ALICE);

        if (staked == 0) return;

        amount = bound(amount, 1, staked);

        vm.prank(ALICE);
        staking.unstake(amount);
    }

    function unstakeBob(uint256 amount) external {
        uint256 staked = staking.stakedBalance(BOB);

        if (staked == 0) return;

        amount = bound(amount, 1, staked);

        vm.prank(BOB);
        staking.unstake(amount);
    }

    function claimAlice() external {
        uint256 reward = staking.earned(ALICE);

        if (reward == 0) return;
        if (reward > staking.rewardPoolBalance()) return;

        vm.prank(ALICE);
        staking.claimRewards();
    }

    function claimBob() external {
        uint256 reward = staking.earned(BOB);

        if (reward == 0) return;
        if (reward > staking.rewardPoolBalance()) return;

        vm.prank(BOB);
        staking.claimRewards();
    }

    function advanceTime(uint256 secondsToAdvance) external {
        secondsToAdvance = bound(secondsToAdvance, 1, 30 days);

        vm.warp(block.timestamp + secondsToAdvance);
    }

    function alice() external pure returns (address) {
        return ALICE;
    }

    function bob() external pure returns (address) {
        return BOB;
    }
}

contract StakingInvariantTest is StdInvariant, Test {
    StakingToken token;
    StakingProtocol staking;
    StakingHandler handler;

    function setUp() public {
        token = new StakingToken();
        staking = new StakingProtocol(address(token));

        handler = new StakingHandler(token, staking);

        token.mint(handler.alice(), 10_000 ether);
        token.mint(handler.bob(), 10_000 ether);

        // Pool grande para permitir muchas secuencias de claims.
        token.mint(address(staking), 1_000_000 ether);

        targetContract(address(handler));
    }

    function invariant_TotalStakedEqualsUserStakes() public view {
        uint256 usersTotal = staking.stakedBalance(handler.alice()) + staking.stakedBalance(handler.bob());

        assertEq(staking.totalStaked(), usersTotal);
    }

    function invariant_PrincipalIsAlwaysBacked() public view {
        uint256 contractBalance = token.balanceOf(address(staking));

        assertGe(contractBalance, staking.totalStaked());
    }

    function invariant_GlobalLiabilityCoversUserRewards() public view {
        uint256 usersRewards = staking.earned(handler.alice()) + staking.earned(handler.bob());

        assertGe(staking.currentRewardLiability(), usersRewards);
    }
}
