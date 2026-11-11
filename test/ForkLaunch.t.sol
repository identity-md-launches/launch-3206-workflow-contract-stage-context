// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "./vendor/forge-std/src/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LpDesk} from "../src/LpDesk.sol";
import {Burner} from "../src/Burner.sol";
import {FirmVault} from "../src/FirmVault.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {PriceGuard} from "../src/modules/PriceGuard.sol";
import {LpGovernor} from "../src/modules/LpGovernor.sol";
import {VenueV3} from "../src/modules/VenueV3.sol";
import {VenueV4} from "../src/modules/VenueV4.sol";
import {MODULE_LPGOVERNOR, MODULE_PRICEGUARD, MODULE_VENUEV3, MODULE_VENUEV4} from "../src/interfaces/IFirm.sol";
import {PoolKey} from "../src/interfaces/IVenues.sol";
import {FirmMath} from "../src/libraries/FirmMath.sol";
import {OpenParams, Position, IVenueModule, KIND_V4} from "../src/interfaces/IFirm.sol";

/// @dev The live ProjectFactory's launch() surface on Base (verified source, ProjectFactory.ProjectParams).
interface ILiveFactory {
    struct Record {
        bytes32 kind;
        uint64 launchNumber;
        uint64 recordedAt;
        bytes32 sourceCommit;
        bytes32 manifestHash;
        bytes32 attestationHash;
        bytes32 verifierKey;
        string sourceRepoUrl;
    }

    struct ProjectParams {
        uint64 launchNumber;
        bytes32 kind;
        bytes tokenCreationCode;
        bytes32 tokenName;
        bytes[] contractCreationCodes;
        bytes32[] contractNames;
        address[] expectedContracts;
        uint256 totalSupply;
        uint16 poolBps;
        address remainderTo;
        bytes32 merkleRoot;
        uint64 contributorLockSeconds;
        uint64 sweepDelaySeconds;
        address pairedCurrency;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        Record record;
        uint256[] agentIds;
        address requester;
    }

    function launch(ProjectParams calldata p)
        external
        returns (address token, address[] memory contracts, address distributor);
    function deployer() external view returns (address);
    function poolHook() external view returns (address);
    function predictToken(uint64 launchNumber, bytes calldata code) external view returns (address);
    function predictContract(uint64 launchNumber, uint256 index, bytes calldata code) external view returns (address);
    function positionOf(uint64 launchNumber)
        external
        view
        returns (PoolKey memory key, int24 tickLower, int24 tickUpper, address requester);
    function setRequester(uint64 launchNumber, address next) external;
    function distributorOf(uint64 launchNumber) external view returns (address);
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}

/// @notice SPEC section 6 "Full launch rehearsal" on a Base mainnet fork at the job's pinned block: the
/// one evm_project launch through the live ProjectFactory's launch(), called as its deployer() (the only
/// impersonation of an outside address), then deployModule for every module, the project wallet's
/// 600,000,000 NOTSTOCK transfer and setRequester(launchNumber, FirmVault), registerNotStock and split().
contract ForkLaunchTest is Test {
    uint256 constant FORK_BLOCK = 56_087_797;
    ILiveFactory constant FACTORY = ILiveFactory(0x82EcAA82B8C1A64773D99295B1157EE502539736);
    address constant IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address constant OPERATOR = 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981;
    address constant PROJECT = 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint64 constant LAUNCH_NO = 4_000_000_777;
    int24 constant SPACING = 200;

    bool forked;
    LaunchToken token;
    LpDesk desk;
    FirmVault vault;
    GenesisSplitter splitter;
    Burner burner;
    PriceGuard guard;
    address distributor;
    uint256 launchGas;
    uint256 projectAfterLaunch;

    function setUp() public {
        string memory url = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url, FORK_BLOCK);
        forked = true;
    }

    // ------------------------------------------------------------------ launch helpers

    function _params() internal view returns (ILiveFactory.ProjectParams memory p) {
        bytes memory tokenCode = type(LaunchToken).creationCode;
        address tokenAddr = FACTORY.predictToken(LAUNCH_NO, tokenCode);
        bytes[] memory codes = new bytes[](3);
        codes[0] = abi.encodePacked(type(LpDesk).creationCode, abi.encode(tokenAddr, OPERATOR, PROJECT));
        address deskAddr = FACTORY.predictContract(LAUNCH_NO, 0, codes[0]);
        codes[1] = abi.encodePacked(type(FirmVault).creationCode, abi.encode(PROJECT, deskAddr));
        codes[2] = abi.encodePacked(type(GenesisSplitter).creationCode, abi.encode(deskAddr, OPERATOR));
        address[] memory expected = new address[](3);
        expected[0] = deskAddr;
        expected[1] = FACTORY.predictContract(LAUNCH_NO, 1, codes[1]);
        expected[2] = FACTORY.predictContract(LAUNCH_NO, 2, codes[2]);
        bytes32[] memory names = new bytes32[](3);
        names[0] = "LpDesk";
        names[1] = "FirmVault";
        names[2] = "GenesisSplitter";

        // Single-sided NOTSTOCK seed: the range sits entirely on NOTSTOCK's side of the opening price.
        bool notstockIs0 = tokenAddr < IMD;
        int24 lower;
        int24 upper;
        uint160 sqrtP;
        if (notstockIs0) {
            lower = -128_600;
            upper = 887_200;
            sqrtP = FirmMath.getSqrtRatioAtTick(lower - SPACING);
        } else {
            lower = -887_200;
            upper = 128_600;
            sqrtP = FirmMath.getSqrtRatioAtTick(upper + SPACING);
        }
        uint160 sa = FirmMath.getSqrtRatioAtTick(lower);
        uint160 sb = FirmMath.getSqrtRatioAtTick(upper);
        uint128 liq = notstockIs0
            ? FirmMath.getLiquidityForAmount0(sa, sb, 299_000_000e18)
            : FirmMath.getLiquidityForAmount1(sa, sb, 299_000_000e18);

        p.launchNumber = LAUNCH_NO;
        p.kind = "evm_project";
        p.tokenCreationCode = tokenCode;
        p.tokenName = "LaunchToken";
        p.contractCreationCodes = codes;
        p.contractNames = names;
        p.expectedContracts = expected;
        p.totalSupply = SUPPLY;
        p.poolBps = 3000;
        p.remainderTo = PROJECT;
        p.merkleRoot = keccak256("rehearsal swarm root");
        p.contributorLockSeconds = 0;
        p.sweepDelaySeconds = 30 days;
        p.pairedCurrency = IMD;
        p.tickSpacing = SPACING;
        p.sqrtPriceX96 = sqrtP;
        p.tickLower = lower;
        p.tickUpper = upper;
        p.liquidity = liq;
        p.record.kind = "evm_project";
        p.record.launchNumber = LAUNCH_NO;
        p.record.sourceCommit = keccak256("rehearsal");
        p.requester = PROJECT;
    }

    /// @dev Intrinsic gas of a transaction carrying `data` (21,000 + calldata), added to the execution gas.
    function _intrinsic(bytes memory data) internal pure returns (uint256 g) {
        g = 21_000;
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    function _launch() internal {
        ILiveFactory.ProjectParams memory p = _params();
        bytes memory callData = abi.encodeCall(ILiveFactory.launch, (p));
        address dep = FACTORY.deployer();
        vm.prank(dep);
        uint256 g0 = gasleft();
        (bool ok, bytes memory ret) = address(FACTORY).call(callData);
        uint256 used = g0 - gasleft();
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        launchGas = used + _intrinsic(callData);
        (address t, address[] memory cs, address d) = abi.decode(ret, (address, address[], address));
        token = LaunchToken(t);
        desk = LpDesk(cs[0]);
        vault = FirmVault(cs[1]);
        splitter = GenesisSplitter(cs[2]);
        distributor = d;
        burner = Burner(desk.burner());
        projectAfterLaunch = token.balanceOf(PROJECT);
    }

    function _modules() internal {
        guard = PriceGuard(desk.deployModule(MODULE_PRICEGUARD, type(PriceGuard).creationCode));
        desk.deployModule(MODULE_LPGOVERNOR, type(LpGovernor).creationCode);
        desk.deployModule(MODULE_VENUEV3, type(VenueV3).creationCode);
        desk.deployModule(MODULE_VENUEV4, type(VenueV4).creationCode);
    }

    function _postLaunch() internal {
        vm.startPrank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18);
        FACTORY.setRequester(LAUNCH_NO, address(vault));
        vm.stopPrank();
        guard.registerNotStock(LAUNCH_NO);
        splitter.split();
    }

    // ------------------------------------------------------------------ tests

    function test_fork_fullLaunchRehearsal() public {
        if (!forked) vm.skip(true);
        assertEq(block.chainid, 8453);
        _launch();

        // One launch transaction under 16,777,216 gas, the factory as LpDesk's launchFactory.
        assertLt(launchGas, 16_777_216, "launch gas");
        assertEq(desk.launchFactory(), address(FACTORY));
        assertEq(desk.token(), address(token));
        assertEq(desk.operator(), OPERATOR);
        assertEq(desk.projectWallet(), PROJECT);
        assertEq(vault.lpDesk(), address(desk));
        assertEq(vault.projectWallet(), PROJECT);
        assertEq(splitter.lpDesk(), address(desk));
        assertEq(splitter.devWallet(), OPERATOR);
        assertEq(token.totalSupply(), SUPPLY);

        // Supply at launch: 10% swarm, at most 30% in the pool, the rest (seed rounding included) to the
        // project wallet; nothing anywhere else.
        uint256 swarm = token.balanceOf(distributor);
        uint256 pooled = token.balanceOf(POOL_MANAGER);
        assertEq(swarm, 100_000_000e18, "swarm 10%");
        assertLe(pooled, 300_000_000e18, "pool at most 30%");
        assertGt(pooled, 298_000_000e18, "pool seeded");
        assertEq(projectAfterLaunch, SUPPLY - swarm - pooled, "remainder to project wallet");
        assertGe(projectAfterLaunch, 600_000_000e18);
        assertEq(token.balanceOf(address(desk)), 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(address(splitter)), 0);
        assertEq(token.balanceOf(address(FACTORY)), 0);

        // The pool the factory recorded: NOTSTOCK/IMD at 12500 with the factory's hook, requester = payer.
        (PoolKey memory key,,, address requester) = FACTORY.positionOf(LAUNCH_NO);
        assertEq(requester, PROJECT);
        assertEq(key.fee, 12_500);
        assertEq(key.hooks, FACTORY.poolHook());
        assertTrue(key.currency0 == address(token) || key.currency1 == address(token));
        assertTrue(key.currency0 == IMD || key.currency1 == IMD);

        // Modules: anyone deploys each once at the predicted address.
        _modules();
        assertTrue(desk.isModuleDeployed(MODULE_PRICEGUARD));
        assertTrue(desk.isModuleDeployed(MODULE_LPGOVERNOR));
        assertTrue(desk.isModuleDeployed(MODULE_VENUEV3));
        assertTrue(desk.isModuleDeployed(MODULE_VENUEV4));
        vm.expectRevert(LpDesk.ModuleExists.selector);
        desk.deployModule(MODULE_PRICEGUARD, type(PriceGuard).creationCode);

        // registerNotStock before the 600,000,000 transfer and the requester change reverts.
        vm.expectRevert();
        guard.registerNotStock(LAUNCH_NO);

        _postLaunch();
        (,,, requester) = FACTORY.positionOf(LAUNCH_NO);
        assertEq(requester, address(vault), "pool fee recipient is FirmVault");
        assertTrue(desk.registered());
        assertEq(desk.firmVault(), address(vault));
        assertEq(desk.bootstrapEnd(), block.timestamp + 604_800);

        // split(): LpDesk 500,000,000, dev wallet +100,000,000, GenesisSplitter 0.
        assertEq(token.balanceOf(address(desk)), 500_000_000e18);
        assertEq(token.balanceOf(address(splitter)), 0);
        assertEq(token.balanceOf(PROJECT), projectAfterLaunch - 600_000_000e18);
        vm.expectRevert(GenesisSplitter.AlreadySplit.selector);
        splitter.split();
        // A second registration reverts.
        vm.expectRevert(PriceGuard.AlreadyRegistered.selector);
        guard.registerNotStock(LAUNCH_NO);
    }

    function test_fork_launchGasUnderBlockBound() public {
        if (!forked) vm.skip(true);
        _launch();
        emit log_named_uint("launch transaction gas", launchGas);
        assertLt(launchGas, 16_777_216);
    }

    function test_fork_onlyProjectWalletSetsRequester() public {
        if (!forked) vm.skip(true);
        _launch();
        _modules();
        vm.prank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18);
        // A stranger cannot redirect the fee recipient.
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        FACTORY.setRequester(LAUNCH_NO, address(vault));
        // Registration refuses while the fee recipient is still the project wallet (an EOA).
        vm.expectRevert(PriceGuard.WrongRecipient.selector);
        guard.registerNotStock(LAUNCH_NO);
        // split() before registration reverts.
        vm.expectRevert(GenesisSplitter.NotRegistered.selector);
        splitter.split();
        // distribute() before registration reverts.
        vm.expectRevert(FirmVault.NotRegistered.selector);
        vault.distribute(IMD);
    }

    function test_fork_registerRefusesShortSplitter() public {
        if (!forked) vm.skip(true);
        _launch();
        _modules();
        vm.startPrank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18 - 1);
        FACTORY.setRequester(LAUNCH_NO, address(vault));
        vm.stopPrank();
        vm.expectRevert(PriceGuard.SplitterShort.selector);
        guard.registerNotStock(LAUNCH_NO);
        // One more wei from anyone (the project wallet here) and it registers.
        vm.prank(PROJECT);
        token.transfer(address(splitter), 1);
        guard.registerNotStock(LAUNCH_NO);
        assertTrue(desk.registered());
    }

    function test_fork_vaultNotstockFeesBurnThroughBurner() public {
        if (!forked) vm.skip(true);
        _launch();
        _modules();
        _postLaunch();
        // NOTSTOCK reaching FirmVault by plain transfer (as the factory pays fees) goes 100% to Burner.
        vm.prank(OPERATOR);
        token.transfer(address(vault), 1234e18);
        vm.prank(address(0xCAFE));
        vault.distribute(address(token));
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(address(burner)), 1234e18);
        uint256 deadBefore = token.balanceOf(DEAD);
        burner.burn();
        assertEq(token.balanceOf(DEAD), deadBefore + 1234e18);
        vm.expectRevert(Burner.NothingToBurn.selector);
        burner.burn();
    }

    /// @dev The registered launch pool's buyback: the live IMD token and the live Uniswap v4 PoolManager.
    function test_fork_vaultDistributeImdAndBuybackInLivePool() public {
        if (!forked) vm.skip(true);
        _launch();
        _modules();
        _postLaunch();
        deal(IMD, address(vault), 1000e18);
        uint256 projBefore = IERC20Like(IMD).balanceOf(PROJECT);
        vault.distribute(IMD);
        // 25/25/25/25 of what the vault held: bucket 250, project 250 (as measured), LpDesk 500 credited.
        assertEq(vault.buybackBucket(), 250e18);
        assertEq(IERC20Like(IMD).balanceOf(PROJECT) - projBefore, 250e18);
        assertEq(desk.topUpBasket(IMD) + desk.freeBalance(IMD), 500e18);
        assertEq(vault.undistributed(IMD), 0);

        // A stranger cannot spend the bucket.
        vm.prank(address(0xBEEF));
        vm.expectRevert(FirmVault.NotOperator.selector);
        vault.buyback(1e18, 0);
        // Above the bucket reverts.
        vm.prank(OPERATOR);
        vm.expectRevert(FirmVault.AboveBucket.selector);
        vault.buyback(250e18 + 1, 0);
        // minOut above what the pool gives reverts.
        vm.prank(OPERATOR);
        vm.expectRevert();
        vault.buyback(100e18, type(uint256).max);

        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(OPERATOR);
        vault.buyback(100e18, 1);
        assertEq(vault.buybackBucket(), 150e18, "bucket down by exactly amount");
        assertGt(token.balanceOf(DEAD), deadBefore, "dead address got NOTSTOCK");
        // Nothing stays behind in the swap module.
        address v4m = desk.venueV4();
        assertEq(token.balanceOf(v4m), 0);
        assertEq(IERC20Like(IMD).balanceOf(v4m), 0);
    }

    // ------------------------------------------------------------------ live venues (section 2b)

    address constant WETH = 0x4200000000000000000000000000000000000006;

    /// @dev Single-sided NOTSTOCK open of `amount` on a fresh WETH/NOTSTOCK pool of `venue`, then collect and close.
    function _openCollectClose(address venue, uint24 fee, int24 ts) internal {
        _launch();
        _modules();
        _postLaunch();
        (bool listed, uint8 kind) = guard.venueKind(venue);
        assertTrue(listed, "venue listed at deploy");
        IVenueModule m = IVenueModule(desk.moduleAddress(kind == KIND_V4 ? MODULE_VENUEV4 : MODULE_VENUEV3));
        bool notIs0 = address(token) < WETH;
        (int24 lower, int24 upper) = notIs0 ? (int24(600), int24(6000)) : (int24(-6000), int24(-600));
        uint160 price = FirmMath.getSqrtRatioAtTick(0);
        uint256 amount = 1_000_000e18;
        Position memory pos = m.prepare(
            Position({
                manager: venue,
                kind: kind,
                asset: WETH,
                fee: fee,
                tickSpacing: ts,
                tickLower: lower,
                tickUpper: upper,
                tokenId: 0,
                open: true
            })
        );
        (uint256 n, uint256 a,) = m.quote(pos, price, amount, false);
        assertEq(a, 0, "single-sided NOTSTOCK takes no WETH");
        uint256 floorNot = n * 9_950 / 10_000;
        OpenParams memory p = OpenParams({
            asset: WETH,
            venue: venue,
            fee: fee,
            tickSpacing: ts,
            tickLower: lower,
            tickUpper: upper,
            sqrtPriceX96: price,
            amount: amount,
            amount0Min: notIs0 ? floorNot : 0,
            amount1Min: notIs0 ? 0 : floorNot
        });

        // A minimum below 99.5% of the quoted amount reverts; a stranger cannot open.
        if (notIs0) p.amount0Min = floorNot - 1;
        else p.amount1Min = floorNot - 1;
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.MinTooLow.selector);
        desk.open(p);
        if (notIs0) p.amount0Min = floorNot;
        else p.amount1Min = floorNot;
        vm.prank(address(0xBEEF));
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.open(p);

        uint256 freeBefore = desk.freeBalance(address(token));
        uint256 projWeth = IERC20Like(WETH).balanceOf(PROJECT);
        vm.prank(OPERATOR);
        uint256 id = desk.open(p);
        uint256 spent = freeBefore - desk.freeBalance(address(token));
        assertGe(spent, floorNot);
        assertLe(spent, n);
        assertGt(desk.positionLiquidity(id), 0);
        // Nothing left in the module.
        assertEq(token.balanceOf(address(m)), 0);
        assertEq(IERC20Like(WETH).balanceOf(address(m)), 0);

        // A second open of the same pool at a price more than 0.5% away reverts.
        p.sqrtPriceX96 = FirmMath.getSqrtRatioAtTick(200);
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.PriceMoved.selector);
        desk.open(p);

        vm.prank(OPERATOR);
        desk.collect(id);
        // Close by a stranger reverts; minimum outs above what the pool returns revert.
        vm.prank(address(0xBEEF));
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.close(id, 0, 0);
        vm.prank(OPERATOR);
        vm.expectRevert();
        desk.close(id, notIs0 ? spent + 1 : 0, notIs0 ? 0 : spent + 1);

        vm.prank(OPERATOR);
        desk.close(id, notIs0 ? spent - 2 : 0, notIs0 ? 0 : spent - 2);
        uint256 back = desk.freeBalance(address(token));
        assertGe(back + 2, freeBefore, "principal back to free balance");
        assertLe(back, freeBefore);
        assertEq(desk.topUpBasket(WETH), 0);
        assertEq(desk.buybackBasket(WETH), 0);
        assertEq(IERC20Like(WETH).balanceOf(PROJECT), projWeth);
        assertEq(token.balanceOf(address(m)), 0);
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.PositionClosedError.selector);
        desk.close(id, 0, 0);
    }

    /// @dev Every venue listed at deploy, one after another from the same pre-launch state. They run in one
    /// test rather than six parallel ones so the live state each venue needs is fetched at a steady pace.
    function test_fork_venuesOpenCollectClose() public {
        if (!forked) vm.skip(true);
        address[6] memory managers = [
            0x7C5f5A4bBd8fD63184577525326123B519429bDc, // Uniswap v4 PositionManager
            0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1, // Uniswap v3 NonfungiblePositionManager
            0x46A15B0b27311cedF172AB29E4f4766fbE7F4364, // PancakeSwap v3
            0x80C7DD17B01855a6D2347444a0FCC36136a314de, // SushiSwap v3
            0x827922686190790b37229fd06084350E74485b72, // Aerodrome Slipstream
            0x4857DB576eE0e45F10525eC59527BfD10beeC60b // Aerodrome Slipstream (second factory)
        ];
        uint24[6] memory fees = [uint24(3000), 3000, 2500, 3000, 0, 0];
        int24[6] memory spacings = [int24(60), 0, 0, 0, 200, 200];
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < managers.length; ++i) {
            _openCollectClose(managers[i], fees[i], spacings[i]);
            vm.revertToState(snap);
        }
    }

    function test_fork_venuesAtDeployAndUnlistedManager() public {
        if (!forked) vm.skip(true);
        _launch();
        _modules();
        _postLaunch();
        assertEq(guard.venues().length, 6);
        OpenParams memory p;
        p.asset = WETH;
        p.venue = 0xDe151D5c92BfAA288Db4B67c21CD55d5826bCc93; // BaseSwap v3, not listed at deploy
        p.fee = 3000;
        p.tickLower = 600;
        p.tickUpper = 6000;
        p.sqrtPriceX96 = FirmMath.getSqrtRatioAtTick(0);
        p.amount = 1e18;
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.UnlistedVenue.selector);
        desk.open(p);
        p.venue = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
        p.asset = address(0xA55E7);
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.UnlistedAsset.selector);
        desk.open(p);
    }
}
