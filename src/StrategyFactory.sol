// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {AerodromeSlipstreamStrategy} from "./AerodromeSlipstreamStrategy.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";
import {BaseAddresses} from "./libraries/BaseAddresses.sol";

/// @notice Deploys Aerodrome Slipstream strategies and wires Yearn roles.
contract StrategyFactory {
    event NewStrategy(address indexed strategy, address indexed asset);

    address public immutable emergencyAdmin;
    address public management;
    address public performanceFeeRecipient;
    address public keeper;

    /// @dev asset => strategy
    mapping(address => address) public deployments;

    constructor(
        address _management,
        address _performanceFeeRecipient,
        address _keeper,
        address _emergencyAdmin
    ) {
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
        emergencyAdmin = _emergencyAdmin;
    }

    struct SlipstreamConfig {
        address npm;
        address gauge;
        address pool;
        address swapRouter;
        address otherToken;
        address aero;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
    }

    function newStrategy(
        address _asset,
        string calldata _name,
        SlipstreamConfig calldata cfg
    ) external returns (address) {
        IStrategyInterface strat = IStrategyInterface(
            address(
                new AerodromeSlipstreamStrategy(
                    _asset,
                    _name,
                    cfg.npm,
                    cfg.gauge,
                    cfg.pool,
                    cfg.swapRouter,
                    cfg.otherToken,
                    cfg.aero,
                    cfg.tickSpacing,
                    cfg.tickLower,
                    cfg.tickUpper
                )
            )
        );

        strat.setPerformanceFeeRecipient(performanceFeeRecipient);
        strat.setKeeper(keeper);
        strat.setPendingManagement(management);
        strat.setEmergencyAdmin(emergencyAdmin);

        // Open deposits by default for permissionless ERC-4626 (HealthCheck whitelist).
        // Management can close + whitelist later.
        AerodromeSlipstreamStrategy(address(strat)).setOpen(true);

        emit NewStrategy(address(strat), _asset);
        deployments[_asset] = address(strat);
        return address(strat);
    }

    /// @notice Convenience deploy for Base WETH/USDC CL100 with caller-supplied ticks.
    function newWethUsdcStrategy(
        string calldata _name,
        int24 _tickLower,
        int24 _tickUpper
    ) external returns (address) {
        SlipstreamConfig memory cfg = SlipstreamConfig({
            npm: BaseAddresses.NPM,
            gauge: BaseAddresses.CL100_WETH_USDC_GAUGE,
            pool: BaseAddresses.CL100_WETH_USDC_POOL,
            swapRouter: BaseAddresses.SLIPSTREAM_SWAP_ROUTER,
            otherToken: BaseAddresses.USDC,
            aero: BaseAddresses.AERO,
            tickSpacing: BaseAddresses.DEFAULT_TICK_SPACING,
            tickLower: _tickLower,
            tickUpper: _tickUpper
        });
        return this.newStrategy(BaseAddresses.WETH, _name, cfg);
    }

    function setAddresses(
        address _management,
        address _performanceFeeRecipient,
        address _keeper
    ) external {
        require(msg.sender == management, "!management");
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
    }

    function isDeployedStrategy(address _strategy) external view returns (bool) {
        address _asset = IStrategyInterface(_strategy).asset();
        return deployments[_asset] == _strategy;
    }
}
