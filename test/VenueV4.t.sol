// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FirmBase} from "./FirmBase.t.sol";
import {VenueV4} from "../src/modules/VenueV4.sol";
import {Position, KIND_V4} from "../src/interfaces/IFirm.sol";

/// @dev The v4 PositionManager surface VenueV4.collect touches. modifyLiquidities reverts on a position with
/// zero liquidity, as v4-core's Position.update does for a zero-delta poke (CannotUpdateEmptyPosition).
contract MockV4PosmLiquidity {
    mapping(uint256 => uint128) public liquidityOf;
    uint256 public pokes;

    function setLiquidity(uint256 id, uint128 l) external {
        liquidityOf[id] = l;
    }

    function getPositionLiquidity(uint256 id) external view returns (uint128) {
        return liquidityOf[id];
    }

    function modifyLiquidities(bytes calldata data, uint256) external {
        (, bytes[] memory params) = abi.decode(data, (bytes, bytes[]));
        (uint256 id) = abi.decode(params[0], (uint256));
        require(liquidityOf[id] != 0, "CannotUpdateEmptyPosition");
        ++pokes;
    }
}

/// @notice VenueV4: a position emptied by moveLiquidity is skipped by collect instead of reverting.
contract VenueV4Test is FirmBase {
    function _pos(address manager, uint256 tokenId) internal view returns (Position memory) {
        return Position({
            manager: manager,
            kind: KIND_V4,
            asset: IMD_ADDR,
            fee: 3000,
            tickSpacing: 60,
            tickLower: -600,
            tickUpper: 600,
            tokenId: tokenId,
            open: true
        });
    }

    function test_collectSkipsEmptyPositionAndPokesLiveOne() public {
        MockV4PosmLiquidity posm = new MockV4PosmLiquidity();
        posm.setLiquidity(1, 1e18);
        vm.startPrank(address(desk));
        v4.collect(_pos(address(posm), 1));
        assertEq(posm.pokes(), 1, "a live position is poked to collect its fees");
        v4.collect(_pos(address(posm), 2));
        assertEq(posm.pokes(), 1, "an empty position is skipped, no revert");
        vm.stopPrank();
    }

    function test_collectOnlyByLpDesk() public {
        MockV4PosmLiquidity posm = new MockV4PosmLiquidity();
        vm.expectRevert(VenueV4.NotLpDesk.selector);
        v4.collect(_pos(address(posm), 1));
    }
}
