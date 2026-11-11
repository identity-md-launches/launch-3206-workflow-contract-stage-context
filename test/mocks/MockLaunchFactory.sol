// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey, ILaunchRegistry} from "../../src/interfaces/IVenues.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {LpDesk} from "../../src/LpDesk.sol";
import {FirmVault} from "../../src/FirmVault.sol";
import {GenesisSplitter} from "../../src/GenesisSplitter.sol";

/// @dev Stands in for ProjectFactory: deploys the token and the three launch contracts in one call (so
/// LpDesk's constructor msg.sender is the factory), keeps the pool key, requester and artifact records
/// the way the live factory's positionOf / registry().artifactsOf / fees() / poolHook() expose them.
contract MockLaunchFactory {
    address public constant IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    uint24 public poolFee = 12_500;
    address public poolHook = address(0xB369);

    LaunchToken public token;
    LpDesk public lpDesk;
    FirmVault public firmVault;
    GenesisSplitter public splitter;

    mapping(uint64 => PoolKey) internal _keys;
    mapping(uint64 => address) public requesterOf;
    mapping(uint64 => ILaunchRegistry.Artifact[]) internal _artifacts;

    function launch(uint64 n, address operator, address projectWallet, address devWallet) external {
        token = new LaunchToken();
        lpDesk = new LpDesk(address(token), operator, projectWallet);
        firmVault = new FirmVault(projectWallet, address(lpDesk));
        splitter = new GenesisSplitter(address(lpDesk), devWallet);
        (address c0, address c1) = address(token) < IMD ? (address(token), IMD) : (IMD, address(token));
        _keys[n] = PoolKey({currency0: c0, currency1: c1, fee: poolFee, tickSpacing: 60, hooks: poolHook});
        requesterOf[n] = projectWallet;
        _artifacts[n].push(ILaunchRegistry.Artifact({role: "token", name: "LaunchToken", addr: address(token)}));
        _artifacts[n].push(ILaunchRegistry.Artifact({role: "contract", name: "LpDesk", addr: address(lpDesk)}));
        _artifacts[n].push(ILaunchRegistry.Artifact({role: "contract", name: "FirmVault", addr: address(firmVault)}));
        _artifacts[n].push(
            ILaunchRegistry.Artifact({role: "contract", name: "GenesisSplitter", addr: address(splitter)})
        );
        // 30% pool (kept here as the pool's share), 10% swarm, 60% remainder to the project wallet.
        token.transfer(address(0x5AAA), 100_000_000e18);
        token.transfer(projectWallet, 600_000_000e18);
    }

    // ---- live factory surface
    function positionOf(uint64 n) external view returns (PoolKey memory key, int24, int24, address requester) {
        return (_keys[n], 0, 0, requesterOf[n]);
    }

    function registry() external view returns (address) {
        return address(this);
    }

    function fees() external view returns (address) {
        return address(this);
    }

    function artifactsOf(uint64 n) external view returns (ILaunchRegistry.Artifact[] memory) {
        return _artifacts[n];
    }

    function setRequester(uint64 n, address requester) external {
        require(msg.sender == requesterOf[n], "NotRequester");
        require(requester != address(0), "ZeroRequester");
        requesterOf[n] = requester;
    }

    /// @dev The requester's share of pool fees, paid by plain transfer as PoolFees.claimFees does.
    function payFees(uint64 n, address currency, uint256 amount) external {
        (bool ok,) = currency.call(abi.encodeWithSignature("transfer(address,uint256)", requesterOf[n], amount));
        require(ok, "pay");
    }

    // ---- test knobs
    function setPoolFee(uint24 fee) external {
        poolFee = fee;
    }

    function setKey(uint64 n, PoolKey memory key) external {
        _keys[n] = key;
    }

    function dropArtifact(uint64 n, bytes32 name) external {
        ILaunchRegistry.Artifact[] storage a = _artifacts[n];
        for (uint256 i; i < a.length; ++i) {
            if (a[i].name == name) {
                a[i] = a[a.length - 1];
                a.pop();
                return;
            }
        }
    }

    function setArtifactAddr(uint64 n, bytes32 name, address addr) external {
        ILaunchRegistry.Artifact[] storage a = _artifacts[n];
        for (uint256 i; i < a.length; ++i) {
            if (a[i].name == name) a[i].addr = addr;
        }
    }
}
