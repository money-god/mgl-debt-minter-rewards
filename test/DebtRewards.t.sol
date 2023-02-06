// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.6.7;

import "forge-std/Test.sol";
import "ds-token/token.sol";
import "../src/DebtRewards.sol";
import {AutoRewardDripper} from "../src/AutoRewardDripper.sol";

contract SAFEEngineMock {
    DebtRewards immutable rewards;

    constructor(address rewards_) public {
        rewards = DebtRewards(rewards_);
    }

    function setDebt(address who, uint256 wad) external {
        rewards.setDebt(who, wad);
    }
}

contract DebtRewardsTest is Test {
    DSToken rewardToken;
    DebtRewards debtRewards;
    SAFEEngineMock safeEngine;
    AutoRewardDripper rewardDripper;

    // for auto dripper
    uint256 rewardTimeline = 172800;
    uint256 rewardCalculationDelay = 7 days;

    function setUp() public {
        vm.roll(5000000);
        vm.warp(100000001);

        rewardToken = new DSToken("PROT", "PROT");
        rewardDripper = new AutoRewardDripper(
            address(this),        // requestor
            address(rewardToken),
            rewardTimeline,
            rewardCalculationDelay
        );

        debtRewards = new DebtRewards(address(rewardDripper));
        
        safeEngine = new SAFEEngineMock(address(debtRewards));
        debtRewards.addAuthorization(address(safeEngine));
        debtRewards.addAuthorization(address(this));

        rewardDripper.modifyParameters("requestor", address(debtRewards));
        rewardToken.mint(address(rewardDripper), 10000000 ether);
        rewardDripper.recomputePerBlockReward();
    }

    function test_setup() public {
        assertEq(address(debtRewards.rewardDripper()), address(rewardDripper));
        assertEq(address(debtRewards.rewardPool().token()), address(rewardToken));
        assertEq(debtRewards.authorizedAccounts(address(this)), 1);
        assertEq(debtRewards.totalDebt(), 0);
    }

    function test_setup_null_dripper() public {
        vm.expectRevert(bytes("DebtRewards/null-reward-dripper"));
        debtRewards = new DebtRewards(address(0));        
    }

    function test_set_debt(address who, uint wad, uint wad2) public {
        safeEngine.setDebt(who, wad);
        assertEq(debtRewards.debtBalanceOf(who), wad);
        assertEq(debtRewards.totalDebt(), wad);

        safeEngine.setDebt(who, wad2);
        assertEq(debtRewards.debtBalanceOf(who), wad2);
        assertEq(debtRewards.totalDebt(), wad2);        
    }

    function test_debt_rewards_1(address who, uint amount, uint blockDelay) public {
        amount = amount % 10**24 + 1; // up to 1mm staked
        blockDelay = (blockDelay % 100) + 1; // up to 1000 blocks
        uint rewardPerBlock = rewardDripper.rewardPerBlock();
        // join
        safeEngine.setDebt(who, amount);

        vm.roll(block.number + blockDelay);
        uint previousBalance = rewardToken.balanceOf(address(who));

        // exit
        safeEngine.setDebt(who, 0);

        assertTrue(rewardToken.balanceOf(address(who)) >= previousBalance + (blockDelay * rewardPerBlock) - 1);
        assertEq(debtRewards.debtBalanceOf(who), 0);
    }

    function test_debt_rewards_2_users(uint amount) public {
        amount = amount % 10**24 + 1; // non null up to 1mm
        address user1 = address(1);
        address user2 = address(2);

        uint rewardPerBlock = rewardDripper.rewardPerBlock();

        // join
        safeEngine.setDebt(user1, amount);
        assertEq(debtRewards.debtBalanceOf(user1), amount);
        safeEngine.setDebt(user2, amount);
        assertEq(debtRewards.debtBalanceOf(user2), amount);

        // exit
        vm.roll(block.number + 32); // 32 blocks
        uint previousBalance1 = rewardToken.balanceOf(address(user1));
        uint previousBalance2 = rewardToken.balanceOf(address(user2));

        safeEngine.setDebt(user1, 0);
        assertEq(debtRewards.debtBalanceOf(user1), 0);
        safeEngine.setDebt(user2, 0);
        assertEq(debtRewards.debtBalanceOf(user2), 0);
        
        assertTrue(rewardToken.balanceOf(address(user1)) >= previousBalance1 + 16 * rewardPerBlock -1);
        assertTrue(rewardToken.balanceOf(address(user1)) <= previousBalance1 + 16 * rewardPerBlock +1);
        assertTrue(rewardToken.balanceOf(address(user2)) >= previousBalance2 + 16 * rewardPerBlock -1);
        assertTrue(rewardToken.balanceOf(address(user2)) <= previousBalance2 + 16 * rewardPerBlock +1);
    }

    function test_get_rewards() public {
        uint amount = 10 ether;
        address user1 = address(1);

        uint rewardPerBlock = rewardDripper.rewardPerBlock();

        vm.roll(block.number + 10);

        debtRewards.updatePool(); // no effect

        // join
        rewardToken.approve(address(debtRewards), uint(-1));
        safeEngine.setDebt(user1, amount);

        uint previousBalance = rewardToken.balanceOf(address(user1));

        vm.roll(block.number + 10); // 10 blocks

        vm.prank(user1);
        debtRewards.getRewards();
        assertEq(rewardToken.balanceOf(address(user1)), previousBalance + 20 * rewardPerBlock); // 1 eth per block

        vm.roll(block.number + 8); // 8 blocks

        vm.prank(user1);
        debtRewards.getRewards();
        assertTrue(rewardToken.balanceOf(address(user1)) >= previousBalance + 28 * rewardPerBlock - 1); // 1 eth per block, division rounding causes a slight loss of precision
    }

    function test_rewards_dripper_depleated2() public {
        address user1 = address(1);
        uint amount = 7 ether;
        uint rewardPerBlock = rewardDripper.rewardPerBlock();
        // leave rewards only for 20 blocks
        rewardDripper.transferTokenOut(address(0x0ddaf), rewardToken.balanceOf(address(rewardDripper)) - 20 * rewardPerBlock);

        safeEngine.setDebt(user1, amount);

        vm.roll(block.number + 32); // 32 blocks
        uint previousBalance = rewardToken.balanceOf(address(user1));
        safeEngine.setDebt(user1, 0);           
        
        assertEq(debtRewards.debtBalanceOf(address(user1)), 0);
        assertTrue(rewardToken.balanceOf(address(user1)) >= previousBalance + 20 * rewardPerBlock - 1); // full amount
    }

    function test_rewards_dripper_depleated_recharged() public {
        address user1 = address(1);
        uint amount = 7 ether;
        uint rewardPerBlock = rewardDripper.rewardPerBlock();
        // leave rewards only for 20 blocks
        rewardDripper.transferTokenOut(address(0x0ddaf), rewardToken.balanceOf(address(rewardDripper)) - 20 * rewardPerBlock);

        safeEngine.setDebt(user1, amount);

        vm.roll(block.number + 32); // 32 blocks
        uint previousBalance = rewardToken.balanceOf(address(this));
        vm.prank(user1);
        debtRewards.getRewards();
        assertTrue(rewardToken.balanceOf(address(user1)) >= previousBalance + 20 * rewardPerBlock - 1); // full amount

        vm.roll(block.number + 32); // 32 blocks

        rewardToken.mint(address(rewardDripper), 5 * rewardPerBlock);
        vm.prank(user1);
        debtRewards.getRewards();
        assertTrue(rewardToken.balanceOf(address(user1)) >= previousBalance + 25 * rewardPerBlock - 1);
    }

    function test_get_rewards_externally_funded() public {
        uint amount = 10 ether;

        rewardDripper.transferTokenOut(address(0xfab), rewardToken.balanceOf(address(rewardDripper)));

        vm.roll(block.number + 10);

        debtRewards.updatePool(); // no effect

        // join
        safeEngine.setDebt(address(this), amount);

        vm.roll(block.number + 10); // 10 blocks

        rewardToken.mint(address(debtRewards.rewardPool()), 10 ether); // manually filling up contract

        uint previousBalance = rewardToken.balanceOf(address(this));
        debtRewards.getRewards();
        assertEq(rewardToken.balanceOf(address(this)), previousBalance + 10 ether); // 1 eth per block + externally funded

        vm.roll(block.number + 4);
        debtRewards.pullFunds(); // pulling rewards to contract without updating

        vm.roll(block.number + 4);
        rewardToken.mint(address(debtRewards.rewardPool()), 2 ether); // manually filling up contract

        debtRewards.getRewards();
        assertEq(rewardToken.balanceOf(address(this)), previousBalance + 12 ether); // 1 eth per block, division rounding causes a slight loss of precision
    }
}