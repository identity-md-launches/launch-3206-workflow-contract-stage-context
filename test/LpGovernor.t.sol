// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FirmBase} from "./FirmBase.t.sol";
import {LpDesk} from "../src/LpDesk.sol";
import {LpGovernor} from "../src/modules/LpGovernor.sol";
import {PriceGuard} from "../src/modules/PriceGuard.sol";
import {FirmMath} from "../src/libraries/FirmMath.sol";
import {OpenParams, Position} from "../src/interfaces/IFirm.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Venue, MockV3Pool} from "./mocks/MockV3Venue.sol";
import {MockOFT} from "./mocks/MockOFT.sol";

/// @notice LpGovernor: staking checkpoints, proposal gates, vote, veto, execute, expiry and bridges.
contract LpGovernorTest is FirmBase {
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant UNI_V3 = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address constant BASESWAP = 0xDe151D5c92BfAA288Db4B67c21CD55d5826bCc93;
    uint160 constant ONE = 79228162514264337593543950336;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);

    function setUp() public override {
        super.setUp();
        _registerAndSplit();
        vm.etch(WETH, address(new MockERC20("WETH", "WETH", 18)).code);
        vm.etch(UNI_V3, address(new MockV3Venue(false, false)).code);
        vm.startPrank(address(0x5AAA)); // the swarm's share funds the stakers
        token.transfer(alice, 10_000_000e18);
        token.transfer(bob, 10_000_000e18);
        token.transfer(carol, 1_000e18);
        vm.stopPrank();
        _stake(alice, 10_000_000e18);
        _stake(bob, 10_000_000e18);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _stake(address who, uint256 amount) internal {
        vm.startPrank(who);
        token.approve(address(gov), amount);
        gov.stake(amount);
        vm.stopPrank();
    }

    function _pass(uint256 id) internal {
        vm.prank(alice);
        gov.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        assertEq(uint256(gov.state(id)), uint256(LpGovernor.State.VetoWindow));
        vm.warp(vm.getBlockTimestamp() + 2 days);
        assertEq(uint256(gov.state(id)), uint256(LpGovernor.State.Executable));
    }

    // ------------------------------------------------------------ staking

    function test_stakeUnstakeAndCheckpoints() public {
        assertEq(gov.staked(alice), 10_000_000e18);
        assertEq(gov.totalStaked(), 20_000_000e18);
        uint256 b = vm.getBlockNumber();
        vm.prank(alice);
        gov.unstake(4_000_000e18);
        assertEq(token.balanceOf(alice), 4_000_000e18);
        assertEq(gov.stakedAt(alice, b - 1), 10_000_000e18, "checkpoint before the unstake");
        assertEq(gov.stakedAt(alice, b), 6_000_000e18);
        assertEq(gov.totalStakedAt(b - 1), 20_000_000e18);
        vm.prank(alice);
        vm.expectRevert(LpGovernor.AboveStaked.selector);
        gov.unstake(6_000_000e18 + 1);
        assertEq(token.balanceOf(address(gov)), 16_000_000e18, "LpGovernor holds the stake");
    }

    function test_laterUnstakeCannotChangeAVote() public {
        uint256 id = _proposeAddAsset(alice, address(0x1111));
        vm.prank(alice);
        gov.unstake(10_000_000e18);
        vm.prank(alice);
        gov.vote(id, true);
        assertEq(gov.proposal(id).forWeight, 10_000_000e18, "checkpointed weight");
        vm.prank(alice);
        vm.expectRevert(LpGovernor.AlreadyVoted.selector);
        gov.vote(id, false);
        // A staker with no checkpointed weight cannot vote.
        _stake(carol, 1_000e18);
        vm.prank(carol);
        vm.expectRevert(LpGovernor.NoWeight.selector);
        gov.vote(id, true);
    }

    // ------------------------------------------------------------ gates

    function _proposeAddAsset(address who, address asset) internal returns (uint256 id) {
        vm.prank(who);
        id = gov.proposeAddAsset(asset);
    }

    function test_thresholdAndOperatorException() public {
        _stake(carol, 1_000e18); // 0.005% of staked
        vm.prank(carol);
        vm.expectRevert(LpGovernor.BelowThreshold.selector);
        gov.proposeAddAsset(address(0x1111));
        vm.prank(OPERATOR); // zero staked, still allowed
        gov.proposeAddAsset(address(0x1111));
        vm.prank(address(0xDEAD1));
        vm.expectRevert(LpGovernor.BelowThreshold.selector);
        gov.proposeAddAsset(address(0x1111));
    }

    function test_oneOpenProposalPerKindPerClass() public {
        uint256 id = _proposeAddAsset(alice, address(0x1111));
        vm.prank(bob);
        vm.expectRevert(LpGovernor.KindOpen.selector);
        gov.proposeAddAsset(address(0x2222));
        vm.etch(BASESWAP, address(new MockV3Venue(false, false)).code);
        vm.prank(bob);
        gov.proposeAddVenue(BASESWAP, 1); // another kind is not blocked
        vm.prank(OPERATOR);
        uint256 opId = gov.proposeAddAsset(address(0x3333)); // operator not blocked
        vm.prank(OPERATOR);
        vm.expectRevert(LpGovernor.KindOpen.selector);
        gov.proposeAddAsset(address(0x4444));
        // Failed proposals stop blocking as soon as the vote ends.
        vm.warp(vm.getBlockTimestamp() + 3 days);
        assertEq(uint256(gov.state(id)), uint256(LpGovernor.State.Failed));
        assertEq(uint256(gov.state(opId)), uint256(LpGovernor.State.Failed));
        _proposeAddAsset(bob, address(0x2222));
    }

    function test_quorumAndMajority() public {
        _stake(carol, 1_000e18);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 id = _proposeAddAsset(alice, address(0x1111));
        vm.prank(carol);
        gov.vote(id, true); // 1,000 of 20,001,000 staked: below the 3% quorum
        vm.warp(vm.getBlockTimestamp() + 3 days);
        assertEq(uint256(gov.state(id)), uint256(LpGovernor.State.Failed));
        vm.expectRevert(LpGovernor.NotExecutable.selector);
        gov.execute(id);
        uint256 id2 = _proposeAddAsset(alice, address(0x1111));
        vm.prank(alice);
        gov.vote(id2, true);
        vm.prank(bob);
        gov.vote(id2, false); // tie: for must exceed against
        vm.warp(vm.getBlockTimestamp() + 3 days);
        assertEq(uint256(gov.state(id2)), uint256(LpGovernor.State.Failed));
    }

    function test_vetoOnlyInWindowByOperator() public {
        uint256 id = _proposeAddAsset(alice, address(0x1111));
        vm.prank(OPERATOR);
        vm.expectRevert(LpGovernor.NotVetoWindow.selector);
        gov.veto(id);
        vm.prank(alice);
        gov.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.prank(alice);
        vm.expectRevert(LpGovernor.NotOperator.selector);
        gov.veto(id);
        vm.prank(OPERATOR);
        gov.veto(id);
        assertEq(uint256(gov.state(id)), uint256(LpGovernor.State.Vetoed));
        vm.expectRevert(LpGovernor.NotExecutable.selector);
        gov.execute(id);
        // A vetoed proposal does not block a new one of its kind; the veto window is over for a passed one.
        uint256 id2 = _proposeAddAsset(alice, address(0x1111));
        _pass(id2);
        vm.prank(OPERATOR);
        vm.expectRevert(LpGovernor.NotVetoWindow.selector);
        gov.veto(id2);
    }

    function test_executeOnceAndExpiry() public {
        uint256 id = _proposeAddAsset(alice, address(0x1111));
        _pass(id);
        gov.execute(id);
        assertTrue(guard.isAsset(address(0x1111)));
        vm.expectRevert(LpGovernor.NotExecutable.selector);
        gov.execute(id);
        uint256 id2 = _proposeAddAsset(alice, address(0x2222));
        _pass(id2);
        vm.warp(vm.getBlockTimestamp() + 259_200);
        assertEq(uint256(gov.state(id2)), uint256(LpGovernor.State.Expired));
        vm.expectRevert(LpGovernor.NotExecutable.selector);
        gov.execute(id2);
        _proposeAddAsset(alice, address(0x2222)); // expired does not block
    }

    function test_addAssetGate() public {
        vm.prank(alice);
        vm.expectRevert(PriceGuard.ZeroAddress.selector);
        gov.proposeAddAsset(address(0));
        vm.prank(alice);
        vm.expectRevert(PriceGuard.NotstockNotAsset.selector);
        gov.proposeAddAsset(address(token));
        vm.prank(alice);
        vm.expectRevert(PriceGuard.AlreadyListed.selector);
        gov.proposeAddAsset(WETH);
        // Listed between creation and execute: execute reverts too.
        uint256 id = _proposeAddAsset(alice, address(0x1111));
        vm.prank(OPERATOR);
        uint256 id2 = gov.proposeAddAsset(address(0x1111));
        vm.prank(bob);
        gov.vote(id2, true);
        _pass(id);
        gov.execute(id);
        vm.expectRevert(PriceGuard.AlreadyListed.selector);
        gov.execute(id2);
        vm.prank(alice);
        vm.expectRevert(LpDesk.NotGovernor.selector);
        desk.addAsset(address(0x5555));
    }

    function test_addVenueGateAndExecution() public {
        vm.prank(alice);
        vm.expectRevert(PriceGuard.ZeroAddress.selector);
        gov.proposeAddVenue(address(0), 1);
        vm.prank(alice);
        vm.expectRevert(PriceGuard.AlreadyListed.selector);
        gov.proposeAddVenue(UNI_V3, 1);
        vm.prank(alice);
        vm.expectRevert(PriceGuard.NoCode.selector);
        gov.proposeAddVenue(address(0x9999), 1);
        vm.prank(alice);
        vm.expectRevert(PriceGuard.BadVenue.selector);
        gov.proposeAddVenue(address(token), 1); // factory() reverts
        vm.prank(alice);
        vm.expectRevert(PriceGuard.BadVenue.selector);
        gov.proposeAddVenue(address(token), 0); // poolManager() reverts
        vm.etch(BASESWAP, address(new MockV3Venue(false, false)).code);
        vm.prank(alice);
        vm.expectRevert(PriceGuard.BadKind.selector);
        gov.proposeAddVenue(BASESWAP, 7);
        vm.prank(alice);
        uint256 id = gov.proposeAddVenue(BASESWAP, 1);
        _pass(id);
        gov.execute(id);
        assertEq(guard.venues().length, 7);
        (bool listed, uint8 kind) = guard.venueKind(BASESWAP);
        assertTrue(listed);
        assertEq(kind, 1);
        // Opens on it after the bootstrap only through a proposal; here the bootstrap window still runs.
        OpenParams memory op = _openParams(BASESWAP, 1_000e18, ONE);
        vm.prank(OPERATOR);
        desk.open(op);
        assertEq(desk.positionCount(), 1);
    }

    function _openParams(address venue, uint256 amount, uint160 price) internal view returns (OpenParams memory p) {
        bool notIs0 = address(token) < WETH;
        (int24 lower, int24 upper) = notIs0 ? (int24(60), int24(6000)) : (int24(-6000), int24(-60));
        p = OpenParams(WETH, venue, 3000, 0, lower, upper, price, amount, 0, 0);
        (uint256 n, uint256 a,) =
            v3.quote(Position(venue, 1, WETH, 3000, 60, lower, upper, 0, true), price, amount, false);
        (p.amount0Min, p.amount1Min) = notIs0 ? (n * 995 / 1000, a * 995 / 1000) : (a * 995 / 1000, n * 995 / 1000);
    }

    function test_openPositionProposalAfterBootstrap() public {
        vm.warp(desk.bootstrapEnd());
        OpenParams memory p = _openParams(UNI_V3, 1_000e18, ONE);
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.BootstrapOver.selector);
        desk.open(p);
        vm.prank(alice);
        vm.expectRevert(LpDesk.NotGovernor.selector);
        desk.openFromGovernor(p);
        p.amount = 600_000_000e18;
        vm.prank(alice);
        vm.expectRevert(LpGovernor.AboveFree.selector);
        gov.proposeOpenPosition(p);
        p.amount = 1_000e18;
        vm.prank(alice);
        uint256 id = gov.proposeOpenPosition(p);
        _pass(id);
        // The pool moved more than 0.5% from the proposal's price: execute reverts, the proposal expires.
        (address t0, address t1) = FirmMath.sort(address(token), WETH);
        MockV3Venue(UNI_V3).createPoolAt(t0, t1, 3000, ONE * 1006 / 1000);
        vm.expectRevert(LpDesk.PriceMoved.selector);
        gov.execute(id);
        vm.warp(vm.getBlockTimestamp() + 259_200);
        vm.expectRevert(LpGovernor.NotExecutable.selector);
        gov.execute(id);
        // A new proposal at the pool's price executes once.
        p.sqrtPriceX96 = ONE * 1006 / 1000;
        vm.prank(alice);
        uint256 id2 = gov.proposeOpenPosition(p);
        _pass(id2);
        gov.execute(id2);
        assertEq(desk.positionCount(), 1);
        assertTrue(desk.position(0).open);
        vm.expectRevert(LpGovernor.NotExecutable.selector);
        gov.execute(id2);
    }

    // ------------------------------------------------------------ bridges

    function test_bridgeRecordsAndBridgeOut() public {
        MockOFT wrong = new MockOFT(WETH);
        vm.prank(alice);
        vm.expectRevert(LpGovernor.WrongAdapter.selector);
        gov.proposeAddBridge(address(wrong), 30101, address(0xDE5C));
        MockOFT adapter = new MockOFT(address(token));
        vm.prank(alice);
        uint256 id = gov.proposeAddBridge(address(adapter), 30101, address(0xDE5C));
        _pass(id);
        gov.execute(id);
        assertEq(gov.bridgeCount(), 1);
        LpGovernor.Bridge[] memory bs = gov.bridges();
        assertEq(bs[0].adapter, address(adapter));
        assertEq(bs[0].dstChainId, 30101);
        vm.prank(alice);
        vm.expectRevert(LpGovernor.UnknownBridge.selector);
        gov.proposeBridgeOut(1, 1e18);
        vm.prank(alice);
        vm.expectRevert(LpGovernor.AboveFree.selector);
        gov.proposeBridgeOut(0, 600_000_000e18);
        vm.prank(alice);
        vm.expectRevert(LpDesk.NotGovernor.selector);
        desk.bridgeOut(address(adapter), 30101, alice, 1e18, alice);
        vm.prank(alice);
        uint256 out = gov.proposeBridgeOut(0, 5e18);
        vm.expectRevert(LpGovernor.NotExecutable.selector);
        gov.execute(out);
        _pass(out);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        gov.execute{value: 0.01 ether}(out);
        assertEq(adapter.lastAmount(), 5e18);
        assertEq(adapter.lastTo(), bytes32(uint256(uint160(address(0xDE5C)))));
        assertEq(adapter.lastDstEid(), 30101);
        assertEq(adapter.lastRefund(), bob);
        assertEq(adapter.lastFee(), 0.01 ether);
        assertEq(token.allowance(address(desk), address(adapter)), 0, "approval reset");
        assertEq(token.balanceOf(address(desk)), 500_000_000e18 - 5e18);
        assertEq(gov.bridgedOut(0), 5e18);
    }
}
