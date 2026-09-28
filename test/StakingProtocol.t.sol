// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {StakingToken} from "../src/StakingToken.sol";
import {StakingProtocol} from "../src/StakingProtocol.sol";

contract StakingProtocolTest is Test {
    StakingToken token;
    StakingProtocol staking;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        token = new StakingToken();
        staking = new StakingProtocol(address(token));

        token.mint(alice, 1_000 ether);
        token.mint(bob, 1_000 ether);
        token.mint(address(staking), 10_000 ether);
    }

    function testStake() public {
        vm.startPrank(alice);

        token.approve(address(staking), 100 ether);
        staking.stake(100 ether);

        vm.stopPrank();

        assertEq(staking.stakedBalance(alice), 100 ether);
        assertEq(token.balanceOf(alice), 900 ether);
        assertEq(token.balanceOf(address(staking)), 10100 ether);
    }

    function testCannotStakeZero() public {
        vm.prank(alice);

        vm.expectRevert("Amount must be greater than 0");
        staking.stake(0);
    }

    function testRewardAfterOneDay() public {
        vm.startPrank(alice);

        token.approve(address(staking), 100 ether);
        staking.stake(100 ether);

        vm.warp(block.timestamp + 1 days);

        staking.claimRewards();

        vm.stopPrank();

        assertEq(token.balanceOf(alice), 901 ether);
    }

    function testPartialUnstakeKeepsRewards() public {
        vm.startPrank(alice);

        token.approve(address(staking), 100 ether);
        staking.stake(100 ether);

        vm.warp(block.timestamp + 1 days);

        staking.unstake(40 ether);

        vm.stopPrank();

        assertEq(staking.stakedBalance(alice), 60 ether);
        assertEq(staking.rewards(alice), 1 ether);

        // 900 después del stake + 40 retirados
        assertEq(token.balanceOf(alice), 940 ether);
    }

    function testMultipleUsersEarnRewardsIndependently() public {
        vm.startPrank(alice);
        token.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(staking), 200 ether);
        staking.stake(200 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        staking.claimRewards();

        vm.prank(bob);
        staking.claimRewards();

        assertEq(token.balanceOf(alice), 901 ether);
        assertEq(token.balanceOf(bob), 802 ether);

        assertEq(staking.stakedBalance(alice), 100 ether);
        assertEq(staking.stakedBalance(bob), 200 ether);
    }

    function testAdditionalStakeCalculatesRewardsCorrectly() public {
        vm.startPrank(alice);

        token.approve(address(staking), 100 ether);

        // Alice stakea 60 STK
        staking.stake(60 ether);

        // Pasan 12 horas
        vm.warp(block.timestamp + 12 hours);

        // Alice añade otros 40 STK
        staking.stake(40 ether);

        // Por las primeras 12 horas:
        // 60 * 0.5 días / 100 = 0.3 STK
        assertEq(staking.rewards(alice), 3 ether / 10);

        // Ahora tiene 100 STK staked
        assertEq(staking.stakedBalance(alice), 100 ether);

        // Pasan otras 12 horas
        vm.warp(block.timestamp + 12 hours);

        staking.claimRewards();

        vm.stopPrank();

        // Primeras 12h con 60 STK = 0.3
        // Segundas 12h con 100 STK = 0.5
        // Total = 0.8 STK
        assertEq(token.balanceOf(alice), 900 ether + (8 ether / 10));

        assertEq(staking.rewards(alice), 0);
    }

    function testStakePartialUnstakeAndClaim() public {
        vm.startPrank(alice);

        token.approve(address(staking), 100 ether);

        // Empieza con 100 STK
        staking.stake(100 ether);

        // 1 día con 100 STK
        vm.warp(block.timestamp + 1 days);

        // Retira 40 → quedan 60
        staking.unstake(40 ether);

        // Otro día con 60 STK
        vm.warp(block.timestamp + 1 days);

        staking.claimRewards();

        vm.stopPrank();

        // Día 1: 100 STK → 1 STK reward
        // Día 2: 60 STK → 0.6 STK reward
        // Total reward = 1.6 STK

        assertEq(staking.stakedBalance(alice), 60 ether);

        assertEq(token.balanceOf(alice), 940 ether + (16 ether / 10));

        assertEq(staking.rewards(alice), 0);
    }

    function testEarnedShowsPendingRewards() public {
        vm.startPrank(alice);

        token.approve(address(staking), 100 ether);
        staking.stake(100 ether);

        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        assertEq(staking.rewards(alice), 0);
        assertEq(staking.earned(alice), 1 ether);
    }

    function testClaimRevertsIfRewardPoolIsInsufficient() public {
        StakingToken smallToken = new StakingToken();
        StakingProtocol smallStaking = new StakingProtocol(address(smallToken));

        smallToken.mint(alice, 100 ether);

        vm.startPrank(alice);

        smallToken.approve(address(smallStaking), 100 ether);
        smallStaking.stake(100 ether);

        vm.warp(block.timestamp + 200 days);

        vm.expectRevert();
        smallStaking.claimRewards();

        vm.stopPrank();

        // La transacción revirtió entera.
        // Alice sigue teniendo derecho a sus recompensas.
        assertEq(smallStaking.earned(alice), 200 ether);
        assertEq(smallStaking.stakedBalance(alice), 100 ether);
    }

    function testRewardPoolDoesNotIncludeStakedTokens() public {
        vm.startPrank(alice);

        token.approve(address(staking), 100 ether);
        staking.stake(100 ether);

        vm.stopPrank();

        assertEq(staking.totalStaked(), 100 ether);

        assertEq(token.balanceOf(address(staking)), 10_100 ether);

        assertEq(staking.rewardPoolBalance(), 10_000 ether);
    }

    function testRewardsCannotUseStakedTokens() public {
        StakingToken smallToken = new StakingToken();
        StakingProtocol smallStaking = new StakingProtocol(address(smallToken));

        smallToken.mint(alice, 100 ether);

        vm.startPrank(alice);

        smallToken.approve(address(smallStaking), 100 ether);
        smallStaking.stake(100 ether);

        vm.warp(block.timestamp + 1 days);

        // El contrato tiene 100 STK físicamente,
        // pero los 100 pertenecen al stake de Alice.
        assertEq(smallToken.balanceOf(address(smallStaking)), 100 ether);

        assertEq(smallStaking.totalStaked(), 100 ether);
        assertEq(smallStaking.rewardPoolBalance(), 0);

        vm.expectRevert("Insufficient reward pool");
        smallStaking.claimRewards();

        // Aunque no pueda cobrar reward,
        // Alice sí puede recuperar su principal.
        smallStaking.unstake(100 ether);

        vm.stopPrank();

        assertEq(smallToken.balanceOf(alice), 100 ether);
        assertEq(smallStaking.totalStaked(), 0);
    }
}
