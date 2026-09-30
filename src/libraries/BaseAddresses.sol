// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

/// @title Canonical Base (8453) addresses for Aerodrome Slipstream WETH/USDC.
/// @dev Verify on Basescan / Aerodrome docs before production deploy.
///      Pool / gauge may differ by tickSpacing — confirm the intended CL pool.
library BaseAddresses {
    // ---- Tokens ----
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;

    // ---- Aerodrome core ----
    address internal constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    address internal constant ROUTER_V2 = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43; // classic

    // ---- Slipstream (CL / Uniswap-v3-style) ----
    address internal constant CL_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;
    address internal constant CL_GAUGE_FACTORY = 0x385293CaE378C813F16f0C1334d774AdDDf56AbB;
    // Multiple Slipstream NPM deployments exist on Base; use the one the target gauge expects.
    // Verified via CL100-WETH/USDC gauge.nft() on fork (Sep 2026).
    address internal constant NPM = 0x827922686190790b37229fd06084350E74485b72;
    address internal constant NPM_LEGACY = 0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53;
    address internal constant SLIPSTREAM_SWAP_ROUTER = 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F;

    // ---- WETH/USDC CL100 (tickSpacing = 100) — placeholders; confirm before mainnet ----
    // Popular CL100 pool + gauge (verify on Basescan / Aerodrome UI):
    address internal constant CL100_WETH_USDC_POOL = 0xAaD23a67F2AC693ABBe543489aeB3F24F561D517;
    address internal constant CL100_WETH_USDC_GAUGE = 0xF33a96b5932D9E9B9A0eDA447AbD8C9d48d2e0c8;

    int24 internal constant DEFAULT_TICK_SPACING = 100;
}
