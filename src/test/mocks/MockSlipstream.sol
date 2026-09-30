// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {
    INonfungiblePositionManager,
    ICLGauge,
    ICLPool,
    ISlipstreamSwapRouter
} from "../../interfaces/IAerodromeSlipstream.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockCLPool is ICLPool {
    address public override token0;
    address public override token1;
    int24 public override tickSpacing;
    int24 public currentTick;
    uint160 public sqrtPriceX96;

    constructor(address t0, address t1, int24 spacing) {
        token0 = t0;
        token1 = t1;
        tickSpacing = spacing;
        currentTick = 0;
        sqrtPriceX96 = uint160(1) << 96;
    }

    function setSlot0(uint160 sp, int24 tick) external {
        sqrtPriceX96 = sp;
        currentTick = tick;
    }

    function slot0()
        external
        view
        override
        returns (uint160, int24, uint16, uint16, uint16, bool)
    {
        return (sqrtPriceX96, currentTick, 0, 0, 0, true);
    }
}

contract MockNPM is INonfungiblePositionManager {
    uint256 public nextId = 1;
    mapping(uint256 => address) public owners;
    mapping(uint256 => uint128) public liq;
    mapping(uint256 => address) public token0Of;
    mapping(uint256 => address) public token1Of;
    mapping(uint256 => int24) public tickSpacingOf;
    mapping(uint256 => int24) public tickLowerOf;
    mapping(uint256 => int24) public tickUpperOf;
    mapping(uint256 => address) public approved;
    mapping(uint256 => uint256) internal _owed0;
    mapping(uint256 => uint256) internal _owed1;

    function mint(MintParams calldata params)
        external
        payable
        override
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        tokenId = nextId++;
        owners[tokenId] = params.recipient;
        token0Of[tokenId] = params.token0;
        token1Of[tokenId] = params.token1;
        tickSpacingOf[tokenId] = params.tickSpacing;
        tickLowerOf[tokenId] = params.tickLower;
        tickUpperOf[tokenId] = params.tickUpper;
        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;
        liquidity = uint128(uint256(amount0) + uint256(amount1));
        if (liquidity == 0) liquidity = 1;
        liq[tokenId] = liquidity;
        if (amount0 > 0) ERC20(params.token0).transferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) ERC20(params.token1).transferFrom(msg.sender, address(this), amount1);
    }

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        override
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;
        liquidity = uint128(uint256(amount0) + uint256(amount1));
        if (liquidity == 0) liquidity = 1;
        liq[params.tokenId] += liquidity;
        if (amount0 > 0) {
            ERC20(token0Of[params.tokenId]).transferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0) {
            ERC20(token1Of[params.tokenId]).transferFrom(msg.sender, address(this), amount1);
        }
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        override
        returns (uint256 amount0, uint256 amount1)
    {
        uint128 L = liq[params.tokenId];
        require(params.liquidity <= L && L > 0, "liq");
        uint256 bal0 = ERC20(token0Of[params.tokenId]).balanceOf(address(this));
        uint256 bal1 = ERC20(token1Of[params.tokenId]).balanceOf(address(this));
        amount0 = (bal0 * uint256(params.liquidity)) / uint256(L);
        amount1 = (bal1 * uint256(params.liquidity)) / uint256(L);
        liq[params.tokenId] = L - params.liquidity;
        _owed0[params.tokenId] += amount0;
        _owed1[params.tokenId] += amount1;
    }

    function collect(CollectParams calldata params)
        external
        payable
        override
        returns (uint256 amount0, uint256 amount1)
    {
        amount0 = _owed0[params.tokenId];
        amount1 = _owed1[params.tokenId];
        _owed0[params.tokenId] = 0;
        _owed1[params.tokenId] = 0;
        if (amount0 > 0) ERC20(token0Of[params.tokenId]).transfer(params.recipient, amount0);
        if (amount1 > 0) ERC20(token1Of[params.tokenId]).transfer(params.recipient, amount1);
    }

    function burn(uint256 tokenId) external payable override {
        require(liq[tokenId] == 0, "liq");
        delete owners[tokenId];
    }

    function positions(uint256 tokenId)
        external
        view
        override
        returns (
            uint96,
            address,
            address,
            address,
            int24,
            int24,
            int24,
            uint128,
            uint256,
            uint256,
            uint128,
            uint128
        )
    {
        return (
            0,
            address(0),
            token0Of[tokenId],
            token1Of[tokenId],
            tickSpacingOf[tokenId],
            tickLowerOf[tokenId],
            tickUpperOf[tokenId],
            liq[tokenId],
            0,
            0,
            uint128(_owed0[tokenId]),
            uint128(_owed1[tokenId])
        );
    }

    function ownerOf(uint256 tokenId) external view override returns (address) {
        address o = owners[tokenId];
        require(o != address(0), "!exist");
        return o;
    }

    function approve(address to, uint256 tokenId) external override {
        require(owners[tokenId] == msg.sender, "!owner");
        approved[tokenId] = to;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external override {
        require(owners[tokenId] == from, "!owner");
        require(msg.sender == from || approved[tokenId] == msg.sender, "!auth");
        owners[tokenId] = to;
        approved[tokenId] = address(0);
        if (to.code.length > 0) {
            require(
                IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, "")
                    == IERC721Receiver.onERC721Received.selector,
                "!erc721"
            );
        }
    }
}

contract MockCLGauge is ICLGauge, IERC721Receiver {
    MockNPM public npm;
    address public override rewardToken;
    address public override pool;
    address public override token0;
    address public override token1;
    mapping(uint256 => address) public stakerOf;
    mapping(address => uint256[]) internal _staked;
    mapping(uint256 => uint256) public pendingReward;

    constructor(address _npm, address _reward, address _pool, address t0, address t1) {
        npm = MockNPM(_npm);
        rewardToken = _reward;
        pool = _pool;
        token0 = t0;
        token1 = t1;
    }

    function deposit(uint256 tokenId) external override {
        npm.safeTransferFrom(msg.sender, address(this), tokenId);
        stakerOf[tokenId] = msg.sender;
        _staked[msg.sender].push(tokenId);
    }

    function withdraw(uint256 tokenId) external override {
        require(stakerOf[tokenId] == msg.sender, "!staker");
        stakerOf[tokenId] = address(0);
        npm.safeTransferFrom(address(this), msg.sender, tokenId);
    }

    function getReward(address account) external override {
        uint256[] memory ids = _staked[account];
        uint256 total;
        for (uint256 i; i < ids.length; ++i) {
            total += pendingReward[ids[i]];
            pendingReward[ids[i]] = 0;
        }
        if (total > 0) ERC20(rewardToken).transfer(account, total);
    }

    function getReward(uint256 tokenId) external override {
        address a = stakerOf[tokenId];
        uint256 amt = pendingReward[tokenId];
        pendingReward[tokenId] = 0;
        if (amt > 0 && a != address(0)) ERC20(rewardToken).transfer(a, amt);
    }

    function earned(address, uint256 tokenId) external view override returns (uint256) {
        return pendingReward[tokenId];
    }

    function rewards(uint256 tokenId) external view override returns (uint256) {
        return pendingReward[tokenId];
    }

    function nft() external view override returns (address) {
        return address(npm);
    }

    function stakedValues(address depositor) external view override returns (uint256[] memory) {
        return _staked[depositor];
    }

    function airdropReward(uint256 tokenId, uint256 amount) external {
        pendingReward[tokenId] += amount;
        ERC20(rewardToken).transferFrom(msg.sender, address(this), amount);
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev Mints MockERC20 outputs so liquidity never drains in unit tests.
contract MockSwapRouter is ISlipstreamSwapRouter {
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        ERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        // Keep 1:1 raw units for simplicity across decimals in mocks.
        amountOut = params.amountIn;
        MockERC20(params.tokenOut).mint(params.recipient, amountOut);
    }
}
