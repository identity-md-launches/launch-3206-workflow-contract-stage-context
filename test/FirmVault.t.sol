// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FirmBase} from "./FirmBase.t.sol";
import {FirmVault} from "../src/FirmVault.sol";
import {VenueV4} from "../src/modules/VenueV4.sol";
import {PoolKey} from "../src/interfaces/IVenues.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice FirmVault: distribute(), the LpDesk credit, and the operator buyback in the registered pool.
contract FirmVaultTest is FirmBase {
    function test_distributeRevertsBeforeRegistration() public {
        imd.mint(address(vault), 100e18);
        vm.expectRevert(FirmVault.NotRegistered.selector);
        vault.distribute(IMD_ADDR);
    }

    function test_distributeImdSplitsExactly() public {
        _registerAndSplit();
        factory.payFees(LAUNCH, IMD_ADDR, 0);
        imd.mint(address(factory), 1_000e18);
        factory.payFees(LAUNCH, IMD_ADDR, 100e18); // the factory's plain transfer to the requester
        assertEq(imd.balanceOf(address(vault)), 100e18);
        vm.prank(address(0xABCD));
        vault.distribute(IMD_ADDR);
        assertEq(vault.buybackBucket(), 25e18);
        assertEq(imd.balanceOf(PROJECT), 25e18);
        assertEq(desk.topUpBasket(IMD_ADDR), 25e18);
        assertEq(desk.freeBalance(IMD_ADDR), 25e18);
        assertEq(imd.balanceOf(address(desk)), 50e18);
        assertEq(imd.balanceOf(address(vault)), 25e18, "only the bucket stays");
        assertEq(vault.undistributed(IMD_ADDR), 0);
        // A second distribute with no new transfer moves nothing.
        vault.distribute(IMD_ADDR);
        assertEq(vault.buybackBucket(), 25e18);
        assertEq(imd.balanceOf(PROJECT), 25e18);
        assertEq(desk.topUpBasket(IMD_ADDR), 25e18);
    }

    function test_severalTransfersSplitTheirSum() public {
        _registerAndSplit();
        imd.mint(address(vault), 30e18);
        imd.mint(address(vault), 50e18);
        vault.distribute(IMD_ADDR);
        assertEq(vault.buybackBucket(), 20e18);
        assertEq(imd.balanceOf(PROJECT), 20e18);
        assertEq(desk.topUpBasket(IMD_ADDR), 20e18);
        assertEq(desk.freeBalance(IMD_ADDR), 20e18);
        // Rounding dust (sum not divisible by 4) goes to LpDesk's free balance, nothing is left unaccounted.
        imd.mint(address(vault), 7);
        vault.distribute(IMD_ADDR);
        assertEq(vault.buybackBucket(), 20e18 + 1);
        assertEq(imd.balanceOf(PROJECT), 20e18 + 1);
        assertEq(desk.topUpBasket(IMD_ADDR), 20e18 + 2);
        assertEq(desk.freeBalance(IMD_ADDR), 20e18 + 3);
        assertEq(imd.balanceOf(address(vault)), vault.buybackBucket());
    }

    function test_distributeNotstockGoesToBurner() public {
        _registerAndSplit();
        vm.prank(OPERATOR);
        token.transfer(address(vault), 9e18);
        vault.distribute(address(token));
        assertEq(token.balanceOf(address(burner)), 9e18);
        assertEq(token.balanceOf(address(vault)), 0);
        burner.burn();
        assertEq(token.balanceOf(DEAD), 9e18);
    }

    function test_distributeOtherTokenReverts() public {
        _registerAndSplit();
        MockERC20 other = new MockERC20("X", "X", 18);
        other.mint(address(vault), 1e18);
        vm.expectRevert(FirmVault.UnsupportedToken.selector);
        vault.distribute(address(other));
    }

    function test_creditOnlyFromLpDesk() public {
        _registerAndSplit();
        vm.prank(OPERATOR);
        vm.expectRevert(FirmVault.NotLpDesk.selector);
        vault.creditFromLpDesk(1);
        vm.prank(address(desk));
        vm.expectRevert(FirmVault.CreditExceedsBalance.selector);
        vault.creditFromLpDesk(1);
        imd.mint(address(vault), 10e18);
        vm.prank(address(desk));
        vault.creditFromLpDesk(10e18);
        assertEq(vault.buybackBucket(), 10e18);
        assertEq(vault.undistributed(IMD_ADDR), 0);
    }

    function test_bucketSurvivesShortBalance() public {
        _registerAndSplit();
        imd.mint(address(vault), 100e18);
        vault.distribute(IMD_ADDR);
        // Even if the balance ever fell below the bucket (issuer action), undistributed clamps to zero.
        assertEq(vault.undistributed(IMD_ADDR), 0);
        vault.distribute(IMD_ADDR);
        assertEq(vault.buybackBucket(), 25e18);
    }

    function test_buybackByOperatorOnly() public {
        _registerAndSplit();
        imd.mint(address(vault), 100e18);
        vault.distribute(IMD_ADDR);
        PoolKey memory key = desk.registeredPoolKey();
        // The pool pays NOTSTOCK out of the PoolManager's balance.
        vm.prank(address(factory));
        token.transfer(address(poolManager), 1_000e18);
        uint256 quoted = poolManager.quoteOut(key, IMD_ADDR == key.currency0, 10e18);
        assertGt(quoted, 0);
        vm.prank(PROJECT);
        vm.expectRevert(FirmVault.NotOperator.selector);
        vault.buyback(10e18, 0);
        vm.prank(OPERATOR);
        vm.expectRevert(FirmVault.AboveBucket.selector);
        vault.buyback(25e18 + 1, 0);
        vm.prank(OPERATOR);
        vm.expectRevert(VenueV4.BelowMinOut.selector);
        vault.buyback(10e18, quoted + 1);
        vm.prank(OPERATOR);
        vault.buyback(10e18, quoted);
        assertEq(vault.buybackBucket(), 15e18);
        assertEq(imd.balanceOf(address(vault)), 15e18);
        assertEq(token.balanceOf(DEAD), quoted, "all NOTSTOCK out to the dead address");
        assertEq(imd.balanceOf(address(v4)), 0);
        assertEq(imd.balanceOf(address(poolManager)), 10e18);
    }

    function test_vaultSwapModuleOnlyByFirmVault() public {
        _registerAndSplit();
        PoolKey memory key = desk.registeredPoolKey();
        vm.expectRevert(VenueV4.NotAllowed.selector);
        v4.swapExactInForVault(key, IMD_ADDR, 1, 0, DEAD);
        vm.expectRevert(VenueV4.NotPoolManager.selector);
        v4.unlockCallback("");
    }
}
