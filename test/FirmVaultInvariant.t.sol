// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "./vendor/forge-std/src/Test.sol";
import {FirmBase} from "./FirmBase.t.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LpDesk} from "../src/LpDesk.sol";
import {Burner} from "../src/Burner.sol";
import {FirmVault} from "../src/FirmVault.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Drives FirmVault, Burner and LpDesk's IMD credit in random order with bounded inputs.
contract VaultHandler is Test {
    address constant OPERATOR = 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981;
    address constant PROJECT = 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    FirmVault vault;
    LpDesk desk;
    Burner burner;
    LaunchToken token;
    MockERC20 imd;
    address imdAddr;

    uint256 public ghostImdPaid;
    uint256 public ghostBucketIn;
    uint256 public ghostBought;
    uint256 public ghostNotstockPaid;
    uint256 public ghostDeskCredited;
    uint256 public calls;

    constructor(FirmVault v, LpDesk d, LaunchToken t, MockERC20 i) {
        vault = v;
        desk = d;
        burner = Burner(d.burner());
        token = t;
        imd = i;
        imdAddr = address(i);
    }

    function payImd(uint256 amount) external {
        amount = bound(amount, 0, 1e30);
        imd.mint(address(vault), amount);
        ghostImdPaid += amount;
        calls++;
    }

    function distributeImd(uint256 actorSeed) external {
        address actor = address(uint160(bound(actorSeed, 1, type(uint160).max)));
        uint256 total = vault.undistributed(imdAddr);
        uint256 bucket0 = vault.buybackBucket();
        uint256 proj0 = imd.balanceOf(PROJECT);
        uint256 desk0 = imd.balanceOf(address(desk));
        uint256 top0 = desk.topUpBasket(imdAddr);
        vm.prank(actor);
        vault.distribute(imdAddr);
        uint256 q = total / 4;
        // Exactly 25/25 to bucket and project wallet; the rest (25+25, dust included) to LpDesk.
        assertEq(vault.buybackBucket() - bucket0, q, "bucket quarter");
        assertEq(imd.balanceOf(PROJECT) - proj0, q, "project quarter");
        assertEq(imd.balanceOf(address(desk)) - desk0, total - 2 * q, "desk half");
        assertEq(desk.topUpBasket(imdAddr) - top0, (total - 2 * q) / 2, "top-up half of desk share");
        assertEq(vault.undistributed(imdAddr), 0, "nothing left undistributed");
        ghostBucketIn += q;
        ghostDeskCredited += total - 2 * q;
        calls++;
    }

    function payNotstock(uint256 amount) external {
        amount = bound(amount, 0, token.balanceOf(OPERATOR));
        vm.prank(OPERATOR);
        token.transfer(address(vault), amount);
        ghostNotstockPaid += amount;
        calls++;
    }

    function distributeNotstock() external {
        uint256 bal = token.balanceOf(address(vault));
        uint256 b0 = token.balanceOf(address(burner));
        vault.distribute(address(token));
        assertEq(token.balanceOf(address(burner)) - b0, bal, "all NOTSTOCK to Burner");
        assertEq(token.balanceOf(address(vault)), 0);
        calls++;
    }

    function burn() external {
        uint256 bal = token.balanceOf(address(burner));
        if (bal == 0) {
            vm.expectRevert(Burner.NothingToBurn.selector);
            burner.burn();
            return;
        }
        uint256 d0 = token.balanceOf(DEAD);
        burner.burn();
        assertEq(token.balanceOf(DEAD) - d0, bal);
        calls++;
    }

    function buyback(uint256 amount, bool asStranger) external {
        uint256 bucket = vault.buybackBucket();
        if (asStranger) {
            vm.prank(PROJECT);
            vm.expectRevert(FirmVault.NotOperator.selector);
            vault.buyback(bound(amount, 0, bucket), 0);
            return;
        }
        if (bucket == 0 || amount % 5 == 0) {
            vm.prank(OPERATOR);
            vm.expectRevert(FirmVault.AboveBucket.selector);
            vault.buyback(bucket + 1 + bound(amount, 0, 1e30), 0);
            return;
        }
        amount = bound(amount, 1, bucket);
        uint256 d0 = token.balanceOf(DEAD);
        vm.prank(OPERATOR);
        try vault.buyback(amount, 0) {
            ghostBought += amount;
            assertEq(vault.buybackBucket(), bucket - amount, "bucket down by exactly amount");
            assertGe(token.balanceOf(DEAD), d0);
        } catch {
            // A buyback the mock pool cannot fill leaves the bucket untouched.
            assertEq(vault.buybackBucket(), bucket);
        }
        calls++;
    }

    function strangerCredits(uint256 amount, address who) external {
        vm.assume(who != address(desk) && who != address(vault));
        vm.prank(who);
        vm.expectRevert(FirmVault.NotLpDesk.selector);
        vault.creditFromLpDesk(amount);
        vm.prank(who);
        vm.expectRevert(LpDesk.NotFirmVault.selector);
        desk.creditFromFirmVault(amount);
    }
}

/// @notice Invariants of FirmVault's buckets, the IMD and NOTSTOCK conservation through distribute(),
/// Burner and buyback, over random call sequences.
contract FirmVaultInvariantTest is FirmBase {
    VaultHandler handler;
    uint256 pmImd0;
    uint256 pmNot0;
    uint256 supply0;

    function setUp() public override {
        super.setUp();
        _registerAndSplit();
        // The mock pool pays NOTSTOCK out of the PoolManager's balance.
        vm.prank(address(factory));
        token.transfer(address(poolManager), 50_000_000e18);
        pmImd0 = imd.balanceOf(address(poolManager));
        pmNot0 = token.balanceOf(address(poolManager));
        supply0 = token.totalSupply();
        handler = new VaultHandler(vault, desk, token, imd);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_bucketIsBackedByBalance() public view {
        assertGe(imd.balanceOf(address(vault)), vault.buybackBucket());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_bucketMovesOnlyBySharesAndBuybacks() public view {
        assertEq(vault.buybackBucket(), handler.ghostBucketIn() - handler.ghostBought());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_imdConserved() public view {
        uint256 held = imd.balanceOf(address(vault)) + imd.balanceOf(address(desk)) + imd.balanceOf(PROJECT)
            + (imd.balanceOf(address(poolManager)) - pmImd0) + imd.balanceOf(address(v4));
        assertEq(held, handler.ghostImdPaid(), "IMD only at section 5 destinations or the pool");
        assertEq(imd.balanceOf(address(v4)), 0, "swap module holds nothing");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_deskImdBookkeeping() public view {
        assertEq(imd.balanceOf(address(desk)), handler.ghostDeskCredited());
        assertEq(desk.buybackBasket(IMD_ADDR), 0, "IMD buyback share never sits in LpDesk");
        assertEq(desk.topUpBasket(IMD_ADDR) + desk.freeBalance(IMD_ADDR), imd.balanceOf(address(desk)));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_notstockSupplyAndSplitFixed() public view {
        assertEq(token.totalSupply(), supply0);
        assertTrue(splitter.hasSplit());
        assertEq(token.balanceOf(address(splitter)), 0);
        assertEq(token.balanceOf(address(desk)), 500_000_000e18, "vault flows never touch LpDesk NOTSTOCK");
    }
}

/// @notice Failure paths and edges of Burner, GenesisSplitter, FirmVault and LpDesk's operator powers.
contract FirmEdgesTest is FirmBase {
    function test_burnerKeepsOtherTokensAndRefusesZero() public {
        _registerAndSplit();
        vm.expectRevert(Burner.NothingToBurn.selector);
        burner.burn();
        imd.mint(address(burner), 5e18);
        vm.expectRevert(Burner.NothingToBurn.selector);
        burner.burn();
        assertEq(imd.balanceOf(address(burner)), 5e18, "other tokens stay in Burner");
        vm.prank(OPERATOR);
        token.transfer(address(burner), 1);
        burner.burn();
        assertEq(token.balanceOf(address(burner)), 0);
        assertEq(token.balanceOf(DEAD), 1);
    }

    function test_splitterRefusesBeforeRegistrationAndTwice() public {
        vm.prank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18);
        vm.expectRevert(GenesisSplitter.NotRegistered.selector);
        splitter.split();
        vm.prank(PROJECT);
        factory.setRequester(LAUNCH, address(vault));
        guard.registerNotStock(LAUNCH);
        splitter.split();
        assertEq(token.balanceOf(address(desk)), 500_000_000e18);
        assertEq(token.balanceOf(OPERATOR), 100_000_000e18);
        // Tokens sent after the split stay; a second split reverts.
        vm.prank(address(factory));
        token.transfer(address(splitter), 6e18);
        vm.expectRevert(GenesisSplitter.AlreadySplit.selector);
        splitter.split();
        assertEq(token.balanceOf(address(splitter)), 6e18);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_splitterRatio(uint256 extra) public {
        extra = bound(extra, 0, 400_000_000e18);
        vm.startPrank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18);
        factory.setRequester(LAUNCH, address(vault));
        vm.stopPrank();
        vm.prank(address(factory));
        token.transfer(address(splitter), extra > 100_000_000e18 ? 100_000_000e18 : extra);
        uint256 bal = token.balanceOf(address(splitter));
        guard.registerNotStock(LAUNCH);
        splitter.split();
        assertEq(token.balanceOf(address(desk)), bal * 50 / 60);
        assertEq(token.balanceOf(OPERATOR), bal - bal * 50 / 60);
        assertEq(token.balanceOf(address(splitter)), 0);
    }

    function test_vaultRejectsOtherTokensAndStrangers() public {
        _registerAndSplit();
        MockERC20 other = new MockERC20("X", "X", 18);
        other.mint(address(vault), 1e18);
        vm.expectRevert(FirmVault.UnsupportedToken.selector);
        vault.distribute(address(other));
        vm.expectRevert(FirmVault.NotLpDesk.selector);
        vault.creditFromLpDesk(1);
        vm.expectRevert(LpDesk.NotFirmVault.selector);
        desk.creditFromFirmVault(1);
        // A zero distribute moves nothing and does not revert.
        vault.distribute(IMD_ADDR);
        assertEq(vault.buybackBucket(), 0);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_distributeImdExactQuarters(uint256 a, uint256 b) public {
        _registerAndSplit();
        a = bound(a, 0, 1e30);
        b = bound(b, 0, 1e30);
        imd.mint(address(vault), a);
        imd.mint(address(vault), b);
        vault.distribute(IMD_ADDR);
        uint256 t = a + b;
        assertEq(vault.buybackBucket(), t / 4);
        assertEq(imd.balanceOf(PROJECT), t / 4);
        assertEq(imd.balanceOf(address(desk)), t - 2 * (t / 4));
        assertEq(imd.balanceOf(address(vault)), t / 4, "only the bucket stays");
        // A repeat with no new transfer moves nothing.
        vault.distribute(IMD_ADDR);
        assertEq(imd.balanceOf(PROJECT), t / 4);
        assertEq(vault.buybackBucket(), t / 4);
    }

    function test_deskBurnEdges() public {
        _registerAndSplit();
        vm.prank(PROJECT);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.burn(1);
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.AboveFree.selector);
        desk.burn(500_000_000e18 + 1);
        vm.prank(OPERATOR);
        desk.burn(0);
        vm.prank(OPERATOR);
        desk.burn(500_000_000e18);
        assertEq(token.balanceOf(DEAD), 500_000_000e18);
        assertEq(token.balanceOf(address(desk)), 0);
    }

    function test_operatorHandoverEdges() public {
        vm.prank(PROJECT);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.setOperator(PROJECT);
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.ZeroAddress.selector);
        desk.setOperator(address(0));
        vm.prank(OPERATOR);
        desk.setOperator(address(0xB0B));
        // The old operator lost every power, including FirmVault's buyback.
        _registerAndSplit();
        imd.mint(address(vault), 8e18);
        vault.distribute(IMD_ADDR);
        vm.prank(OPERATOR);
        vm.expectRevert(FirmVault.NotOperator.selector);
        vault.buyback(1, 0);
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.burn(1);
    }

    function test_deployModuleWrongCodeOrUnknownKind() public {
        vm.expectRevert(LpDesk.WrongModuleCode.selector);
        desk.deployModule("PriceGuard", hex"00");
        vm.expectRevert(LpDesk.UnknownModule.selector);
        desk.deployModule("Nope", hex"00");
    }
}
