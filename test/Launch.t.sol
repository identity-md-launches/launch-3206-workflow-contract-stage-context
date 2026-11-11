// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FirmBase} from "./FirmBase.t.sol";
import {LpDesk} from "../src/LpDesk.sol";
import {Burner} from "../src/Burner.sol";
import {FirmVault} from "../src/FirmVault.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {PriceGuard} from "../src/modules/PriceGuard.sol";
import {LpGovernor} from "../src/modules/LpGovernor.sol";
import {VenueV3} from "../src/modules/VenueV3.sol";
import {VenueV4} from "../src/modules/VenueV4.sol";
import {
    MODULE_LPGOVERNOR,
    MODULE_PRICEGUARD,
    MODULE_VENUEV3,
    MODULE_VENUEV4,
    OpenParams
} from "../src/interfaces/IFirm.sol";
import {PoolKey} from "../src/interfaces/IVenues.sol";
import {MockLaunchFactory} from "./mocks/MockLaunchFactory.sol";

contract OtherVault {
    address public lpDesk = address(0x1234);
}

/// @notice Launch layout, modules, registration, GenesisSplitter and Burner.
contract LaunchTest is FirmBase {
    // ------------------------------------------------------------ layout and modules

    function test_constructorWiring() public view {
        assertEq(desk.token(), address(token));
        assertEq(desk.launchFactory(), address(factory));
        assertEq(desk.operator(), OPERATOR);
        assertEq(desk.projectWallet(), PROJECT);
        assertEq(burner.lpDesk(), address(desk));
        assertEq(vault.lpDesk(), address(desk));
        assertEq(vault.projectWallet(), PROJECT);
        assertEq(splitter.lpDesk(), address(desk));
        assertEq(splitter.devWallet(), OPERATOR);
        assertEq(address(guard.lpDesk()), address(desk));
        assertEq(address(gov.lpDesk()), address(desk));
        assertEq(v3.lpDesk(), address(desk));
        assertEq(v4.lpDesk(), address(desk));
    }

    function test_moduleHashesMatchCreationCode() public view {
        assertEq(desk.LPGOVERNOR_CODE_HASH(), keccak256(type(LpGovernor).creationCode));
        assertEq(desk.PRICEGUARD_CODE_HASH(), keccak256(type(PriceGuard).creationCode));
        assertEq(desk.VENUEV3_CODE_HASH(), keccak256(type(VenueV3).creationCode));
        assertEq(desk.VENUEV4_CODE_HASH(), keccak256(type(VenueV4).creationCode));
        assertTrue(desk.isModuleDeployed(MODULE_LPGOVERNOR));
        assertTrue(desk.isModuleDeployed(MODULE_PRICEGUARD));
        assertTrue(desk.isModuleDeployed(MODULE_VENUEV3));
        assertTrue(desk.isModuleDeployed(MODULE_VENUEV4));
        assertEq(desk.lpGovernor(), address(gov));
        assertEq(desk.priceGuard(), address(guard));
        assertEq(desk.venueV3(), address(v3));
        assertEq(desk.venueV4(), address(v4));
    }

    function test_deployModuleRefusesOtherCodeAndSecondDeploy() public {
        vm.expectRevert(LpDesk.WrongModuleCode.selector);
        desk.deployModule(MODULE_LPGOVERNOR, type(PriceGuard).creationCode);
        vm.expectRevert(LpDesk.ModuleExists.selector);
        desk.deployModule(MODULE_LPGOVERNOR, type(LpGovernor).creationCode);
        vm.expectRevert(LpDesk.UnknownModule.selector);
        desk.deployModule("Other", type(LpGovernor).creationCode);
    }

    function test_runtimeSizesWithinSpecLimits() public view {
        assertLt(address(desk).code.length, 24_576);
        assertLt(address(gov).code.length, 24_576);
        assertLt(address(guard).code.length, 24_576);
        assertLt(address(v3).code.length, 24_576);
        assertLt(address(v4).code.length, 24_576);
        assertLt(address(vault).code.length, 10_240);
        assertLt(address(splitter).code.length, 2_048);
        assertLt(address(burner).code.length, 1_024);
        assertLt(type(LpDesk).creationCode.length, 49_152);
    }

    function test_functionsNeedingModulesRevertBeforeDeploy() public {
        MockLaunchFactory f2 = new MockLaunchFactory();
        f2.launch(1, OPERATOR, PROJECT, OPERATOR);
        LpDesk d2 = f2.lpDesk();
        assertFalse(d2.registered());
        assertEq(d2.bootstrapEnd(), 0);
        vm.expectRevert(LpDesk.ModuleMissing.selector);
        d2.firmVault();
        OpenParams memory p;
        vm.prank(OPERATOR);
        vm.expectRevert(LpDesk.NotRegistered.selector);
        d2.open(p);
    }

    function test_venueAndAssetListsAtDeploy() public view {
        PriceGuard.Venue[] memory vs = guard.venues();
        assertEq(vs.length, 6);
        assertEq(vs[0].manager, 0x7C5f5A4bBd8fD63184577525326123B519429bDc);
        assertEq(vs[0].factory, 0x498581fF718922c3f8e6A244956aF099B2652b2b);
        assertEq(vs[1].manager, 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1);
        assertEq(vs[2].manager, 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364);
        assertEq(vs[3].manager, 0x80C7DD17B01855a6D2347444a0FCC36136a314de);
        assertEq(vs[4].manager, 0x827922686190790b37229fd06084350E74485b72);
        assertEq(vs[5].manager, 0x4857DB576eE0e45F10525eC59527BfD10beeC60b);
        assertEq(uint256(vs[4].kind), 2);
        address[] memory as_ = guard.assets();
        assertEq(as_.length, 13);
        assertEq(as_[0], IMD_ADDR);
        assertEq(as_[1], 0x4200000000000000000000000000000000000006);
        assertEq(as_[2], 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        assertEq(as_[3], 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf);
        assertEq(as_[4], 0xb2000000000000000000002D0BA3164cc74f58B7);
        assertEq(as_[12], 0xb2000000000000000000007d16372840dF4dAbbe);
        assertTrue(guard.isAsset(0xB200000000000000000000Ab99cFa739E253872B));
    }

    // ------------------------------------------------------------ registration

    function test_registerAndSplitConserveSupply() public {
        _registerAndSplit();
        assertTrue(desk.registered());
        assertEq(desk.bootstrapEnd(), vm.getBlockTimestamp() + 604_800);
        assertEq(desk.firmVault(), address(vault));
        assertEq(token.balanceOf(address(desk)), 500_000_000e18);
        assertEq(token.balanceOf(OPERATOR), 100_000_000e18);
        assertEq(token.balanceOf(address(splitter)), 0);
        assertEq(token.balanceOf(address(factory)), 300_000_000e18);
        assertEq(token.balanceOf(address(0x5AAA)), 100_000_000e18);
        PoolKey memory k = desk.registeredPoolKey();
        assertEq(k.fee, 12_500);
        assertEq(k.hooks, factory.poolHook());
        assertTrue(splitter.hasSplit());
        vm.expectRevert(GenesisSplitter.AlreadySplit.selector);
        splitter.split();
        vm.expectRevert(PriceGuard.AlreadyRegistered.selector);
        guard.registerNotStock(LAUNCH);
    }

    function test_splitNeedsRegistrationAndBalance() public {
        vm.expectRevert(GenesisSplitter.NotRegistered.selector);
        splitter.split();
    }

    function test_registerRevertsWhileSplitterShort() public {
        vm.startPrank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18 - 1);
        factory.setRequester(LAUNCH, address(vault));
        vm.stopPrank();
        vm.expectRevert(PriceGuard.SplitterShort.selector);
        guard.registerNotStock(LAUNCH);
        // 60% plus extra tokens sent by anyone registers.
        vm.prank(PROJECT);
        token.transfer(address(splitter), 1);
        vm.prank(OPERATOR);
        token.transfer(address(splitter), 0);
        vm.prank(address(0x5AAA));
        token.transfer(address(splitter), 5e18);
        guard.registerNotStock(LAUNCH);
        splitter.split();
        assertEq(token.balanceOf(address(desk)), uint256(600_000_005e18) * 50 / 60);
    }

    function test_registerRevertsForWrongRecipient() public {
        vm.prank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18);
        // Requester still the project wallet (no code).
        vm.expectRevert(PriceGuard.WrongRecipient.selector);
        guard.registerNotStock(LAUNCH);
        // A contract whose lpDesk() is not this LpDesk.
        OtherVault other = new OtherVault();
        vm.prank(PROJECT);
        factory.setRequester(LAUNCH, address(other));
        vm.expectRevert(PriceGuard.WrongRecipient.selector);
        guard.registerNotStock(LAUNCH);
    }

    function test_registerRevertsForWrongFeeHookOrPair() public {
        vm.startPrank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18);
        factory.setRequester(LAUNCH, address(vault));
        vm.stopPrank();
        PoolKey memory k = _goodKey();
        k.fee = 10_000;
        factory.setKey(LAUNCH, k);
        vm.expectRevert(PriceGuard.WrongPool.selector);
        guard.registerNotStock(LAUNCH);
        k = _goodKey();
        k.hooks = address(0xBAD);
        factory.setKey(LAUNCH, k);
        vm.expectRevert(PriceGuard.WrongPool.selector);
        guard.registerNotStock(LAUNCH);
        k = _goodKey();
        k.currency0 = address(0x1);
        factory.setKey(LAUNCH, k);
        vm.expectRevert(PriceGuard.WrongPool.selector);
        guard.registerNotStock(LAUNCH);
        // A later change of the live poolFee setting does not block registration (constant 12500).
        factory.setKey(LAUNCH, _goodKey());
        factory.setPoolFee(10_000);
        guard.registerNotStock(LAUNCH);
        assertTrue(guard.registered());
    }

    function test_registerRevertsWithoutArtifacts() public {
        vm.startPrank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18);
        factory.setRequester(LAUNCH, address(vault));
        vm.stopPrank();
        factory.setArtifactAddr(LAUNCH, "LpDesk", address(0x77));
        vm.expectRevert(PriceGuard.ArtifactMissing.selector);
        guard.registerNotStock(LAUNCH);
        factory.setArtifactAddr(LAUNCH, "LpDesk", address(desk));
        factory.dropArtifact(LAUNCH, "GenesisSplitter");
        vm.expectRevert(PriceGuard.ArtifactMissing.selector);
        guard.registerNotStock(LAUNCH);
    }

    function test_registerRevertsForAnotherLaunch() public {
        vm.expectRevert(PriceGuard.WrongPool.selector);
        guard.registerNotStock(99);
    }

    function _goodKey() internal view returns (PoolKey memory k) {
        (address c0, address c1) = address(token) < IMD_ADDR ? (address(token), IMD_ADDR) : (IMD_ADDR, address(token));
        k = PoolKey({currency0: c0, currency1: c1, fee: 12_500, tickSpacing: 60, hooks: factory.poolHook()});
    }

    // ------------------------------------------------------------ Burner

    function test_burnerBurnsWholeBalanceAndRevertsOnZero() public {
        vm.expectRevert(Burner.NothingToBurn.selector);
        burner.burn();
        vm.prank(PROJECT);
        token.transfer(address(burner), 7e18);
        vm.prank(address(0xABCD));
        burner.burn();
        assertEq(token.balanceOf(DEAD), 7e18);
        assertEq(token.balanceOf(address(burner)), 0);
        vm.expectRevert(Burner.NothingToBurn.selector);
        burner.burn();
    }

    function test_burnerHasNoOtherStateChangingFunction() public {
        (bool ok,) = address(burner).call(abi.encodeWithSignature("withdraw(address,uint256)", address(this), 1));
        assertFalse(ok);
        (ok,) = address(burner).call(abi.encodeWithSignature("setToken(address)", address(this)));
        assertFalse(ok);
    }
}
