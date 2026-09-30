// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface IStrategyInterface is IStrategy {
    function positionTokenId() external view returns (uint256);
    function tickLower() external view returns (int24);
    function tickUpper() external view returns (int24);
    function tickSpacing() external view returns (int24);
    function npm() external view returns (address);
    function gauge() external view returns (address);
    function pool() external view returns (address);
    function otherToken() external view returns (address);
    function aero() external view returns (address);
    function isAssetToken0() external view returns (bool);
    function estimatedTotalAssets() external view returns (uint256);

    function setTickRange(int24 _tickLower, int24 _tickUpper) external;
    function setAuction(address _auction) external;
    function setMinAmountToSell(address _token, uint256 _min) external;
    function setMaxSlippageBps(uint256 _bps) external;
    function setTendThresholdBps(uint256 _bps) external;
}
