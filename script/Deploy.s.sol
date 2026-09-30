// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Script, console2} from "forge-std/Script.sol";
import {AerodromeSlipstreamStrategy} from "../src/AerodromeSlipstreamStrategy.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {BaseAddresses} from "../src/libraries/BaseAddresses.sol";

/**
 * @title Deploy
 * @notice Prepares deployment of Aerodrome Slipstream WETH/USDC strategy on Base.
 * @dev Does NOT broadcast by default. Example:
 *
 *   forge script script/Deploy.s.sol:Deploy --rpc-url $BASE_RPC_URL -vvvv
 *   forge script script/Deploy.s.sol:Deploy --rpc-url $BASE_RPC_URL --broadcast --verify
 *
 * Before mainnet:
 * 1. Confirm TokenizedStrategy @ 0x310f5Db015E9d6E542fd41bd4542640790791e76 on Base
 *    (tokenized-strategy v3.1.0 CREATE2).
 * 2. Confirm CL100 pool + gauge addresses in BaseAddresses.
 * 3. Choose tickLower/tickUpper around current tick (multiples of 100).
 * 4. Set roles (management, keeper, emergencyAdmin, perfFeeRecipient).
 */
contract Deploy is Script {
    // ---- Customize roles before broadcast ----
    address public management = vm.envOr("MANAGEMENT", address(0));
    address public keeper = vm.envOr("KEEPER", address(0));
    address public emergencyAdmin = vm.envOr("EMERGENCY_ADMIN", address(0));
    address public perfFeeRecipient = vm.envOr("PERF_FEE_RECIPIENT", address(0));

    // Wide-ish initial range placeholders (±2000 ticks @ spacing 100 = ±20 tick steps).
    // TODO: set from live pool.slot0().tick before production deploy.
    int24 public tickLower = -200_000;
    int24 public tickUpper = 200_000;

    function run() external {
        address deployer = msg.sender;
        if (management == address(0)) management = deployer;
        if (keeper == address(0)) keeper = deployer;
        if (emergencyAdmin == address(0)) emergencyAdmin = deployer;
        if (perfFeeRecipient == address(0)) perfFeeRecipient = deployer;

        console2.log("Deployer", deployer);
        console2.log("Management", management);
        console2.log("Chain id", block.chainid);

        vm.startBroadcast();

        StrategyFactory factory = new StrategyFactory(
            management,
            perfFeeRecipient,
            keeper,
            emergencyAdmin
        );

        StrategyFactory.SlipstreamConfig memory cfg = StrategyFactory.SlipstreamConfig({
            npm: BaseAddresses.NPM,
            gauge: BaseAddresses.CL100_WETH_USDC_GAUGE,
            pool: BaseAddresses.CL100_WETH_USDC_POOL,
            swapRouter: BaseAddresses.SLIPSTREAM_SWAP_ROUTER,
            otherToken: BaseAddresses.USDC,
            aero: BaseAddresses.AERO,
            tickSpacing: BaseAddresses.DEFAULT_TICK_SPACING,
            tickLower: tickLower,
            tickUpper: tickUpper
        });

        address strat = factory.newStrategy(
            BaseAddresses.WETH,
            "Aerodrome Slipstream WETH/USDC CL100",
            cfg
        );

        vm.stopBroadcast();

        console2.log("Factory", address(factory));
        console2.log("Strategy", strat);
        console2.log("Asset (WETH)", BaseAddresses.WETH);
        console2.log("NPM", BaseAddresses.NPM);
        console2.log("Gauge", BaseAddresses.CL100_WETH_USDC_GAUGE);
        console2.log("Pool", BaseAddresses.CL100_WETH_USDC_POOL);
    }
}
