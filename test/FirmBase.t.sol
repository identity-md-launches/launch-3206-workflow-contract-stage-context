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
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockLaunchFactory} from "./mocks/MockLaunchFactory.sol";
import {MockV4PoolManager, MockV4PositionManager} from "./mocks/MockV4.sol";

/// @dev The launch as the factory performs it, on a local chain with the IMD token mocked at its Base
/// address: token + LpDesk (+ Burner) + FirmVault + GenesisSplitter in one factory call, every module by
/// deployModule, the project wallet's 600,000,000 transfer and setRequester, registerNotStock, split().
abstract contract FirmBase is Test {
    address constant IMD_ADDR = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant UNI_V4_POSM = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address constant OPERATOR = 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981;
    address constant PROJECT = 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C;
    uint64 constant LAUNCH = 7;

    MockLaunchFactory factory;
    LaunchToken token;
    LpDesk desk;
    Burner burner;
    FirmVault vault;
    GenesisSplitter splitter;
    PriceGuard guard;
    LpGovernor gov;
    VenueV3 v3;
    VenueV4 v4;
    MockERC20 imd;
    MockV4PoolManager poolManager;

    function setUp() public virtual {
        vm.chainId(8453);
        vm.warp(1_800_000_000);
        vm.roll(40_000_000);
        // IMD at its Base address.
        MockERC20 impl = new MockERC20("Fren Pet", "Fren Pet", 18);
        vm.etch(IMD_ADDR, address(impl).code);
        imd = MockERC20(IMD_ADDR);
        // Uniswap v4 PositionManager at its Base address, pointing at a mock PoolManager.
        poolManager = new MockV4PoolManager();
        MockV4PositionManager posm = new MockV4PositionManager(address(poolManager));
        vm.etch(UNI_V4_POSM, address(posm).code);

        factory = new MockLaunchFactory();
        factory.launch(LAUNCH, OPERATOR, PROJECT, OPERATOR);
        token = factory.token();
        desk = factory.lpDesk();
        burner = Burner(desk.burner());
        vault = factory.firmVault();
        splitter = factory.splitter();
        _deployModules();
    }

    function _deployModules() internal {
        guard = PriceGuard(desk.deployModule(MODULE_PRICEGUARD, type(PriceGuard).creationCode));
        gov = LpGovernor(desk.deployModule(MODULE_LPGOVERNOR, type(LpGovernor).creationCode));
        v3 = VenueV3(desk.deployModule(MODULE_VENUEV3, type(VenueV3).creationCode));
        v4 = VenueV4(desk.deployModule(MODULE_VENUEV4, type(VenueV4).creationCode));
    }

    /// @dev The two post-launch transactions of the project wallet, then registration and split.
    function _registerAndSplit() internal {
        vm.startPrank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18);
        factory.setRequester(LAUNCH, address(vault));
        vm.stopPrank();
        guard.registerNotStock(LAUNCH);
        splitter.split();
        // The registered pool at one-to-one in the mock PoolManager.
        poolManager.initialize(guard.poolKey(), uint160(1 << 96));
    }
}
