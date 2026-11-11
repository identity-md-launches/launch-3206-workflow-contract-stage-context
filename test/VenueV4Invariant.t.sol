// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "./vendor/forge-std/src/Test.sol";
import {FirmBase} from "./FirmBase.t.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LpDesk} from "../src/LpDesk.sol";
import {VenueV4} from "../src/modules/VenueV4.sol";
import {FirmMath} from "../src/libraries/FirmMath.sol";
import {OpenParams, Position, KIND_V4} from "../src/interfaces/IFirm.sol";
import {PoolKey} from "../src/interfaces/IVenues.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV4PoolManager} from "./mocks/MockV4.sol";
import {MockV4Posm, MockPermit2} from "./mocks/MockV4Posm.sol";

/// @dev Drives LpDesk's v4 position actions as the operator, in random order with bounded inputs.
contract V4Handler is Test {
    address constant OPERATOR = 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981;
    address constant POSM = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    uint160 constant ONE = 79228162514264337593543950336;

    LpDesk desk;
    LaunchToken token;
    VenueV4 v4;
    MockV4PoolManager pm;
    MockV4Posm posm;
    address notSource;

    uint256 public injectedNot;
    uint256 public mintedWeth;
    uint256 public opens;
    uint256 public closes;
    uint256 public moves;

    constructor(LpDesk d, LaunchToken t, VenueV4 v, MockV4PoolManager p, address src) {
        desk = d;
        token = t;
        v4 = v;
        pm = p;
        posm = MockV4Posm(POSM);
        notSource = src;
    }

    function _notIs0() internal view returns (bool) {
        return address(token) < WETH;
    }

    function _key() internal view returns (PoolKey memory) {
        (address c0, address c1) = FirmMath.sort(address(token), WETH);
        return PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: address(0)});
    }

    function _range(uint256 seed) internal view returns (int24 lower, int24 upper) {
        uint256 k = seed % 3;
        if (k == 0) return (-600, 600);
        if (k == 1) return (-1200, 1200);
        return _notIs0() ? (int24(120), int24(3000)) : (int24(-3000), int24(-120));
    }

    function _openIds() internal view returns (uint256[] memory ids, uint256 n) {
        uint256 c = desk.positionCount();
        ids = new uint256[](c);
        for (uint256 i; i < c; ++i) {
            if (desk.position(i).open) ids[n++] = i;
        }
    }

    function _pick(uint256 seed) internal view returns (bool ok, uint256 id) {
        (uint256[] memory ids, uint256 n) = _openIds();
        if (n == 0) return (false, 0);
        return (true, ids[seed % n]);
    }

    function open(uint256 amount, uint256 rangeSeed) external {
        if (desk.positionCount() >= 12) return;
        amount = bound(amount, 1e15, 5_000_000e18);
        (int24 lower, int24 upper) = _range(rangeSeed);
        uint160 at = posm.priceOf(_key());
        if (at == 0) at = ONE;
        Position memory pos = Position(POSM, KIND_V4, WETH, 3000, 60, lower, upper, 0, true);
        (uint256 n, uint256 a, uint128 l) = v4.quote(pos, at, amount, false);
        if (n == 0 || l == 0) return;
        if (a > desk.freeBalance(WETH)) {
            uint256 need = a - desk.freeBalance(WETH);
            MockERC20(WETH).mint(address(desk), need);
            mintedWeth += need;
        }
        (uint256 q0, uint256 q1) = _notIs0() ? (n, a) : (a, n);
        OpenParams memory p =
            OpenParams(WETH, POSM, 3000, 60, lower, upper, at, amount, q0 * 9950 / 10_000, q1 * 9950 / 10_000);
        vm.prank(OPERATOR);
        desk.open(p);
        ++opens;
    }

    function accrue(uint256 seed, uint256 notFee, uint256 wethFee) external {
        (bool ok, uint256 id) = _pick(seed);
        if (!ok) return;
        notFee = bound(notFee, 0, 1_000e18);
        wethFee = bound(wethFee, 0, 1_000e18);
        MockERC20(WETH).mint(POSM, wethFee);
        mintedWeth += wethFee;
        vm.prank(notSource);
        token.transfer(POSM, notFee);
        injectedNot += notFee;
        (uint128 f0, uint128 f1) = _notIs0() ? (uint128(notFee), uint128(wethFee)) : (uint128(wethFee), uint128(notFee));
        posm.accrueFees(desk.position(id).tokenId, f0, f1);
    }

    function collect(uint256 seed) external {
        (bool ok, uint256 id) = _pick(seed);
        if (!ok) return;
        vm.prank(OPERATOR);
        desk.collect(id);
    }

    function close(uint256 seed) external {
        (bool ok, uint256 id) = _pick(seed);
        if (!ok) return;
        vm.prank(OPERATOR);
        desk.close(id, 0, 0);
        ++closes;
    }

    function move(uint256 fromSeed, uint256 toSeed, uint256 frac) external {
        (bool ok, uint256 from) = _pick(fromSeed);
        (bool ok2, uint256 to) = _pick(toSeed);
        if (!ok || !ok2 || from == to) return;
        uint128 l = posm.getPositionLiquidity(desk.position(from).tokenId);
        uint128 amount = uint128(bound(frac, 0, l));
        if (amount == 0) return;
        vm.prank(OPERATOR);
        try desk.moveLiquidity(from, to, amount, 0, 0, 0, 0) {
            ++moves;
        } catch (bytes memory err) {
            // The only expected refusal: the target range takes nothing of what was withdrawn.
            require(bytes4(err) == LpDesk.NothingTaken.selector, "unexpected moveLiquidity revert");
        }
    }

    function movePrice(uint256 factor) external {
        if (posm.priceOf(_key()) == 0) return;
        factor = bound(factor, 9_980_000, 10_020_000);
        uint160 price = uint160(uint256(ONE) * factor / 1e7);
        pm.initialize(_key(), price);
        // In a real pool the price moves by swaps, which pay the counter-asset in. Model that by topping
        // the manager up to what its positions are worth at the new price (tracked as injected).
        (uint256 need0, uint256 need1) = _owedByManager(price);
        (address c0, address c1) = (_key().currency0, _key().currency1);
        _topUp(c0, need0);
        _topUp(c1, need1);
    }

    function _owedByManager(uint160 price) internal view returns (uint256 need0, uint256 need1) {
        uint256 c = desk.positionCount();
        for (uint256 i; i < c; ++i) {
            Position memory p = desk.position(i);
            if (!p.open) continue;
            (uint256 a0, uint256 a1) = FirmMath.getAmountsForLiquidity(
                price,
                FirmMath.getSqrtRatioAtTick(p.tickLower),
                FirmMath.getSqrtRatioAtTick(p.tickUpper),
                posm.getPositionLiquidity(p.tokenId)
            );
            (uint128 f0, uint128 f1) = posm.feesOf(p.tokenId);
            need0 += a0 + f0;
            need1 += a1 + f1;
        }
    }

    function _topUp(address c, uint256 need) internal {
        uint256 bal = MockERC20(c).balanceOf(POSM);
        if (bal >= need) return;
        uint256 d = need - bal;
        if (c == WETH) {
            MockERC20(WETH).mint(POSM, d);
            mintedWeth += d;
        } else {
            vm.prank(notSource);
            token.transfer(POSM, d);
            injectedNot += d;
        }
    }
}

/// @notice Invariants of LpDesk's v4 positions over random open / accrue / collect / close / move / price
/// sequences: tokens are conserved between LpDesk, the manager, the Burner and the project wallet;
/// VenueV4 never keeps a balance; the baskets are always backed; every open position's NFT is LpDesk's
/// and every closed one is burned.
contract VenueV4InvariantTest is FirmBase {
    address constant WETH = 0x4200000000000000000000000000000000000006;

    V4Handler handler;
    uint256 startNot;

    function setUp() public override {
        super.setUp();
        _registerAndSplit();
        vm.etch(WETH, address(new MockERC20("WETH", "WETH", 18)).code);
        MockPermit2 permit2 = new MockPermit2();
        vm.etch(UNI_V4_POSM, address(new MockV4Posm(address(poolManager), address(permit2))).code);
        handler = new V4Handler(desk, token, v4, poolManager, address(factory));
        startNot = token.balanceOf(address(desk)) + token.balanceOf(UNI_V4_POSM) + token.balanceOf(address(burner));
        bytes4[] memory sel = new bytes4[](6);
        sel[0] = V4Handler.open.selector;
        sel[1] = V4Handler.accrue.selector;
        sel[2] = V4Handler.collect.selector;
        sel[3] = V4Handler.close.selector;
        sel[4] = V4Handler.move.selector;
        sel[5] = V4Handler.movePrice.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_notstockConserved() public view {
        uint256 held = token.balanceOf(address(desk)) + token.balanceOf(UNI_V4_POSM) + token.balanceOf(address(burner));
        assertEq(held, startNot + handler.injectedNot());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_assetConserved() public view {
        MockERC20 weth = MockERC20(WETH);
        uint256 held = weth.balanceOf(address(desk)) + weth.balanceOf(UNI_V4_POSM) + weth.balanceOf(PROJECT);
        assertEq(held, handler.mintedWeth());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_moduleKeepsNothingAndBasketsBacked() public view {
        MockERC20 weth = MockERC20(WETH);
        assertEq(token.balanceOf(address(v4)), 0);
        assertEq(weth.balanceOf(address(v4)), 0);
        assertGe(weth.balanceOf(address(desk)), desk.topUpBasket(WETH) + desk.buybackBasket(WETH));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_positionOwnership() public view {
        MockV4Posm posm = MockV4Posm(UNI_V4_POSM);
        uint256 c = desk.positionCount();
        for (uint256 i; i < c; ++i) {
            Position memory p = desk.position(i);
            if (p.open) {
                assertEq(posm.ownerOf(p.tokenId), address(desk));
                assertEq(desk.positionLiquidity(i), posm.getPositionLiquidity(p.tokenId));
            } else {
                assertEq(posm.ownerOf(p.tokenId), address(0));
                assertEq(desk.positionLiquidity(i), 0);
            }
        }
    }
}
