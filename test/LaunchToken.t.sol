// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "./vendor/forge-std/src/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {FirmMath} from "../src/libraries/FirmMath.sol";

contract LaunchTokenTest is Test {
    LaunchToken token;

    function setUp() public {
        token = new LaunchToken();
    }

    function test_fixedSupplyMintedToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.balanceOf(address(this)), 1_000_000_000e18);
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "The Firm");
        assertEq(token.symbol(), "NOTSTOCK");
    }

    function test_transferMovesExactly() public {
        address to = address(0xCAFE);
        assertTrue(token.transfer(to, 1e18));
        assertEq(token.balanceOf(to), 1e18);
        assertEq(token.balanceOf(address(this)), 1_000_000_000e18 - 1e18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }

    function test_transferFromNeedsAllowance() public {
        address spender = address(0xBEEF);
        vm.prank(spender);
        vm.expectRevert(LaunchToken.InsufficientAllowance.selector);
        token.transferFrom(address(this), spender, 1);
        token.approve(spender, 5);
        vm.prank(spender);
        token.transferFrom(address(this), spender, 5);
        assertEq(token.balanceOf(spender), 5);
        assertEq(token.allowance(address(this), spender), 0);
    }

    function test_transferAboveBalanceReverts() public {
        vm.prank(address(0xCAFE));
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        token.transfer(address(this), 1);
    }

    function test_noMintSelector() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }
}

/// @dev The TickMath series written without assembly must reproduce Uniswap's values.
contract FirmMathTest is Test {
    function test_knownSqrtRatios() public pure {
        assertEq(FirmMath.getSqrtRatioAtTick(0), 79228162514264337593543950336);
        assertEq(FirmMath.getSqrtRatioAtTick(-887272), 4295128739);
        assertEq(FirmMath.getSqrtRatioAtTick(887272), 1461446703485210103287273052203988822378723970342);
    }

    /// @dev Each magic constant is exercised by one single-bit tick: sqrt(1.0001^(2^k)) must equal the
    /// square of sqrt(1.0001^(2^(k-1))), and the first term must equal sqrt(1.0001).
    function test_everyTermMatchesThePower() public pure {
        uint256 prev = FirmMath.getSqrtRatioAtTick(1);
        // (sqrtP / 2^96)^2 * 1e36 == 1.0001e36 within 1e-9
        uint256 price = FirmMath.mulDiv(FirmMath.mulDiv(prev, prev, 1 << 96), 1e36, 1 << 96);
        uint256 diff = price > 10001e32 ? price - 10001e32 : 10001e32 - price;
        assertLe(diff * 1e9, 10001e32, "term 0 off");
        for (uint256 k = 1; k < 20; ++k) {
            uint256 cur = FirmMath.getSqrtRatioAtTick(int24(int256(uint256(1) << k)));
            uint256 expected = FirmMath.mulDiv(prev, prev, 1 << 96);
            diff = cur > expected ? cur - expected : expected - cur;
            assertLe(diff * 1e9, expected, "term off");
            prev = cur;
        }
    }

    function test_liquidityRoundTrip() public pure {
        uint160 p = FirmMath.getSqrtRatioAtTick(0);
        uint160 a = FirmMath.getSqrtRatioAtTick(-6000);
        uint160 b = FirmMath.getSqrtRatioAtTick(6000);
        uint128 l = FirmMath.getLiquidityForAmount0(p, b, 1_000e18);
        (uint256 a0, uint256 a1) = FirmMath.getAmountsForLiquidity(p, a, b, l);
        assertLe(a0, 1_000e18);
        assertGt(a0, 999e18);
        assertGt(a1, 0);
    }

    function testFuzz_mulDivMatchesSmallMath(uint128 x, uint128 y, uint128 d) public pure {
        vm.assume(d > 0);
        assertEq(FirmMath.mulDiv(x, y, d), uint256(x) * uint256(y) / uint256(d));
    }
}
