// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FirmBase} from "./FirmBase.t.sol";
import {LpDesk} from "../src/LpDesk.sol";
import {VenueV4} from "../src/modules/VenueV4.sol";
import {FirmMath} from "../src/libraries/FirmMath.sol";
import {OpenParams, Position, KIND_V4} from "../src/interfaces/IFirm.sol";
import {PoolKey} from "../src/interfaces/IVenues.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV4Posm, MockPermit2} from "./mocks/MockV4Posm.sol";

/// @notice LpDesk positions on the Uniswap v4 venue, end to end through VenueV4 (mint, increase, collect,
/// decrease, burn) against a PositionManager mock that rounds owed amounts up, checks the maximums and
/// minimums, credits fees on increase, requires approval and refuses an empty-position poke.
contract VenueV4PositionsTest is FirmBase {
    address constant WETH = 0x4200000000000000000000000000000000000006;
    uint160 constant ONE = 79228162514264337593543950336;
    uint24 constant FEE = 3000;
    int24 constant TS = 60;

    MockERC20 weth;
    MockV4Posm posm;
    MockPermit2 permit2;

    function setUp() public override {
        super.setUp();
        _registerAndSplit();
        vm.etch(WETH, address(new MockERC20("WETH", "WETH", 18)).code);
        weth = MockERC20(WETH);
        permit2 = new MockPermit2();
        MockV4Posm impl = new MockV4Posm(address(poolManager), address(permit2));
        vm.etch(UNI_V4_POSM, address(impl).code);
        posm = MockV4Posm(UNI_V4_POSM);
    }

    // ------------------------------------------------------------ helpers

    function _notIs0() internal view returns (bool) {
        return address(token) < WETH;
    }

    /// @dev A range holding only NOTSTOCK at price ONE (beyond the price on NOTSTOCK's side).
    function _notOnly() internal view returns (int24, int24) {
        return _notIs0() ? (int24(60), int24(6000)) : (int24(-6000), int24(-60));
    }

    function _key() internal view returns (PoolKey memory) {
        (address c0, address c1) = FirmMath.sort(address(token), WETH);
        return PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: TS, hooks: address(0)});
    }

    function _position(int24 lower, int24 upper) internal pure returns (Position memory) {
        return Position({
            manager: UNI_V4_POSM,
            kind: KIND_V4,
            asset: WETH,
            fee: FEE,
            tickSpacing: TS,
            tickLower: lower,
            tickUpper: upper,
            tokenId: 0,
            open: true
        });
    }

    /// @dev sqrtPrice of ONE scaled by a sqrt factor in 1e7 (10_009_995 is +0.2% in price).
    function _scaled(uint256 sqrtFactor1e7) internal pure returns (uint160) {
        return uint160(uint256(ONE) * sqrtFactor1e7 / 1e7);
    }

    /// @dev Open parameters with the minimums set to exactly 99.5% of the amounts quoted at `quoteAt`.
    function _params(int24 lower, int24 upper, uint160 given, uint160 quoteAt, uint256 amount)
        internal
        view
        returns (OpenParams memory p)
    {
        (uint256 n, uint256 a,) = v4.quote(_position(lower, upper), quoteAt, amount, false);
        (uint256 q0, uint256 q1) = _notIs0() ? (n, a) : (a, n);
        p = OpenParams({
            asset: WETH,
            venue: UNI_V4_POSM,
            fee: FEE,
            tickSpacing: TS,
            tickLower: lower,
            tickUpper: upper,
            sqrtPriceX96: given,
            amount: amount,
            amount0Min: q0 * 9950 / 10_000,
            amount1Min: q1 * 9950 / 10_000
        });
    }

    function _openNotOnly(uint256 amount) internal returns (uint256 id) {
        (int24 lower, int24 upper) = _notOnly();
        OpenParams memory p = _params(lower, upper, ONE, ONE, amount);
        vm.prank(OPERATOR);
        id = desk.open(p);
    }

    function _openTwoSided(uint256 amount) internal returns (uint256 id) {
        weth.mint(address(desk), amount * 2);
        uint160 at = posm.priceOf(_key());
        if (at == 0) at = ONE;
        OpenParams memory p = _params(-600, 600, ONE, at, amount);
        vm.prank(OPERATOR);
        id = desk.open(p);
    }

    function _accrue(uint256 tokenId, uint256 notFee, uint256 wethFee) internal {
        weth.mint(UNI_V4_POSM, wethFee);
        vm.prank(address(factory));
        token.transfer(UNI_V4_POSM, notFee);
        (uint128 f0, uint128 f1) = _notIs0() ? (uint128(notFee), uint128(wethFee)) : (uint128(wethFee), uint128(notFee));
        posm.accrueFees(tokenId, f0, f1);
    }

    function _venueHoldsNothing() internal view {
        assertEq(token.balanceOf(address(v4)), 0, "VenueV4 keeps no NOTSTOCK");
        assertEq(weth.balanceOf(address(v4)), 0, "VenueV4 keeps no asset");
    }

    // ------------------------------------------------------------ open

    function test_openCreatesPoolAndMintsToLpDesk() public {
        assertEq(posm.priceOf(_key()), 0);
        uint256 notBefore = token.balanceOf(address(desk));
        uint256 id = _openNotOnly(1_000_000e18);
        Position memory p = desk.position(id);
        assertEq(posm.priceOf(_key()), ONE, "new pool created at the given price");
        assertEq(posm.ownerOf(p.tokenId), address(desk), "LpDesk owns the position");
        assertEq(p.tokenId, 1);
        assertGt(desk.positionLiquidity(id), 0);
        uint256 used = notBefore - token.balanceOf(address(desk));
        assertEq(token.balanceOf(UNI_V4_POSM), used, "the manager holds exactly what was used");
        assertGe(used, 1_000_000e18 * 9950 / 10_000);
        assertLe(used, 1_000_000e18 + 1);
        _venueHoldsNothing();
    }

    function test_openExistingPoolWithPriceDriftInsideBand() public {
        // The pool already trades 0.2% above the operator's price.
        uint160 drifted = _scaled(10_009_995);
        poolManager.initialize(_key(), drifted);
        weth.mint(address(desk), 10_000e18);
        uint256 notBefore = token.balanceOf(address(desk));
        uint256 wethBefore = weth.balanceOf(address(desk));
        (uint256 qn, uint256 qa,) = v4.quote(_position(-600, 600), drifted, 1_000e18, false);
        OpenParams memory p = _params(-600, 600, ONE, drifted, 1_000e18);
        vm.prank(OPERATOR);
        uint256 id = desk.open(p);
        assertEq(posm.priceOf(_key()), drifted, "an existing pool is not re-initialised");
        uint256 usedNot = notBefore - token.balanceOf(address(desk));
        uint256 usedWeth = wethBefore - weth.balanceOf(address(desk));
        assertLe(usedNot, qn, "never more than quoted at the pool's own price");
        assertLe(usedWeth, qa, "never more than quoted at the pool's own price");
        assertGe(usedNot, qn * 9950 / 10_000);
        assertGe(usedWeth, qa * 9950 / 10_000);
        assertGt(usedWeth, 0, "two-sided at the drifted price");
        assertGt(desk.positionLiquidity(id), 0);
        _venueHoldsNothing();
    }

    function test_openDriftBelowInsideBand() public {
        uint160 drifted = _scaled(9_990_005); // about -0.2% in price
        poolManager.initialize(_key(), drifted);
        weth.mint(address(desk), 10_000e18);
        OpenParams memory p = _params(-600, 600, ONE, drifted, 1_000e18);
        vm.prank(OPERATOR);
        uint256 id = desk.open(p);
        assertGt(desk.positionLiquidity(id), 0);
        _venueHoldsNothing();
    }

    function test_openRevertsWhenPoolMovedPastHalfPercent() public {
        weth.mint(address(desk), 10_000e18);
        poolManager.initialize(_key(), _scaled(10_029_955)); // about +0.6%
        OpenParams memory p = _params(-600, 600, ONE, ONE, 1_000e18);
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.PriceMoved.selector);
        desk.open(p);
        poolManager.initialize(_key(), _scaled(9_969_955)); // about -0.6%
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.PriceMoved.selector);
        desk.open(p);
    }

    function test_openRejectsMinimumsUnder995() public {
        (int24 lower, int24 upper) = _notOnly();
        OpenParams memory p = _params(lower, upper, ONE, ONE, 1_000e18);
        if (_notIs0()) p.amount0Min -= 1;
        else p.amount1Min -= 1;
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.MinTooLow.selector);
        desk.open(p);
    }

    function test_openRejectsAssetOnlyRangeAndAboveFree() public {
        // A range holding only the asset takes no NOTSTOCK: refused.
        (int24 lower, int24 upper) = _notOnly();
        OpenParams memory p = _params(-upper, -lower, ONE, ONE, 1_000e18);
        p.tickLower = -upper;
        p.tickUpper = -lower;
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.NeedsNotstock.selector);
        desk.open(p);
        // Two-sided with no WETH held: above the free balance.
        OpenParams memory q = _params(-600, 600, ONE, ONE, 1_000e18);
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.AboveFree.selector);
        desk.open(q);
    }

    function test_secondOpenInSamePoolUsesNextTokenId() public {
        uint256 a = _openNotOnly(1_000e18);
        uint256 b = _openNotOnly(2_000e18);
        assertEq(desk.position(a).tokenId, 1);
        assertEq(desk.position(b).tokenId, 2);
        assertEq(posm.ownerOf(2), address(desk));
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_openNeverTakesMoreThanQuoted(uint256 amount, uint256 sqrtFactor) public {
        amount = bound(amount, 1e9, 10_000_000e18);
        sqrtFactor = bound(sqrtFactor, 9_975_100, 10_024_900); // inside +-0.5% in price
        uint160 at = _scaled(sqrtFactor);
        poolManager.initialize(_key(), at);
        weth.mint(address(desk), 100_000_000e18);
        (uint256 qn, uint256 qa, uint128 ql) = v4.quote(_position(-600, 600), at, amount, false);
        vm.assume(ql > 0 && qn > 0);
        uint256 notBefore = token.balanceOf(address(desk));
        uint256 wethBefore = weth.balanceOf(address(desk));
        OpenParams memory p = _params(-600, 600, ONE, at, amount);
        vm.prank(OPERATOR);
        uint256 id = desk.open(p);
        assertLe(notBefore - token.balanceOf(address(desk)), qn);
        assertLe(wethBefore - weth.balanceOf(address(desk)), qa);
        assertEq(posm.getPositionLiquidity(desk.position(id).tokenId), ql);
        _venueHoldsNothing();
    }

    // ------------------------------------------------------------ collect

    function test_collectSplitsV4Fees() public {
        uint256 id = _openNotOnly(1_000_000e18);
        uint256 tokenId = desk.position(id).tokenId;
        _accrue(tokenId, 40e18, 8e18);
        uint256 burnerBefore = token.balanceOf(address(burner));
        uint256 projectBefore = weth.balanceOf(PROJECT);
        uint128 liqBefore = posm.getPositionLiquidity(tokenId);
        vm.prank(OPERATOR);
        desk.collect(id);
        assertEq(token.balanceOf(address(burner)) - burnerBefore, 40e18, "NOTSTOCK fees to Burner");
        assertEq(weth.balanceOf(PROJECT) - projectBefore, 2e18, "25% to the project wallet");
        assertEq(desk.topUpBasket(WETH), 2e18);
        assertEq(desk.buybackBasket(WETH), 2e18);
        assertEq(desk.freeBalance(WETH), 2e18, "25% free");
        assertEq(posm.getPositionLiquidity(tokenId), liqBefore, "collect leaves liquidity");
        // A repeat collects nothing and moves nothing.
        vm.prank(OPERATOR);
        desk.collect(id);
        assertEq(token.balanceOf(address(burner)) - burnerBefore, 40e18);
        assertEq(desk.topUpBasket(WETH), 2e18);
        _venueHoldsNothing();
    }

    function test_collectOnlyOperator() public {
        uint256 id = _openNotOnly(1_000e18);
        vm.prank(PROJECT);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.collect(id);
    }

    // ------------------------------------------------------------ increaseLiquidity

    /// @dev Opens a NOTSTOCK-only position, then moves the pool past it so it holds only the asset, and
    /// fills the top-up basket from fees.
    function _assetOnlyPosition() internal returns (uint256 id, uint160 price) {
        id = _openNotOnly(1_000_000e18);
        _accrue(desk.position(id).tokenId, 0, 400e18);
        vm.prank(OPERATOR);
        desk.collect(id);
        (, int24 upper) = _notOnly();
        (int24 lower,) = _notOnly();
        price = _notIs0() ? FirmMath.getSqrtRatioAtTick(upper + 60) : FirmMath.getSqrtRatioAtTick(lower - 60);
        poolManager.initialize(_key(), price);
    }

    function test_increaseLiquidityFromTopUpBasket() public {
        (uint256 id, uint160 price) = _assetOnlyPosition();
        uint256 tokenId = desk.position(id).tokenId;
        assertEq(desk.topUpBasket(WETH), 100e18);
        // Fees owed at increase time are collected and split first, not netted into the top-up.
        _accrue(tokenId, 0, 40e18);
        Position memory pos = desk.position(id);
        (uint256 qn, uint256 qa, uint128 ql) = v4.quote(pos, price, 50e18, true);
        assertEq(qn, 0);
        uint128 before = posm.getPositionLiquidity(tokenId);
        uint256 projectBefore = weth.balanceOf(PROJECT);
        vm.prank(OPERATOR);
        desk.increaseLiquidity(id, 50e18, price, ql);
        assertEq(posm.getPositionLiquidity(tokenId) - before, ql, "liquidity added as quoted");
        assertEq(weth.balanceOf(PROJECT) - projectBefore, 10e18, "owed fees were split first");
        uint256 used = 100e18 + 10e18 - desk.topUpBasket(WETH);
        assertLe(used, qa);
        assertLe(used, 50e18 + 1);
        assertGe(used, 50e18 * 9950 / 10_000);
        _venueHoldsNothing();
    }

    function test_increaseLiquidityFailurePaths() public {
        (uint256 id, uint160 price) = _assetOnlyPosition();
        uint256 basket = desk.topUpBasket(WETH);
        (,, uint128 ql) = v4.quote(desk.position(id), price, 10e18, true);
        vm.startPrank(OPERATOR);
        vm.expectRevert(LpDesk.AboveBasket.selector);
        desk.increaseLiquidity(id, basket + 1, price, ql);
        vm.expectRevert(LpDesk.PriceMoved.selector);
        desk.increaseLiquidity(id, 10e18, uint160(uint256(price) * 1004 / 1000), ql);
        vm.expectRevert(LpDesk.MinTooLow.selector);
        desk.increaseLiquidity(id, 10e18, price, uint128(uint256(ql) * 9940 / 10_000));
        vm.stopPrank();
        vm.prank(PROJECT);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.increaseLiquidity(id, 10e18, price, ql);
    }

    function test_increaseLiquidityRefusesTwoSidedPosition() public {
        uint256 id = _openTwoSided(1_000e18);
        _accrue(desk.position(id).tokenId, 0, 400e18);
        vm.prank(OPERATOR);
        desk.collect(id);
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.NeedsNotstock.selector);
        desk.increaseLiquidity(id, 10e18, ONE, 1);
    }

    // ------------------------------------------------------------ close

    function test_closeWithdrawsBurnsAndSplitsFees() public {
        uint256 id = _openTwoSided(1_000e18);
        uint256 tokenId = desk.position(id).tokenId;
        _accrue(tokenId, 5e18, 4e18);
        uint256 notBefore = token.balanceOf(address(desk));
        uint256 burnerBefore = token.balanceOf(address(burner));
        uint256 notInPosm = token.balanceOf(UNI_V4_POSM) - 5e18;
        vm.prank(OPERATOR);
        desk.close(id, 1, 1);
        assertFalse(desk.position(id).open);
        assertEq(posm.ownerOf(tokenId), address(0), "position NFT burned");
        assertEq(posm.getPositionLiquidity(tokenId), 0);
        assertEq(token.balanceOf(address(burner)) - burnerBefore, 5e18, "fees split before withdrawal");
        // Round-down on withdrawal: at most one unit of each side stays with the manager.
        assertGe(token.balanceOf(address(desk)) - notBefore + 1, notInPosm);
        assertLe(token.balanceOf(UNI_V4_POSM), 1);
        assertEq(desk.positionLiquidity(id), 0);
        _venueHoldsNothing();
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.PositionClosedError.selector);
        desk.close(id, 0, 0);
    }

    function test_closeRevertsWhenOutsBelowOperatorMinimums() public {
        uint256 id = _openTwoSided(1_000e18);
        vm.prank(OPERATOR);
        vm.expectRevert();
        desk.close(id, 1_000_000e18, 0);
        assertTrue(desk.position(id).open, "nothing changed");
    }

    // ------------------------------------------------------------ shift

    function test_shiftMovesToNewRange() public {
        uint256 id = _openNotOnly(1_000_000e18);
        uint256 oldToken = desk.position(id).tokenId;
        (int24 lower, int24 upper) = _notOnly();
        (int24 nl, int24 nu) = _notIs0() ? (lower + 600, upper + 600) : (lower - 600, upper - 600);
        vm.prank(OPERATOR);
        uint256 newId = desk.shift(id, nl, nu, 0, 0, 0, 0);
        Position memory np = desk.position(newId);
        assertFalse(desk.position(id).open);
        assertTrue(np.open);
        assertEq(np.tickLower, nl);
        assertEq(np.tickUpper, nu);
        assertEq(posm.ownerOf(oldToken), address(0), "old position burned");
        assertEq(posm.ownerOf(np.tokenId), address(desk));
        assertGt(desk.positionLiquidity(newId), 0);
        // The re-deposit is close to what was withdrawn (the manager keeps rounding dust only).
        assertGe(token.balanceOf(UNI_V4_POSM), 1_000_000e18 * 9950 / 10_000);
        _venueHoldsNothing();
    }

    function test_shiftRevertsOnMinimums() public {
        uint256 id = _openNotOnly(1_000e18);
        (int24 lower, int24 upper) = _notOnly();
        vm.startPrank(OPERATOR);
        vm.expectRevert();
        desk.shift(id, lower, upper, 2_000e18, 2_000e18, 0, 0);
        vm.expectRevert(LpDesk.BelowMinimum.selector);
        desk.shift(id, lower, upper, 0, 0, 2_000e18, 2_000e18);
        vm.stopPrank();
        assertTrue(desk.position(id).open);
    }

    // ------------------------------------------------------------ moveLiquidity

    function test_moveLiquidityBetweenV4Positions() public {
        uint256 a = _openNotOnly(1_000_000e18);
        uint256 b = _openNotOnly(1_000e18);
        uint256 ta = desk.position(a).tokenId;
        uint256 tb = desk.position(b).tokenId;
        uint128 la = posm.getPositionLiquidity(ta);
        uint128 lb = posm.getPositionLiquidity(tb);
        vm.prank(OPERATOR);
        desk.moveLiquidity(a, b, la / 2, 0, 0, 0, 0);
        assertEq(posm.getPositionLiquidity(ta), la - la / 2);
        // Same range: the moved liquidity arrives less rounding dust (round-down out, round-down re-quote,
        // and the intermediate sqrtA*sqrtB/Q96 of getLiquidityForAmount0): a few units out of ~1e24.
        assertGe(posm.getPositionLiquidity(tb), lb + la / 2 - 10, "same range: liquidity moves across");
        assertLe(posm.getPositionLiquidity(tb), lb + la / 2);
        // Empty `a` completely, then collect and close it: the empty-position poke is skipped.
        vm.prank(OPERATOR);
        desk.moveLiquidity(a, b, la - la / 2, 0, 0, 0, 0);
        assertEq(posm.getPositionLiquidity(ta), 0);
        vm.startPrank(OPERATOR);
        desk.collect(a);
        desk.close(a, 0, 0);
        vm.stopPrank();
        assertEq(posm.ownerOf(ta), address(0));
        _venueHoldsNothing();
    }

    function test_moveLiquidityFailurePaths() public {
        uint256 a = _openNotOnly(1_000e18);
        uint256 b = _openNotOnly(1_000e18);
        uint128 la = posm.getPositionLiquidity(desk.position(a).tokenId);
        vm.startPrank(OPERATOR);
        vm.expectRevert(LpDesk.AssetMismatch.selector);
        desk.moveLiquidity(a, a, la, 0, 0, 0, 0);
        vm.expectRevert();
        desk.moveLiquidity(a, b, la + 1, 0, 0, 0, 0);
        vm.expectRevert(LpDesk.BelowMinimum.selector);
        desk.moveLiquidity(a, b, la, 0, 0, 10_000e18, 10_000e18);
        vm.stopPrank();
        vm.prank(PROJECT);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.moveLiquidity(a, b, la, 0, 0, 0, 0);
    }

    // ------------------------------------------------------------ module access

    function test_venueActionsOnlyByLpDesk() public {
        uint256 id = _openNotOnly(1_000e18);
        Position memory p = desk.position(id);
        vm.startPrank(OPERATOR);
        vm.expectRevert(VenueV4.NotLpDesk.selector);
        v4.mint(p, ONE, 1, 1, 1);
        vm.expectRevert(VenueV4.NotLpDesk.selector);
        v4.increase(p, 1, 1, 1);
        vm.expectRevert(VenueV4.NotLpDesk.selector);
        v4.decrease(p, 1, 0, 0);
        vm.expectRevert(VenueV4.NotLpDesk.selector);
        v4.burnPosition(p);
        vm.stopPrank();
    }

    function test_positionNotDecreasableByOthersAtManager() public {
        uint256 id = _openNotOnly(1_000e18);
        uint256 tokenId = desk.position(id).tokenId;
        bytes memory actions = abi.encodePacked(uint8(0x01), uint8(0x11));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(1), uint256(0), uint256(0), bytes(""));
        params[1] = abi.encode(_key().currency0, _key().currency1, address(this));
        vm.expectRevert(bytes("NotApproved"));
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }
}
