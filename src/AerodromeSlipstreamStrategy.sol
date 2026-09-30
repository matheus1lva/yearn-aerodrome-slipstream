// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseHealthCheck, ERC20} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {TokenizedStrategyLib as TokenizedStrategy} from "@tokenized-strategy/libraries/TokenizedStrategyLib.sol";
import {AuctionSwapper} from "@periphery/swappers/AuctionSwapper.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {
    INonfungiblePositionManager,
    ICLGauge,
    ICLPool,
    ISlipstreamSwapRouter
} from "./interfaces/IAerodromeSlipstream.sol";

/**
 * @title AerodromeSlipstreamStrategy
 * @notice Yearn V3 Tokenized Strategy — Aerodrome Slipstream (CL) WETH/USDC LP compounder on Base.
 *
 * ## Architecture (v0)
 * - Single-asset ERC-4626 Tokenized Strategy (asset = WETH by default).
 * - Deploys into an Aerodrome Slipstream concentrated-liquidity NFT via NPM.
 * - Stakes the NFT in the pool CL gauge to earn AERO emissions.
 * - On harvest: claim AERO → sell (AuctionSwapper and/or Slipstream router) → compound.
 *
 * ## v0 pragmatism / upgrade path
 * Full autonomous CLM (dynamic range, inventory skew) is stubbed. Management sets ticks.
 * `_tend` / `_tendTrigger` are hooks for keepers; rebalance body is TODO.
 *
 * Production TODOs (search `TODO(prod-`):
 * - `TODO(prod-range)`: out-of-range detection + burn/re-mint around current tick
 * - `TODO(prod-oracle)`: TWAP/Chainlink for accounting + swap mins (not spot-only)
 * - `TODO(prod-slippage)`: sandwich-resistant deploy (private relay / tend-only deploy)
 * - `TODO(prod-amounts)`: wire Uniswap V3 LiquidityAmounts for exact principal valuation
 *
 * ## Periphery
 * - `BaseHealthCheck`: bounds reported profit/loss on `report()`.
 * - `AuctionSwapper`: optional Dutch auction for AERO → asset (`setAuction`).
 */
contract AerodromeSlipstreamStrategy is BaseHealthCheck, AuctionSwapper, IERC721Receiver {
    using SafeERC20 for ERC20;
    using Math for uint256;

    uint256 internal constant MAX_BPS_LOCAL = 10_000;
    uint128 internal constant MAX_UINT128 = type(uint128).max;

    INonfungiblePositionManager public immutable npm;
    ICLGauge public immutable gauge;
    ICLPool public immutable pool;
    ISlipstreamSwapRouter public immutable swapRouter;
    ERC20 public immutable otherToken;
    ERC20 public immutable aero;
    bool public immutable isAssetToken0;
    int24 public immutable tickSpacing;

    /// @notice Slipstream NPM tokenId (0 = none).
    uint256 public positionTokenId;
    int24 public tickLower;
    int24 public tickUpper;

    /// @notice v0 bookkeeping: asset-equivalent still deployed in LP (updated on deploy/free).
    /// @dev Replaced by exact LiquidityAmounts valuation in production (`TODO(prod-amounts)`).
    uint256 public deployedEstimate;

    uint256 public maxSlippageBps = 50;
    uint256 public tendThresholdBps = 2_500;

    event TickRangeUpdated(int24 tickLower, int24 tickUpper);
    event PositionOpened(uint256 indexed tokenId, int24 tickLower, int24 tickUpper);
    event PositionIncreased(uint256 indexed tokenId, uint128 liquidity);
    event RewardsClaimed(uint256 aeroAmount);
    event MaxSlippageUpdated(uint256 bps);
    event TendThresholdUpdated(uint256 bps);

    constructor(
        address _asset,
        string memory _name,
        address _npm,
        address _gauge,
        address _pool,
        address _swapRouter,
        address _otherToken,
        address _aero,
        int24 _tickSpacing,
        int24 _tickLower,
        int24 _tickUpper
    ) BaseHealthCheck(_asset, _name) {
        require(_npm != address(0) && _gauge != address(0) && _pool != address(0), "zero");
        require(_otherToken != address(0) && _aero != address(0) && _swapRouter != address(0), "zero");
        require(_tickLower < _tickUpper, "ticks");
        require(_tickLower % _tickSpacing == 0 && _tickUpper % _tickSpacing == 0, "!spacing");

        npm = INonfungiblePositionManager(_npm);
        gauge = ICLGauge(_gauge);
        pool = ICLPool(_pool);
        swapRouter = ISlipstreamSwapRouter(_swapRouter);
        otherToken = ERC20(_otherToken);
        aero = ERC20(_aero);
        tickSpacing = _tickSpacing;
        tickLower = _tickLower;
        tickUpper = _tickUpper;

        address t0 = ICLPool(_pool).token0();
        address t1 = ICLPool(_pool).token1();
        require(
            (_asset == t0 && _otherToken == t1) || (_asset == t1 && _otherToken == t0),
            "!pair"
        );
        isAssetToken0 = _asset == t0;

        ERC20(_asset).forceApprove(_npm, type(uint256).max);
        ERC20(_otherToken).forceApprove(_npm, type(uint256).max);
        ERC20(_asset).forceApprove(_swapRouter, type(uint256).max);
        ERC20(_otherToken).forceApprove(_swapRouter, type(uint256).max);
        ERC20(_aero).forceApprove(_swapRouter, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        REQUIRED OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function _deployFunds(uint256 _amount) internal override {
        if (_amount == 0) return;

        uint256 beforeAsset = asset.balanceOf(address(this));

        // 50/50 split for v0 inventory. TODO(prod-range): use tick geometry.
        uint256 toSwap = _amount / 2;
        if (toSwap > 0) {
            _swapExact(address(asset), address(otherToken), toSwap);
        }

        uint256 amountAsset = asset.balanceOf(address(this));
        uint256 amountOther = otherToken.balanceOf(address(this));
        (uint256 amount0, uint256 amount1) =
            isAssetToken0 ? (amountAsset, amountOther) : (amountOther, amountAsset);

        if (positionTokenId == 0) {
            _mintAndStake(amount0, amount1);
        } else {
            _unstakeIfNeeded();
            _increase(amount0, amount1);
            _stakePosition();
        }

        // Bookkeeping: asset that left the wallet into LP (v0 estimate).
        uint256 afterAsset = asset.balanceOf(address(this));
        uint256 consumed = beforeAsset > afterAsset ? beforeAsset - afterAsset : 0;
        deployedEstimate += consumed;
    }

    function _freeFunds(uint256 _amount) internal override {
        if (_amount == 0 || positionTokenId == 0) return;

        uint256 total = estimatedTotalAssets();
        if (total == 0) return;

        uint256 shareBps = _amount.mulDiv(MAX_BPS_LOCAL, total);
        if (shareBps > MAX_BPS_LOCAL) shareBps = MAX_BPS_LOCAL;

        _unstakeIfNeeded();

        (,,,,,,, uint128 liquidity,,,,) = npm.positions(positionTokenId);
        uint128 liqToRemove = uint128(uint256(liquidity).mulDiv(shareBps, MAX_BPS_LOCAL));
        if (liqToRemove > 0) {
            npm.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: positionTokenId,
                    liquidity: liqToRemove,
                    amount0Min: 0, // TODO(prod-slippage)
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
            npm.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: positionTokenId,
                    recipient: address(this),
                    amount0Max: MAX_UINT128,
                    amount1Max: MAX_UINT128
                })
            );
        }

        uint256 otherBal = otherToken.balanceOf(address(this));
        if (otherBal > 0) {
            _swapExact(address(otherToken), address(asset), otherBal);
        }

        // Reduce bookkeeping proportionally.
        deployedEstimate = deployedEstimate.mulDiv(MAX_BPS_LOCAL - shareBps, MAX_BPS_LOCAL);

        (,,,,,,, uint128 liqLeft,,,,) = npm.positions(positionTokenId);
        if (liqLeft > 0) {
            _stakePosition();
        } else {
            deployedEstimate = 0;
        }
    }

    function _harvestAndReport() internal override returns (uint256 _totalAssets) {
        if (positionTokenId != 0) {
            _claimRewards();
        }

        uint256 aeroBal = aero.balanceOf(address(this));
        if (aeroBal > 0) {
            emit RewardsClaimed(aeroBal);
            bool auctionReady =
                useAuction && auction != address(0) && aeroBal >= minAmountToSell[address(aero)];
            if (!auctionReady) {
                _swapExact(address(aero), address(asset), aeroBal);
            }
            // else: leave AERO for permissionless kickAuction()
        }

        if (!TokenizedStrategy.isShutdown()) {
            uint256 idle = asset.balanceOf(address(this));
            // Keep a dust buffer of 0 — compound all.
            if (idle > 0) {
                _deployFunds(idle);
            }
        }

        _totalAssets = estimatedTotalAssets();
    }

    /*//////////////////////////////////////////////////////////////
                        OPTIONAL OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function _tend(uint256 /*_totalIdle*/) internal override {
        // TODO(prod-range): full rebalance when out of range.
        uint256 idle = asset.balanceOf(address(this));
        if (idle > 0 && !TokenizedStrategy.isShutdown()) {
            _deployFunds(idle);
        }
    }

    function _tendTrigger() internal view override returns (bool) {
        if (positionTokenId == 0) {
            return asset.balanceOf(address(this)) > 0;
        }
        (, int24 currentTick,,,,) = pool.slot0();
        int24 mid = (tickLower + tickUpper) / 2;
        int24 halfWidth = (tickUpper - tickLower) / 2;
        if (halfWidth <= 0) return false;
        int256 deviation =
            currentTick > mid ? int256(currentTick - mid) : int256(mid - currentTick);
        uint256 deviationBps =
            uint256(deviation).mulDiv(MAX_BPS_LOCAL, uint256(int256(halfWidth)));
        return deviationBps >= tendThresholdBps;
    }

    function _emergencyWithdraw(uint256 _amount) internal override {
        _freeFunds(_amount);
    }

    function availableWithdrawLimit(address) public view override returns (uint256) {
        return estimatedTotalAssets();
    }

    /*//////////////////////////////////////////////////////////////
                        ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Idle asset + idle other (spot) + deployedEstimate.
    /// @dev TODO(prod-amounts): replace deployedEstimate with LiquidityAmounts.
    function estimatedTotalAssets() public view returns (uint256) {
        uint256 total = asset.balanceOf(address(this)) + deployedEstimate;
        uint256 otherBal = otherToken.balanceOf(address(this));
        if (otherBal > 0) {
            total += _convertOtherToAsset(otherBal);
        }
        return total;
    }

    function _strategyTotalAssets() internal view override returns (uint256) {
        return estimatedTotalAssets();
    }

    /*//////////////////////////////////////////////////////////////
                        MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function setTickRange(int24 _tickLower, int24 _tickUpper) external onlyManagement {
        require(_tickLower < _tickUpper, "ticks");
        require(_tickLower % tickSpacing == 0 && _tickUpper % tickSpacing == 0, "!spacing");
        tickLower = _tickLower;
        tickUpper = _tickUpper;
        emit TickRangeUpdated(_tickLower, _tickUpper);
    }

    function setAuction(address _auction) external onlyManagement {
        _setAuction(_auction);
    }

    function setUseAuction(bool _use) external onlyManagement {
        _setUseAuction(_use);
    }

    function setMinAmountToSell(address _token, uint256 _min) external onlyManagement {
        _setMinAmountToSell(_token, _min);
    }

    function setMaxSlippageBps(uint256 _bps) external onlyManagement {
        require(_bps <= 1_000, "!bps");
        maxSlippageBps = _bps;
        emit MaxSlippageUpdated(_bps);
    }

    function setTendThresholdBps(uint256 _bps) external onlyManagement {
        require(_bps <= MAX_BPS_LOCAL, "!bps");
        tendThresholdBps = _bps;
        emit TendThresholdUpdated(_bps);
    }

    function protectedTokens() public view override returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = address(asset);
        tokens[1] = address(otherToken);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _mintAndStake(uint256 amount0, uint256 amount1) internal {
        if (amount0 == 0 && amount1 == 0) return;

        (uint256 tokenId, uint128 liq,,) = npm.mint(
            INonfungiblePositionManager.MintParams({
                token0: pool.token0(),
                token1: pool.token1(),
                tickSpacing: tickSpacing,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp,
                sqrtPriceX96: 0
            })
        );
        positionTokenId = tokenId;
        emit PositionOpened(tokenId, tickLower, tickUpper);
        emit PositionIncreased(tokenId, liq);
        _stakePosition();
    }

    function _increase(uint256 amount0, uint256 amount1) internal {
        if (amount0 == 0 && amount1 == 0) return;
        (uint128 liq,,) = npm.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: positionTokenId,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        emit PositionIncreased(positionTokenId, liq);
    }

    function _stakePosition() internal {
        uint256 id = positionTokenId;
        if (id == 0) return;
        try npm.ownerOf(id) returns (address owner) {
            if (owner == address(this)) {
                npm.approve(address(gauge), id);
                gauge.deposit(id);
            }
        } catch {}
    }

    function _unstakeIfNeeded() internal {
        uint256 id = positionTokenId;
        if (id == 0) return;
        try npm.ownerOf(id) returns (address owner) {
            if (owner == address(gauge)) {
                gauge.withdraw(id);
            }
        } catch {}
    }

    function _claimRewards() internal {
        uint256 id = positionTokenId;
        if (id == 0) return;
        try gauge.getReward(id) {} catch {
            try gauge.getReward(address(this)) {} catch {}
        }
    }

    function _swapExact(address _from, address _to, uint256 _amountIn)
        internal
        returns (uint256 amountOut)
    {
        if (_amountIn == 0 || _from == _to) return 0;
        amountOut = swapRouter.exactInputSingle(
            ISlipstreamSwapRouter.ExactInputSingleParams({
                tokenIn: _from,
                tokenOut: _to,
                tickSpacing: tickSpacing,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: _amountIn,
                amountOutMinimum: 0, // TODO(prod-slippage)
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @dev Spot other→asset. TODO(prod-oracle): TWAP / Chainlink.
    function _convertOtherToAsset(uint256 otherAmount) internal view returns (uint256) {
        if (otherAmount == 0) return 0;
        (uint160 sqrtPriceX96,,,,,) = pool.slot0();
        if (sqrtPriceX96 == 0) return 0;
        uint256 priceX96 = Math.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        if (isAssetToken0) {
            return Math.mulDiv(otherAmount, 1 << 96, priceX96);
        } else {
            return Math.mulDiv(otherAmount, priceX96, 1 << 96);
        }
    }

    /// @notice Accept Slipstream position NFTs (e.g. gauge.withdraw → strategy).
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }
}
