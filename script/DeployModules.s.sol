// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "../test/vendor/forge-std/src/Script.sol";
import {LpDesk} from "../src/LpDesk.sol";
import {LpGovernor} from "../src/modules/LpGovernor.sol";
import {PriceGuard} from "../src/modules/PriceGuard.sol";
import {VenueV3} from "../src/modules/VenueV3.sol";
import {VenueV4} from "../src/modules/VenueV4.sol";
import {MODULE_LPGOVERNOR, MODULE_PRICEGUARD, MODULE_VENUEV3, MODULE_VENUEV4} from "../src/interfaces/IFirm.sol";

/// @title DeployModules
/// @notice After the launch, calls LpDesk.deployModule for every module that is not yet deployed:
/// PriceGuard, LpGovernor, VenueV3 and VenueV4, each by CREATE2 from LpDesk with salt = module kind and
/// the creation code whose hash LpDesk pins. Anyone may run it; the modules take no constructor argument.
///
/// Verification input per module: the artifact of this repository built with foundry.toml as pinned
/// (solc 0.8.26, via_ir, optimizer runs 1, evm cancun, bytecode_hash none), constructor arguments none,
/// deployer = LpDesk (CREATE2). Predicted addresses: LpDesk.moduleAddress(kind).
///
/// Usage: `forge script script/DeployModules.s.sol --sig "deploy(address)" <LpDesk> --rpc-url <base> --broadcast`
contract DeployModules is Script {
    function run() external {
        deploy(vm.envAddress("LP_DESK"));
    }

    /// @dev Deploys only the modules still missing; a rerun is harmless.
    function deploy(address lpDesk) public {
        LpDesk desk = LpDesk(lpDesk);
        vm.startBroadcast();
        _deploy(desk, MODULE_PRICEGUARD, type(PriceGuard).creationCode);
        _deploy(desk, MODULE_LPGOVERNOR, type(LpGovernor).creationCode);
        _deploy(desk, MODULE_VENUEV3, type(VenueV3).creationCode);
        _deploy(desk, MODULE_VENUEV4, type(VenueV4).creationCode);
        vm.stopBroadcast();
    }

    function _deploy(LpDesk desk, bytes32 kind, bytes memory code) internal {
        if (desk.isModuleDeployed(kind)) return;
        desk.deployModule(kind, code);
    }
}
