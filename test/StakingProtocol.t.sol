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

    function testMultipleStakesAccumulateRewardsCorrectly() public {
        vm.startPrank(alice);

        token.approve(address(staking), 200 ether);

        // Día 1: 100 STK
        staking.stake(100 ether);

        vm.warp(block.timestamp + 1 days);

        // Al hacer otro stake, primero se consolidan
        // las rewards del primer día: 1 STK
        staking.stake(100 ether);

        assertEq(staking.rewards(alice), 1 ether);
        assertEq(staking.stakedBalance(alice), 200 ether);

        // Día 2: 200 STK
        vm.warp(block.timestamp + 1 days);

        staking.claimRewards();

        vm.stopPrank();

        // 1 STK del primer día
        // + 2 STK del segundo día
        // = 3 STK
        assertEq(staking.rewards(alice), 0);

        assertEq(token.balanceOf(alice), 803 ether);

        assertEq(staking.stakedBalance(alice), 200 ether);
    }

    function testManualCompoundingIncreasesFutureRewards() public {
        vm.startPrank(alice);

        // Alice va a stakear en total:
        // 100 + 1 reward + 100 = 201 STK
        token.approve(address(staking), 201 ether);

        // Día 1: stake inicial de 100
        staking.stake(100 ether);

        vm.warp(block.timestamp + 1 days);

        // Ha generado 1 STK
        staking.claimRewards();

        assertEq(token.balanceOf(alice), 901 ether);
        assertEq(staking.stakedBalance(alice), 100 ether);

        // Compound manual:
        // vuelve a stakear el 1 STK que acaba de cobrar
        staking.stake(1 ether);

        assertEq(staking.stakedBalance(alice), 101 ether);

        // Además añade otros 100 STK
        staking.stake(100 ether);

        assertEq(staking.stakedBalance(alice), 201 ether);

        // Segundo día con 201 STK
        vm.warp(block.timestamp + 1 days);

        staking.claimRewards();

        vm.stopPrank();

        // 201 STK durante 1 día:
        // 201 / 100 = 2.01 STK
        assertEq(token.balanceOf(alice), 802 ether + (1 ether / 100));

        assertEq(staking.stakedBalance(alice), 201 ether);
    }

    function testMultiplePartialUnstakesKeepRewardAccountingCorrect() public {
        vm.startPrank(alice);

        token.approve(address(staking), 100 ether);
        staking.stake(100 ether);

        // Día 1 con 100 STK
        vm.warp(block.timestamp + 1 days);

        // Retira 40
        // Antes de bajar el stake se consolidan 1 STK de reward
        staking.unstake(40 ether);

        assertEq(staking.stakedBalance(alice), 60 ether);
        assertEq(staking.rewards(alice), 1 ether);

        // Día 2 con 60 STK
        vm.warp(block.timestamp + 1 days);

        // Retira otros 20
        // Se consolidan 0.6 STK más
        staking.unstake(20 ether);

        assertEq(staking.stakedBalance(alice), 40 ether);
        assertEq(staking.rewards(alice), 1 ether + (6 ether / 10));

        // Día 3 con 40 STK
        vm.warp(block.timestamp + 1 days);

        staking.claimRewards();

        vm.stopPrank();

        // Rewards:
        // día 1: 100 STK -> 1
        // día 2:  60 STK -> 0.6
        // día 3:  40 STK -> 0.4
        // total = 2 STK

        assertEq(staking.rewards(alice), 0);
        assertEq(staking.stakedBalance(alice), 40 ether);

        // Wallet:
        // 1000
        // -100 stake
        // +40 unstake
        // +20 unstake
        // +2 rewards
        // = 962
        assertEq(token.balanceOf(alice), 962 ether);
    }

    function testOwnerCanChangeRewardRate() public {
        staking.setRewardRate(200);

        vm.startPrank(alice);

        token.approve(address(staking), 100 ether);
        staking.stake(100 ether);

        vm.warp(block.timestamp + 1 days);

        staking.claimRewards();

        vm.stopPrank();

        // 2% de 100 STK = 2 STK
        assertEq(token.balanceOf(alice), 902 ether);
    }

    function testNonOwnerCannotChangeRewardRate() public {
        vm.prank(alice);

        vm.expectRevert();
        staking.setRewardRate(200);
    }

    function testRewardRateChangeDoesNotApplyRetroactively() public {
        vm.startPrank(alice);

        token.approve(address(staking), 100 ether);
        staking.stake(100 ether);

        vm.stopPrank();

        // 12 horas al 1%
        vm.warp(block.timestamp + 12 hours);

        // El owner cambia la tasa al 2%
        staking.setRewardRate(200);

        // Otras 12 horas al 2%
        vm.warp(block.timestamp + 12 hours);

        vm.prank(alice);
        staking.claimRewards();

        // Primeras 12h:
        // 100 * 1% * 0.5 días = 0.5 STK

        // Segundas 12h:
        // 100 * 2% * 0.5 días = 1 STK

        // Total reward = 1.5 STK

        assertEq(token.balanceOf(alice), 900 ether + (15 ether / 10));

        assertEq(staking.rewards(alice), 0);
    }

    function testAddingStakeUpdatesUserRewardCheckpoint() public {
        vm.startPrank(alice);

        token.approve(address(staking), 200 ether);

        // Alice entra con 100 STK
        staking.stake(100 ether);

        // 1 día al 1%
        vm.warp(block.timestamp + 1 days);

        // Añade otros 100.
        // Antes de añadirlos, se contabiliza lo generado
        // por los 100 antiguos.
        staking.stake(100 ether);

        vm.stopPrank();

        // Los primeros 100 han generado 1 STK
        assertEq(staking.rewards(alice), 1 ether);

        // Ahora Alice tiene 200 STK
        assertEq(staking.stakedBalance(alice), 200 ether);

        // Tras 1 día al 1%, el índice global ha avanzado 0.01
        assertEq(staking.userRewardPerTokenPaid(alice), 1 ether / 100);

        // Otro día con los 200 STK
        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        staking.claimRewards();

        // Primer día: 100 STK -> 1
        // Segundo día: 200 STK -> 2
        // Total: 3 STK
        assertEq(token.balanceOf(alice), 803 ether);

        // El marcador personal ahora queda actualizado
        // al índice global de 0.02
        assertEq(staking.userRewardPerTokenPaid(alice), 2 ether / 100);
    }

    function testRemovingStakeUpdatesUserRewardCheckpoint() public {
        vm.startPrank(alice);

        token.approve(address(staking), 200 ether);
        staking.stake(200 ether);

        // Día 1 con 200 STK
        vm.warp(block.timestamp + 1 days);

        // Antes de retirar, se contabiliza todo el tramo
        // en el que Alice tuvo 200 STK.
        staking.unstake(100 ether);

        vm.stopPrank();

        assertEq(staking.rewards(alice), 2 ether);
        assertEq(staking.stakedBalance(alice), 100 ether);

        // El índice global está en 0.01
        // y Alice ya tiene contabilizado hasta ahí.
        assertEq(staking.userRewardPerTokenPaid(alice), 1 ether / 100);

        // Otro día, ahora solo con 100 STK
        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        staking.claimRewards();

        // Día 1: 200 STK -> 2 STK
        // Día 2: 100 STK -> 1 STK
        // Total rewards = 3 STK

        // Wallet:
        // 1000 - 200 stake + 100 unstake + 3 rewards
        // = 903
        assertEq(token.balanceOf(alice), 903 ether);

        assertEq(staking.stakedBalance(alice), 100 ether);

        // Índice global tras 2 días = 0.02
        assertEq(staking.userRewardPerTokenPaid(alice), 2 ether / 100);
    }

    function testFundRewardPool() public {
        uint256 initialPool = staking.rewardPoolBalance();

        vm.startPrank(alice);

        token.approve(address(staking), 500 ether);
        staking.fundRewardPool(500 ether);

        vm.stopPrank();

        assertEq(staking.rewardPoolBalance(), initialPool + 500 ether);
    }

    function testOwnerCanWithdrawUnusedRewardsWithoutTouchingStake() public {
        vm.startPrank(alice);

        token.approve(address(staking), 100 ether);
        staking.stake(100 ether);

        vm.stopPrank();

        uint256 ownerBalanceBefore = token.balanceOf(address(this));

        staking.withdrawUnusedRewards(1_000 ether);

        assertEq(token.balanceOf(address(this)), ownerBalanceBefore + 1_000 ether);

        assertEq(staking.totalStaked(), 100 ether);

        assertEq(token.balanceOf(address(staking)), 9_100 ether);
    }
}
