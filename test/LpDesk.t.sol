// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FirmBase} from "./FirmBase.t.sol";
import {LpDesk} from "../src/LpDesk.sol";
import {VenueV3} from "../src/modules/VenueV3.sol";
import {FirmMath} from "../src/libraries/FirmMath.sol";
import {OpenParams, Position} from "../src/interfaces/IFirm.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Venue, MockV3Pool} from "./mocks/MockV3Venue.sol";
import {ICLPositionManager} from "../src/interfaces/IVenues.sol";

/// @notice LpDesk positions on the V3 and CL venue kinds, with the mock venues etched at the Base
/// addresses of PriceGuard's fixed list (Uniswap v3, PancakeSwap v3, Aerodrome Slipstream).
contract LpDeskTest is FirmBase {
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant UNI_V3 = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address constant PANCAKE_V3 = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address constant AERO_CL = 0x827922686190790b37229fd06084350E74485b72;
    uint160 constant ONE = 79228162514264337593543950336;

    MockERC20 weth;
    MockERC20 usdc;
    MockV3Venue uni;
    MockV3Venue pancake;
    MockV3Venue aero;

    function setUp() public override {
        super.setUp();
        _registerAndSplit();
        vm.etch(WETH, address(new MockERC20("WETH", "WETH", 18)).code);
        vm.etch(USDC, address(new MockERC20("USDC", "USDC", 6)).code);
        weth = MockERC20(WETH);
        usdc = MockERC20(USDC);
        vm.etch(UNI_V3, address(new MockV3Venue(false, false)).code);
        vm.etch(PANCAKE_V3, address(new MockV3Venue(false, true)).code);
        vm.etch(AERO_CL, address(new MockV3Venue(true, false)).code);
        uni = MockV3Venue(UNI_V3);
        pancake = MockV3Venue(PANCAKE_V3);
        aero = MockV3Venue(AERO_CL);
    }

    // ------------------------------------------------------------ helpers

    function _notIs0(address asset) internal view returns (bool) {
        return address(token) < asset;
    }

    /// @dev A range single-sided in NOTSTOCK just beyond price ONE.
    function _singleSided(address asset) internal view returns (int24 lower, int24 upper) {
        return _notIs0(asset) ? (int24(60), int24(6000)) : (int24(-6000), int24(-60));
    }

    function _params(address asset, address venue, uint24 fee, int24 ts, uint256 amount)
        internal
        view
        returns (OpenParams memory p)
    {
        (int24 lower, int24 upper) = _singleSided(asset);
        p = OpenParams({
            asset: asset,
            venue: venue,
            fee: fee,
            tickSpacing: ts,
            tickLower: lower,
            tickUpper: upper,
            sqrtPriceX96: ONE,
            amount: amount,
            amount0Min: 0,
            amount1Min: 0
        });
        (uint256 n, uint256 a,) = v3.quote(
            Position({
                manager: venue,
                kind: ts == 0 ? 1 : 2,
                asset: asset,
                fee: fee,
                tickSpacing: ts,
                tickLower: lower,
                tickUpper: upper,
                tokenId: 0,
                open: true
            }),
            ONE,
            amount,
            false
        );
        (p.amount0Min, p.amount1Min) =
            _notIs0(asset) ? (n * 995 / 1000, a * 995 / 1000) : (a * 995 / 1000, n * 995 / 1000);
    }

    function _open(address asset, address venue, uint256 amount) internal returns (uint256 id) {
        OpenParams memory p = _params(asset, venue, 3000, 0, amount);
        vm.prank(OPERATOR);
        id = desk.open(p);
    }

    function _accrue(MockV3Venue venue, uint256 tokenId, address asset, uint256 notFee, uint256 assetFee) internal {
        MockERC20(asset).mint(address(venue), assetFee);
        vm.prank(address(factory));
        token.transfer(address(venue), notFee);
        (uint128 f0, uint128 f1) =
            _notIs0(asset) ? (uint128(notFee), uint128(assetFee)) : (uint128(assetFee), uint128(notFee));
        venue.accrueFees(tokenId, f0, f1);
    }

    // ------------------------------------------------------------ open

    function test_operatorOpensDuringBootstrap() public {
        uint256 before = token.balanceOf(address(desk));
        uint256 id = _open(WETH, UNI_V3, 1_000_000e18);
        Position memory p = desk.position(id);
        assertTrue(p.open);
        assertEq(p.manager, UNI_V3);
        assertEq(p.asset, WETH);
        assertEq(p.tickSpacing, 60);
        assertEq(uni.ownerOf(p.tokenId), address(desk));
        uint256 used = before - token.balanceOf(address(desk));
        assertGt(used, 999_000e18);
        assertLe(used, 1_000_000e18);
        assertEq(token.balanceOf(address(v3)), 0, "module keeps nothing");
        assertGt(desk.positionLiquidity(id), 0);
        // Second position on another venue kind (CL) at tick spacing 200.
        OpenParams memory p2 = _params(WETH, AERO_CL, 0, 200, 1_000e18);
        vm.prank(OPERATOR);
        uint256 id2 = desk.open(p2);
        assertEq(desk.position(id2).fee, 3000);
        assertEq(desk.positionCount(), 2);
    }

    function test_openRequiresOperatorAndBootstrap() public {
        OpenParams memory p = _params(WETH, UNI_V3, 3000, 0, 1e18);
        vm.prank(PROJECT);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.open(p);
        vm.warp(desk.bootstrapEnd());
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.BootstrapOver.selector);
        desk.open(p);
    }

    function test_openRejectsUnlistedAssetVenueFeeTierAndAmounts() public {
        OpenParams memory p = _params(WETH, UNI_V3, 3000, 0, 1e18);
        p.asset = address(0xBEEF);
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.UnlistedAsset.selector);
        desk.open(p);
        p = _params(WETH, UNI_V3, 3000, 0, 1e18);
        p.venue = address(0xBEEF);
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.UnlistedVenue.selector);
        desk.open(p);
        p = _params(WETH, UNI_V3, 3000, 0, 1e18);
        p.fee = 1234;
        vm.prank(OPERATOR);
        vm.expectRevert(VenueV3.FeeTierDisabled.selector);
        desk.open(p);
        p = _params(WETH, UNI_V3, 3000, 0, 600_000_000e18);
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.AboveFree.selector);
        desk.open(p);
        p = _params(WETH, UNI_V3, 3000, 0, 1e18);
        if (_notIs0(WETH)) p.amount0Min = p.amount0Min * 99 / 100;
        else p.amount1Min = p.amount1Min * 99 / 100;
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.MinTooLow.selector);
        desk.open(p);
        // A range on the asset side only takes no NOTSTOCK.
        p = _params(WETH, UNI_V3, 3000, 0, 1e18);
        (p.tickLower, p.tickUpper) = _notIs0(WETH) ? (int24(-6000), int24(-60)) : (int24(60), int24(6000));
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.NeedsNotstock.selector);
        desk.open(p);
    }

    /// @dev The 0.5% band applies to the price (sqrtPrice squared), not to sqrtPriceX96: a sqrt price 0.4%
    /// off is a price about 0.8% off and reverts; a sqrt price 0.2% off (price about 0.4% off) opens.
    function test_openPriceCheckAgainstExistingPool() public {
        (address t0, address t1) = FirmMath.sort(address(token), WETH);
        uni.createPoolAt(t0, t1, 3000, ONE * 1006 / 1000);
        OpenParams memory p = _params(WETH, UNI_V3, 3000, 0, 1e18);
        MockV3Pool pool = MockV3Pool(uni.getPool(t0, t1, uint24(3000)));
        uint160[4] memory outside =
            [ONE * 1006 / 1000, ONE * 1004 / 1000, uint160(79545075164321394943918126137), ONE * 996 / 1000];
        for (uint256 i; i < outside.length; ++i) {
            pool.setPrice(outside[i]);
            vm.prank(OPERATOR);
            vm.expectRevert(LpDesk.PriceMoved.selector);
            desk.open(p);
        }
        pool.setPrice(ONE * 1002 / 1000);
        vm.prank(OPERATOR);
        desk.open(p);
        pool.setPrice(ONE * 998 / 1000);
        vm.prank(OPERATOR);
        desk.open(p);
    }

    function _isqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x + 1) / 2;
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        }
    }

    /// @dev Exact band edges: a pool price of exactly +0.5% or -0.5% passes, one unit of sqrt price beyond fails.
    function test_priceBandEdges() public {
        (address t0, address t1) = FirmMath.sort(address(token), WETH);
        uni.createPoolAt(t0, t1, 3000, ONE);
        MockV3Pool pool = MockV3Pool(uni.getPool(t0, t1, uint24(3000)));
        OpenParams memory p = _params(WETH, UNI_V3, 3000, 0, 1e18);
        // sqrt(1.005) * 2^96 and sqrt(0.995) * 2^96, rounded inward.
        uint160 hiEdge = uint160(_isqrt(uint256(ONE) * uint256(ONE) / 1000 * 1005));
        uint160 loEdge = uint160(_isqrt(uint256(ONE) * uint256(ONE) / 1000 * 995) + 1);
        pool.setPrice(hiEdge);
        vm.prank(OPERATOR);
        desk.open(p);
        pool.setPrice(loEdge);
        vm.prank(OPERATOR);
        desk.open(p);
        pool.setPrice(hiEdge + 2);
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.PriceMoved.selector);
        desk.open(p);
        pool.setPrice(loEdge - 2);
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.PriceMoved.selector);
        desk.open(p);
    }

    /// @dev An open on an existing pool whose price is inside the band but not exactly the given price is
    /// quoted at the pool's own price, so a two-sided range takes both amounts in proportion.
    function test_twoSidedOpenOnExistingPoolAtDriftedPrice() public {
        (address t0, address t1) = FirmMath.sort(address(token), WETH);
        uint160 poolPrice = ONE * 1002 / 1000;
        uni.createPoolAt(t0, t1, 3000, poolPrice);
        weth.mint(address(desk), 10e18);
        OpenParams memory p = _params(WETH, UNI_V3, 3000, 0, 1e18);
        (p.tickLower, p.tickUpper) = (int24(-600), int24(600));
        Position memory q = Position(UNI_V3, 1, WETH, 3000, 60, -600, 600, 0, true);
        (uint256 n, uint256 a,) = v3.quote(q, poolPrice, 1e18, false);
        (p.amount0Min, p.amount1Min) =
            _notIs0(WETH) ? (n * 995 / 1000, a * 995 / 1000) : (a * 995 / 1000, n * 995 / 1000);
        uint256 notBefore = token.balanceOf(address(desk));
        uint256 wethBefore = weth.balanceOf(address(desk));
        vm.prank(OPERATOR);
        desk.open(p);
        assertApproxEqAbs(notBefore - token.balanceOf(address(desk)), n, 2, "NOTSTOCK at the pool's price");
        assertApproxEqAbs(wethBefore - weth.balanceOf(address(desk)), a, 2, "asset at the pool's price");
    }

    /// @dev Aerodrome Slipstream creates the pool whenever mint's sqrtPriceX96 is nonzero, and creating an
    /// existing pool reverts (the mock follows that). A second open and a shift on an existing CL pool mint
    /// with sqrtPriceX96 = 0.
    function test_clSecondOpenAndShiftOnExistingPool() public {
        OpenParams memory p = _params(WETH, AERO_CL, 0, 200, 1_000e18);
        vm.prank(OPERATOR);
        uint256 id = desk.open(p);
        vm.prank(OPERATOR);
        uint256 id2 = desk.open(p);
        assertEq(desk.position(id2).manager, AERO_CL);
        (int24 lo, int24 hi) = _notIs0(WETH) ? (int24(200), int24(8000)) : (int24(-8000), int24(-200));
        vm.prank(OPERATOR);
        uint256 newId = desk.shift(id, lo, hi, 0, 0, 0, 0);
        Position memory moved = desk.position(newId);
        assertEq(moved.tickLower, lo);
        assertEq(moved.tickUpper, hi);
        assertFalse(desk.position(id).open);
        assertGt(desk.positionLiquidity(newId), 0);
    }

    /// @dev A direct mint with a nonzero price on an existing CL pool is exactly what Slipstream refuses.
    function test_clMockRefusesCreateOnExistingPool() public {
        (address t0, address t1) = FirmMath.sort(address(token), WETH);
        aero.createPoolAt(t0, t1, 200, ONE);
        ICLPositionManager.MintParams memory m = ICLPositionManager.MintParams({
            token0: t0,
            token1: t1,
            tickSpacing: 200,
            tickLower: -200,
            tickUpper: 200,
            amount0Desired: 0,
            amount1Desired: 0,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp,
            sqrtPriceX96: ONE
        });
        vm.expectRevert(bytes("pool exists"));
        aero.mint(m);
    }

    function test_openOnPancakeCreatesPoolAtGivenPrice() public {
        OpenParams memory p = _params(USDC, PANCAKE_V3, 500, 0, 1_000e18);
        p.sqrtPriceX96 = ONE / 3;
        (int24 lo, int24 hi) = _singleSided(USDC);
        // Shift the range to sit beyond ONE/3 (tick of ONE/3 is about -21972).
        (p.tickLower, p.tickUpper) = lo > 0 ? (int24(-21900), int24(-10000)) : (int24(-40000), int24(-22100));
        (uint256 n, uint256 a,) = v3.quote(
            Position(PANCAKE_V3, 1, USDC, 500, 10, p.tickLower, p.tickUpper, 0, true), p.sqrtPriceX96, 1_000e18, false
        );
        (p.amount0Min, p.amount1Min) = lo > 0 ? (n * 995 / 1000, a * 995 / 1000) : (a * 995 / 1000, n * 995 / 1000);
        vm.prank(OPERATOR);
        desk.open(p);
        (address t0, address t1) = FirmMath.sort(address(token), USDC);
        assertEq(MockV3Pool(pancake.getPool(t0, t1, uint24(500))).sqrtPriceX96(), ONE / 3);
        assertEq(hi, hi);
    }

    // ------------------------------------------------------------ collect and split

    function test_collectSplitsFeesExactly() public {
        uint256 id = _open(WETH, UNI_V3, 1_000e18);
        uint256 tokenId = desk.position(id).tokenId;
        _accrue(uni, tokenId, WETH, 40e18, 8e18);
        uint256 projectBefore = weth.balanceOf(PROJECT);
        vm.prank(PROJECT);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.collect(id);
        vm.prank(OPERATOR);
        desk.collect(id);
        assertEq(token.balanceOf(address(burner)), 40e18, "NOTSTOCK fee to Burner");
        assertEq(desk.buybackBasket(WETH), 2e18);
        assertEq(weth.balanceOf(PROJECT) - projectBefore, 2e18);
        assertEq(desk.topUpBasket(WETH), 2e18);
        assertEq(desk.freeBalance(WETH), 2e18);
        assertEq(weth.balanceOf(address(desk)), 6e18);
    }

    function test_collectImdFeesCreditFirmVaultBucket() public {
        uint256 id = _open(IMD_ADDR, UNI_V3, 1_000e18);
        uint256 tokenId = desk.position(id).tokenId;
        _accrue(uni, tokenId, IMD_ADDR, 0, 100e18);
        vm.prank(OPERATOR);
        desk.collect(id);
        assertEq(vault.buybackBucket(), 25e18);
        assertEq(imd.balanceOf(address(vault)), 25e18);
        assertEq(imd.balanceOf(PROJECT), 25e18);
        assertEq(desk.topUpBasket(IMD_ADDR), 25e18);
        assertEq(desk.freeBalance(IMD_ADDR), 25e18);
        assertEq(desk.buybackBasket(IMD_ADDR), 0, "IMD buyback share lives in FirmVault");
    }

    function test_collectImdFeesCreditMeasuredAmountUnderTransferFee() public {
        uint256 id = _open(IMD_ADDR, UNI_V3, 1_000e18);
        _accrue(uni, desk.position(id).tokenId, IMD_ADDR, 0, 100e18);
        imd.setFeeBps(400); // the IMD issuer taxes every transfer: venue -> LpDesk (96) and LpDesk -> FirmVault
        vm.prank(OPERATOR);
        desk.collect(id);
        assertEq(imd.balanceOf(address(vault)), 23.04e18);
        assertEq(vault.buybackBucket(), 23.04e18, "bucket equals what arrived");
        assertEq(desk.topUpBasket(IMD_ADDR), 24e18, "split of the measured 96");
        assertEq(imd.balanceOf(PROJECT), 23.04e18);
        assertLe(desk.topUpBasket(IMD_ADDR) + desk.buybackBasket(IMD_ADDR), imd.balanceOf(address(desk)));
    }

    // ------------------------------------------------------------ close and shift

    function test_closeReturnsPrincipalToFreeBalance() public {
        uint256 id = _open(WETH, UNI_V3, 1_000e18);
        uint256 tokenId = desk.position(id).tokenId;
        _accrue(uni, tokenId, WETH, 4e18, 4e18);
        uint256 notBefore = token.balanceOf(address(desk));
        vm.prank(PROJECT);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.close(id, 0, 0);
        vm.prank(OPERATOR);
        desk.close(id, 0, 0);
        assertFalse(desk.position(id).open);
        uint256 got = token.balanceOf(address(desk)) - notBefore;
        assertGt(got, 999e18, "principal back");
        assertEq(token.balanceOf(address(burner)), 4e18);
        assertEq(desk.topUpBasket(WETH), 1e18);
        assertEq(desk.buybackBasket(WETH), 1e18);
        assertEq(weth.balanceOf(PROJECT), 1e18);
        assertEq(desk.freeBalance(WETH), 1e18);
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.PositionClosedError.selector);
        desk.close(id, 0, 0);
    }

    function test_closeRespectsManualMinimumOuts() public {
        uint256 id = _open(WETH, UNI_V3, 1_000e18);
        (uint256 min0, uint256 min1) = _notIs0(WETH) ? (uint256(1_001e18), uint256(0)) : (uint256(0), uint256(1_001e18));
        vm.prank(OPERATOR);
        vm.expectRevert("Price slippage check");
        desk.close(id, min0, min1);
        (min0, min1) = _notIs0(WETH) ? (uint256(990e18), uint256(0)) : (uint256(0), uint256(990e18));
        vm.prank(OPERATOR);
        desk.close(id, min0, min1);
    }

    function test_shiftMovesRange() public {
        uint256 id = _open(WETH, UNI_V3, 1_000e18);
        (int24 lo, int24 hi) = _notIs0(WETH) ? (int24(120), int24(12000)) : (int24(-12000), int24(-120));
        vm.prank(OPERATOR);
        uint256 newId = desk.shift(id, lo, hi, 0, 0, 0, 0);
        assertFalse(desk.position(id).open);
        Position memory p = desk.position(newId);
        assertTrue(p.open);
        assertEq(p.tickLower, lo);
        assertGt(desk.positionLiquidity(newId), 0);
        assertLt(token.balanceOf(address(desk)), 500_000_000e18 - 990e18, "re-deposited");
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.BelowMinimum.selector);
        desk.shift(newId, lo, hi, 0, 0, type(uint256).max, type(uint256).max);
    }

    // ------------------------------------------------------------ top-up

    function test_increaseLiquidityFromTopUpBasket() public {
        uint256 id = _open(WETH, UNI_V3, 1_000e18);
        _accrue(uni, desk.position(id).tokenId, WETH, 0, 8e18);
        vm.prank(OPERATOR);
        desk.collect(id);
        assertEq(desk.topUpBasket(WETH), 2e18);
        // The position's range is NOTSTOCK-only: it takes no asset at all.
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.NothingTaken.selector);
        desk.increaseLiquidity(id, 1e18, ONE, 0);
        // An asset-side position.
        OpenParams memory p = _params(WETH, UNI_V3, 3000, 0, 1e18);
        (p.tickLower, p.tickUpper) = _notIs0(WETH) ? (int24(-6000), int24(-60)) : (int24(60), int24(6000));
        // Open needs NOTSTOCK: give the range both sides to open it, then test a top-up on a pure asset range
        // by shifting it: use a two-sided range for the open instead.
        (p.tickLower, p.tickUpper) = (int24(-6000), int24(6000));
        (uint256 n, uint256 a,) = v3.quote(Position(UNI_V3, 1, WETH, 3000, 60, -6000, 6000, 0, true), ONE, 1e18, false);
        (p.amount0Min, p.amount1Min) =
            _notIs0(WETH) ? (n * 995 / 1000, a * 995 / 1000) : (a * 995 / 1000, n * 995 / 1000);
        OpenParams memory big = _params(WETH, UNI_V3, 3000, 0, 600_000_000e18);
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.AboveFree.selector);
        desk.open(big);
        vm.prank(OPERATOR);
        uint256 id2 = desk.open(p);
        // A two-sided range needs NOTSTOCK for the asset amount: a top-up there reverts.
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.NeedsNotstock.selector);
        desk.increaseLiquidity(id2, 1e18, ONE, 0);
        (int24 lo, int24 hi) = _notIs0(WETH) ? (int24(-6000), int24(-60)) : (int24(60), int24(6000));
        vm.prank(OPERATOR);
        uint256 id3 = desk.shift(id2, lo, hi, 0, 0, 0, 0);
        uint128 liqBefore = desk.positionLiquidity(id3);
        (,, uint128 quoted) = v3.quote(desk.position(id3), ONE, 1e18, true);
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.MinTooLow.selector);
        desk.increaseLiquidity(id3, 1e18, ONE, quoted * 99 / 100);
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.AboveBasket.selector);
        desk.increaseLiquidity(id3, 3e18, ONE, quoted);
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.PriceMoved.selector);
        desk.increaseLiquidity(id3, 1e18, ONE * 1006 / 1000, quoted);
        uint256 basket = desk.topUpBasket(WETH);
        uint256 wethBefore = weth.balanceOf(address(desk));
        vm.prank(OPERATOR);
        desk.increaseLiquidity(id3, 1e18, ONE, quoted * 995 / 1000);
        uint256 used = wethBefore - weth.balanceOf(address(desk));
        assertEq(basket - desk.topUpBasket(WETH), used, "basket decreases by what the position took");
        assertLe(used, 1e18);
        assertGt(desk.positionLiquidity(id3), liqBefore);
        vm.prank(PROJECT);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.increaseLiquidity(id3, 1, ONE, 0);
    }

    // ------------------------------------------------------------ buyback and burn

    function test_buybackSwapsBasketToDeadOnV3AndPancake() public {
        _buybackOn(UNI_V3, uni);
        _buybackOn(PANCAKE_V3, pancake);
    }

    function _buybackOn(address venueAddr, MockV3Venue venue) internal {
        uint256 id = _open(WETH, venueAddr, 1_000e18);
        _accrue(venue, desk.position(id).tokenId, WETH, 0, 8e18);
        uint256 basketBefore = desk.buybackBasket(WETH);
        vm.prank(OPERATOR);
        desk.collect(id);
        uint256 basket = desk.buybackBasket(WETH);
        assertEq(basket, basketBefore + 2e18);
        (address t0, address t1) = FirmMath.sort(address(token), WETH);
        MockV3Pool pool = MockV3Pool(venue.getPool(t0, t1, uint24(3000)));
        vm.prank(address(factory));
        token.transfer(address(pool), 10e18);
        uint256 quoted = pool.quoteOut(WETH == t0, 1e18);
        vm.prank(OPERATOR);
        vm.expectRevert(VenueV3.BelowMinOut.selector);
        desk.buyback(id, 1e18, quoted + 1);
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.AboveBasket.selector);
        desk.buyback(id, basket + 1, 0);
        vm.prank(PROJECT);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.buyback(id, 1e18, 0);
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(OPERATOR);
        desk.buyback(id, 1e18, quoted);
        assertEq(token.balanceOf(DEAD) - deadBefore, quoted, "all NOTSTOCK out to dead");
        assertEq(desk.buybackBasket(WETH), basket - 1e18);
        assertEq(weth.balanceOf(address(v3)), 0);
    }

    /// @dev The pool consumes only 1e18 of a 2e18 buyback: 1e18 leaves the basket, the unspent 1e18 stays in
    /// it, and the free balance does not grow.
    function test_buybackPartialFillStaysInBasket() public {
        uint256 id = _open(WETH, UNI_V3, 1_000e18);
        _accrue(uni, desk.position(id).tokenId, WETH, 0, 8e18);
        vm.prank(OPERATOR);
        desk.collect(id);
        assertEq(desk.buybackBasket(WETH), 2e18);
        (address t0, address t1) = FirmMath.sort(address(token), WETH);
        MockV3Pool pool = MockV3Pool(uni.getPool(t0, t1, uint24(3000)));
        vm.prank(address(factory));
        token.transfer(address(pool), 10e18);
        pool.setMaxIn(1e18);
        uint256 freeBefore = desk.freeBalance(WETH);
        uint256 quoted = pool.quoteOut(WETH == t0, 1e18);
        vm.prank(OPERATOR);
        desk.buyback(id, 2e18, 0);
        assertEq(desk.buybackBasket(WETH), 1e18, "unspent input stays in the buyback basket");
        assertEq(desk.freeBalance(WETH), freeBefore, "free balance unchanged");
        assertEq(token.balanceOf(DEAD), quoted);
        assertEq(weth.balanceOf(address(v3)), 0);
    }

    /// @dev increaseLiquidity collects and splits owed fees before topping up: the project wallet receives
    /// its quarter and the basket pays only for the new liquidity.
    function test_increaseLiquidityCollectsFeesFirst() public {
        uint256 id = _open(WETH, UNI_V3, 1_000e18);
        _accrue(uni, desk.position(id).tokenId, WETH, 0, 8e18);
        vm.prank(OPERATOR);
        desk.collect(id);
        // An asset-only position: open two-sided, then shift to an asset-side range.
        OpenParams memory p = _params(WETH, UNI_V3, 3000, 0, 1e18);
        (p.tickLower, p.tickUpper) = (int24(-6000), int24(6000));
        (uint256 n, uint256 a,) = v3.quote(Position(UNI_V3, 1, WETH, 3000, 60, -6000, 6000, 0, true), ONE, 1e18, false);
        (p.amount0Min, p.amount1Min) =
            _notIs0(WETH) ? (n * 995 / 1000, a * 995 / 1000) : (a * 995 / 1000, n * 995 / 1000);
        vm.prank(OPERATOR);
        uint256 id2 = desk.open(p);
        (int24 lo, int24 hi) = _notIs0(WETH) ? (int24(-6000), int24(-60)) : (int24(60), int24(6000));
        vm.prank(OPERATOR);
        uint256 id3 = desk.shift(id2, lo, hi, 0, 0, 0, 0);
        _accrue(uni, desk.position(id3).tokenId, WETH, 4e18, 4e18);
        uint256 projectBefore = weth.balanceOf(PROJECT);
        uint256 burnerBefore = token.balanceOf(desk.burner());
        uint256 buybackBefore = desk.buybackBasket(WETH);
        uint256 basket = desk.topUpBasket(WETH) + 1e18; // after the split adds its quarter
        (,, uint128 quoted) = v3.quote(desk.position(id3), ONE, 1e18, true);
        uint256 wethBefore = weth.balanceOf(address(desk));
        vm.prank(OPERATOR);
        desk.increaseLiquidity(id3, 1e18, ONE, quoted * 995 / 1000);
        assertEq(weth.balanceOf(PROJECT) - projectBefore, 1e18, "project wallet quarter");
        assertEq(desk.buybackBasket(WETH) - buybackBefore, 1e18, "buyback quarter");
        assertEq(token.balanceOf(desk.burner()) - burnerBefore, 4e18, "NOTSTOCK fees to Burner");
        // WETH in: 4e18 fees; out: 1e18 project, `used` into the position.
        uint256 used = wethBefore + 4e18 - 1e18 - weth.balanceOf(address(desk));
        assertEq(basket - desk.topUpBasket(WETH), used, "basket pays exactly the new liquidity");
        assertGt(used, 0);
        assertLe(used, 1e18);
    }

    function test_buybackRejectsImdPosition() public {
        uint256 id = _open(IMD_ADDR, UNI_V3, 1_000e18);
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.ImdNotBuyable.selector);
        desk.buyback(id, 1, 0);
    }

    function test_burnFreeNotstockOnly() public {
        vm.prank(PROJECT);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.burn(1);
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.AboveFree.selector);
        desk.burn(500_000_000e18 + 1);
        vm.prank(OPERATOR);
        desk.burn(5e18);
        assertEq(token.balanceOf(DEAD), 5e18);
        assertEq(desk.freeBalance(address(token)), 500_000_000e18 - 5e18);
    }

    function test_basketsAreNotFreeBalance() public {
        uint256 id = _open(WETH, UNI_V3, 1_000e18);
        _accrue(uni, desk.position(id).tokenId, WETH, 0, 8e18);
        vm.prank(OPERATOR);
        desk.collect(id);
        assertEq(weth.balanceOf(address(desk)), 6e18);
        assertEq(desk.freeBalance(WETH), 2e18);
        // A two-sided open may use only the free 2e18 of WETH.
        OpenParams memory p = _params(WETH, UNI_V3, 3000, 0, 3e18);
        (p.tickLower, p.tickUpper) = (int24(-60), int24(60));
        p.amount0Min = 0;
        p.amount1Min = 0;
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.AboveFree.selector);
        desk.open(p);
    }

    function test_creditFromFirmVaultOnlyByFirmVault() public {
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.NotFirmVault.selector);
        desk.creditFromFirmVault(1);
    }

    function test_setOperatorHandsRole() public {
        vm.prank(PROJECT);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.setOperator(PROJECT);
        vm.prank(OPERATOR);
        desk.setOperator(PROJECT);
        assertEq(desk.operator(), PROJECT);
    }
}
