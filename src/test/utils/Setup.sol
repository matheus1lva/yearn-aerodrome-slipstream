// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {TokenizedStrategy} from "@tokenized-strategy/TokenizedStrategy.sol";
import {MockFactory} from "@tokenized-strategy/test/mocks/MockFactory.sol";

import {AerodromeSlipstreamStrategy} from "../../AerodromeSlipstreamStrategy.sol";
import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {
    MockCLPool,
    MockNPM,
    MockCLGauge,
    MockSwapRouter
} from "../mocks/MockSlipstream.sol";

contract Setup is Test {
    // Matches BaseStrategy.tokenizedStrategyAddress for tokenized-strategy v3.1.0
    address public constant TS_ADDR = 0x310f5Db015E9d6E542fd41bd4542640790791e76;

    MockERC20 public weth;
    MockERC20 public usdc;
    MockERC20 public aero;

    MockCLPool public pool;
    MockNPM public npm;
    MockCLGauge public gauge;
    MockSwapRouter public router;

    IStrategyInterface public strategy;
    AerodromeSlipstreamStrategy public strat;

    address public user = address(10);
    address public keeper = address(4);
    address public management = address(1);
    address public performanceFeeRecipient = address(3);
    address public emergencyAdmin = address(5);

    uint256 public constant MAX_BPS = 10_000;
    int24 public constant TICK_SPACING = 100;
    int24 public tickLower = -1000;
    int24 public tickUpper = 1000;

    MockFactory public mockFactory;

    function setUp() public virtual {
        _etchTokenizedStrategy();

        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aero = new MockERC20("Aerodrome", "AERO", 18);

        // token0 < token1 by address for Uniswap-style ordering
        address t0 = address(weth) < address(usdc) ? address(weth) : address(usdc);
        address t1 = address(weth) < address(usdc) ? address(usdc) : address(weth);

        pool = new MockCLPool(t0, t1, TICK_SPACING);
        npm = new MockNPM();
        gauge = new MockCLGauge(address(npm), address(aero), address(pool), t0, t1);
        router = new MockSwapRouter();

        // Fund router so 1:1 swaps succeed both ways.
        weth.mint(address(router), 1_000_000 ether);
        usdc.mint(address(router), 1_000_000_000e6);
        aero.mint(address(router), 1_000_000 ether);

        strat = new AerodromeSlipstreamStrategy(
            address(weth),
            "Mock Aero Slipstream WETH-USDC",
            address(npm),
            address(gauge),
            address(pool),
            address(router),
            address(usdc),
            address(aero),
            TICK_SPACING,
            tickLower,
            tickUpper
        );
        strategy = IStrategyInterface(address(strat));

        strategy.setKeeper(keeper);
        strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        strategy.setPendingManagement(management);
        strategy.setEmergencyAdmin(emergencyAdmin);

        vm.prank(management);
        strategy.acceptManagement();

        vm.prank(management);
        strat.setOpen(true);

        // Disable health check limits for simple unit flows (re-enable in specific tests).
        vm.prank(management);
        strat.setDoHealthCheck(false);
        vm.prank(management);
        strat.setLossLimitRatio(5_000);
        vm.prank(management);
        strat.setProfitLimitRatio(10_000);

        vm.label(address(strategy), "strategy");
        vm.label(address(weth), "WETH");
        vm.label(address(usdc), "USDC");
        vm.label(address(aero), "AERO");
        vm.label(management, "management");
        vm.label(keeper, "keeper");
        vm.label(user, "user");
    }

    function _etchTokenizedStrategy() internal {
        mockFactory = new MockFactory(0, address(this));
        TokenizedStrategy impl = new TokenizedStrategy(address(mockFactory));
        vm.etch(TS_ADDR, address(impl).code);
    }

    function mintAndDeposit(address _user, uint256 _amount) public {
        weth.mint(_user, _amount);
        vm.startPrank(_user);
        weth.approve(address(strategy), _amount);
        strategy.deposit(_amount, _user);
        vm.stopPrank();
    }
}
