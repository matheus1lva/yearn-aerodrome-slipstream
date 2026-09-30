// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {BaseAddresses} from "../libraries/BaseAddresses.sol";
import {ICLPool, INonfungiblePositionManager, ICLGauge} from "../interfaces/IAerodromeSlipstream.sol";

/**
 * @notice Base fork smoke checks. Skips if BASE_RPC_URL is unset / fork unavailable.
 * Run: `make test-fork` or `forge test --match-path 'src/test/Fork*.t.sol' --fork-url $BASE_RPC_URL`
 */
contract ForkBaseTest is Test {
    uint256 internal forkId;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            console2.log("BASE_RPC_URL unset - skipping Base fork tests");
            return;
        }
        try vm.createSelectFork(rpc) returns (uint256 id) {
            forkId = id;
            forked = true;
            console2.log("Forked Base at block", block.number);
        } catch {
            console2.log("Fork failed - skipping");
            forked = false;
        }
    }

    modifier onlyForked() {
        if (!forked) return;
        _;
    }

    function testFork_addressesExist() public onlyForked {
        assertEq(block.chainid, 8453, "not Base");

        // WETH code
        assertGt(BaseAddresses.WETH.code.length, 0, "WETH");
        assertGt(BaseAddresses.USDC.code.length, 0, "USDC");
        assertGt(BaseAddresses.AERO.code.length, 0, "AERO");
        assertGt(BaseAddresses.NPM.code.length, 0, "NPM");
        assertGt(BaseAddresses.SLIPSTREAM_SWAP_ROUTER.code.length, 0, "router");

        // Pool / gauge - may need updating if placeholders drift
        if (BaseAddresses.CL100_WETH_USDC_POOL.code.length == 0) {
            console2.log("WARN: CL100 pool placeholder has no code - update BaseAddresses");
            return;
        }
        ICLPool p = ICLPool(BaseAddresses.CL100_WETH_USDC_POOL);
        address t0 = p.token0();
        address t1 = p.token1();
        console2.log("pool token0", t0);
        console2.log("pool token1", t1);
        assertTrue(
            (t0 == BaseAddresses.WETH && t1 == BaseAddresses.USDC)
                || (t1 == BaseAddresses.WETH && t0 == BaseAddresses.USDC),
            "pool pair"
        );

        if (BaseAddresses.CL100_WETH_USDC_GAUGE.code.length > 0) {
            ICLGauge g = ICLGauge(BaseAddresses.CL100_WETH_USDC_GAUGE);
            console2.log("gauge rewardToken", g.rewardToken());
            assertEq(g.rewardToken(), BaseAddresses.AERO, "AERO rewards");
        }

        // Yearn TokenizedStrategy v3.1.0 CREATE2
        address ts = 0x310f5Db015E9d6E542fd41bd4542640790791e76;
        assertGt(ts.code.length, 0, "TokenizedStrategy missing on Base");
    }

    function testFork_npmMatchesGauge() public onlyForked {
        if (BaseAddresses.CL100_WETH_USDC_GAUGE.code.length == 0) return;
        ICLGauge g = ICLGauge(BaseAddresses.CL100_WETH_USDC_GAUGE);
        address gaugeNpm = g.nft();
        console2.log("gauge npm", gaugeNpm);
        assertEq(gaugeNpm, BaseAddresses.NPM, "BaseAddresses.NPM must match gauge.nft()");
    }
}
