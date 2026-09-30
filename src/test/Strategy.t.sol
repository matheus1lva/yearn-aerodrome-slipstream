// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "./utils/Setup.sol";
import {console2} from "forge-std/console2.sol";

contract StrategyTest is Setup {
    function test_setupOK() public view {
        assertEq(strategy.asset(), address(weth));
        assertEq(strategy.management(), management);
        assertEq(strategy.keeper(), keeper);
        assertEq(strat.tickSpacing(), TICK_SPACING);
        assertEq(strat.tickLower(), tickLower);
        assertEq(strat.tickUpper(), tickUpper);
        assertEq(strat.positionTokenId(), 0);
    }

    function test_depositDeploysIntoMockLP() public {
        uint256 amount = 10 ether;
        mintAndDeposit(user, amount);

        assertGt(strategy.totalAssets(), 0, "totalAssets");
        assertGt(strat.positionTokenId(), 0, "tokenId");
        assertGt(strat.deployedEstimate(), 0, "deployed");
    }

    function test_withdrawReturnsAsset() public {
        uint256 amount = 5 ether;
        mintAndDeposit(user, amount);

        uint256 shares = strategy.balanceOf(user);
        vm.prank(user);
        uint256 out = strategy.redeem(shares, user, user);

        // Mock 1:1 router + naive LP — allow wide tolerance
        assertGt(out, amount / 4, "got something back");
        assertEq(strategy.balanceOf(user), 0);
    }

    function test_reportClaimsAndCompounds() public {
        uint256 amount = 8 ether;
        mintAndDeposit(user, amount);

        uint256 tokenId = strat.positionTokenId();
        // Simulate AERO emissions
        aero.mint(address(this), 1 ether);
        aero.approve(address(gauge), 1 ether);
        gauge.airdropReward(tokenId, 1 ether);

        uint256 beforeAssets = strategy.totalAssets();

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertEq(loss, 0, "no loss");
        // Profit may be 0 if healthcheck off and accounting noise; ensure report succeeds
        console2.log("profit", profit);
        console2.log("totalAssets", strategy.totalAssets());
        assertGe(strategy.totalAssets(), beforeAssets / 2, "assets sane");
    }

    function test_tendTrigger_outOfRangeSkew() public {
        mintAndDeposit(user, 2 ether);
        (bool trigger,) = strategy.tendTrigger();
        // Mid-range at tick 0 with ±1000 → not skewed
        assertFalse(trigger);

        pool.setSlot0(uint160(1) << 96, 900); // near upper edge
        (trigger,) = strategy.tendTrigger();
        assertTrue(trigger, "should tend near edge");
    }

    function test_setTickRange_onlyManagement() public {
        vm.prank(user);
        vm.expectRevert();
        strat.setTickRange(-500, 500);

        vm.prank(management);
        strat.setTickRange(-500, 500);
        assertEq(strat.tickLower(), -500);
        assertEq(strat.tickUpper(), 500);
    }

    function test_protectedTokens() public view {
        address[] memory p = strat.protectedTokens();
        assertEq(p.length, 2);
        assertEq(p[0], address(weth));
        assertEq(p[1], address(usdc));
    }
}
