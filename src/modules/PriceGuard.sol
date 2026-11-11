// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "../interfaces/IERC20.sol";
import {
    PoolKey,
    ILaunchFactory,
    ILaunchRegistry,
    IV3PositionManager,
    IV4PositionManager
} from "../interfaces/IVenues.sol";
import {ILpDesk, KIND_V4, KIND_V3, KIND_CL} from "../interfaces/IFirm.sol";

interface IFirmVaultView {
    function lpDesk() external view returns (address);
}

/// @title PriceGuard (LpDesk module)
/// @notice The venue list, the asset list and the one-shot NOTSTOCK registration against the launch
/// factory's record. Lists only grow, through LpDesk (executed AddVenue / AddAsset proposals).
contract PriceGuard {
    struct Venue {
        address manager;
        uint8 kind;
        address factory;
    }

    address public constant IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    uint24 public constant LAUNCH_POOL_FEE = 12_500;
    uint256 public constant EXPECTED_SUPPLY = 1_000_000_000e18;

    ILpDesk public immutable lpDesk;

    Venue[] internal _venues;
    mapping(address => uint256) internal _venueIndexPlusOne;
    address[] internal _assets;
    mapping(address => bool) public isAsset;

    bool public registered;
    uint64 public registeredAt;
    uint64 public launchNumber;
    address public firmVault;
    PoolKey internal _poolKey;

    event Registered(uint64 indexed launchNumber, address firmVault);
    event AssetAdded(address indexed asset);
    event VenueAdded(address indexed manager, uint8 kind, address factory);

    error NotLpDesk();
    error AlreadyRegistered();
    error WrongPool();
    error WrongToken();
    error ArtifactMissing();
    error SplitterShort();
    error WrongRecipient();
    error ZeroAddress();
    error AlreadyListed();
    error NotstockNotAsset();
    error NoCode();
    error BadVenue();
    error BadKind();

    modifier onlyLpDesk() {
        if (msg.sender != address(lpDesk)) revert NotLpDesk();
        _;
    }

    constructor() {
        lpDesk = ILpDesk(msg.sender);
        _addVenue(0x7C5f5A4bBd8fD63184577525326123B519429bDc, KIND_V4, 0x498581fF718922c3f8e6A244956aF099B2652b2b);
        _addVenue(0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1, KIND_V3, 0x33128a8fC17869897dcE68Ed026d694621f6FDfD);
        _addVenue(0x46A15B0b27311cedF172AB29E4f4766fbE7F4364, KIND_V3, 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865);
        _addVenue(0x80C7DD17B01855a6D2347444a0FCC36136a314de, KIND_V3, 0xc35DADB65012eC5796536bD9864eD8773aBc74C4);
        _addVenue(0x827922686190790b37229fd06084350E74485b72, KIND_CL, 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A);
        _addVenue(0x4857DB576eE0e45F10525eC59527BfD10beeC60b, KIND_CL, 0x9CB220581b91b0C83223012FE69688b92aD07a76);
        _addAsset(IMD);
        _addAsset(WETH);
        _addAsset(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913); // USDC, 6
        _addAsset(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf); // cbBTC, 8
        _addAsset(0xb2000000000000000000002D0BA3164cc74f58B7); // GOOGLc, 8
        _addAsset(0xb200000000000000000000397293Cb8cda9a10c5); // SNDKc, 8
        _addAsset(0xb20000000000000000000078ee7ce2fE4908108C); // NVDAc, 8
        _addAsset(0xb2000000000000000000008bC8786B856E61707C); // METAc, 8
        _addAsset(0xb2000000000000000000007b9fcbd005511aCBd5); // SPCXc, 8
        _addAsset(0xB200000000000000000000Ab99cFa739E253872B); // MSFTc, 8
        _addAsset(0xb200000000000000000000C2e324d24d7eEcd1fb); // AAPLc, 8
        _addAsset(0xB2000000000000000000000d8Ce462E99ee7A47B); // AMDc, 8
        _addAsset(0xb2000000000000000000007d16372840dF4dAbbe); // PLTRc, 8
    }

    // ---------------------------------------------------------------- views

    function venues() external view returns (Venue[] memory) {
        return _venues;
    }

    function assets() external view returns (address[] memory) {
        return _assets;
    }

    function venueKind(address manager) external view returns (bool listed, uint8 kind) {
        uint256 i = _venueIndexPlusOne[manager];
        if (i == 0) return (false, 0);
        return (true, _venues[i - 1].kind);
    }

    function venueFactory(address manager) external view returns (address) {
        uint256 i = _venueIndexPlusOne[manager];
        if (i == 0) revert BadVenue();
        return _venues[i - 1].factory;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    /// @notice AddAsset gate: reverts only for the zero address, NOTSTOCK or an already listed asset.
    function checkAsset(address asset) public view {
        if (asset == address(0)) revert ZeroAddress();
        if (asset == lpDesk.token()) revert NotstockNotAsset();
        if (isAsset[asset]) revert AlreadyListed();
    }

    /// @notice AddVenue gate: the manager must have code, be unlisted and answer as its kind.
    function checkVenue(address manager, uint8 kind) public view {
        if (manager == address(0)) revert ZeroAddress();
        if (_venueIndexPlusOne[manager] != 0) revert AlreadyListed();
        if (manager.code.length == 0) revert NoCode();
        _resolveFactory(manager, kind);
    }

    function _resolveFactory(address manager, uint8 kind) internal view returns (address factory) {
        if (kind == KIND_V4) {
            (bool ok, bytes memory data) = manager.staticcall(abi.encodeCall(IV4PositionManager.poolManager, ()));
            if (!ok || data.length < 32) revert BadVenue();
            factory = abi.decode(data, (address));
            if (factory.code.length == 0) revert BadVenue();
        } else if (kind == KIND_V3 || kind == KIND_CL) {
            (bool ok, bytes memory data) = manager.staticcall(abi.encodeCall(IV3PositionManager.factory, ()));
            if (!ok || data.length < 32) revert BadVenue();
            factory = abi.decode(data, (address));
            if (factory.code.length == 0) revert BadVenue();
            (ok, data) = manager.staticcall(abi.encodeCall(IV3PositionManager.WETH9, ()));
            if (!ok || data.length < 32 || abi.decode(data, (address)) != WETH) revert BadVenue();
        } else {
            revert BadKind();
        }
    }

    // ---------------------------------------------------------------- LpDesk-only

    function addAsset(address asset) external onlyLpDesk {
        checkAsset(asset);
        _addAsset(asset);
    }

    function addVenue(address manager, uint8 kind) external onlyLpDesk {
        checkVenue(manager, kind);
        _addVenue(manager, kind, _resolveFactory(manager, kind));
    }

    function _addAsset(address asset) internal {
        isAsset[asset] = true;
        _assets.push(asset);
        emit AssetAdded(asset);
    }

    function _addVenue(address manager, uint8 kind, address factory) internal {
        _venues.push(Venue({manager: manager, kind: kind, factory: factory}));
        _venueIndexPlusOne[manager] = _venues.length;
        emit VenueAdded(manager, kind, factory);
    }

    // ---------------------------------------------------------------- registration

    /// @notice One-shot registration of this launch against the factory that deployed LpDesk.
    function registerNotStock(uint64 launchNumber_) external {
        if (registered) revert AlreadyRegistered();
        ILaunchFactory factory = ILaunchFactory(lpDesk.launchFactory());
        address notstock = lpDesk.token();
        (PoolKey memory key,,, address requester) = factory.positionOf(launchNumber_);
        (address c0, address c1) = notstock < IMD ? (notstock, IMD) : (IMD, notstock);
        if (key.currency0 != c0 || key.currency1 != c1) revert WrongPool();
        // The pool's fee is fixed in its key at launch; it is compared with the launch policy's constant
        // (12500) rather than the owner-settable live LaunchFees.poolFee() (ADAPTATION.md).
        if (key.fee != LAUNCH_POOL_FEE || key.hooks != factory.poolHook()) revert WrongPool();
        IERC20 t = IERC20(notstock);
        if (
            keccak256(bytes(t.name())) != keccak256("The Firm") || keccak256(bytes(t.symbol())) != keccak256("NOTSTOCK")
                || t.totalSupply() != EXPECTED_SUPPLY
        ) revert WrongToken();
        ILaunchRegistry.Artifact[] memory artifacts = ILaunchRegistry(factory.registry()).artifactsOf(launchNumber_);
        address splitter;
        bool deskFound;
        for (uint256 i; i < artifacts.length; ++i) {
            if (artifacts[i].name == bytes32("GenesisSplitter")) splitter = artifacts[i].addr;
            if (artifacts[i].name == bytes32("LpDesk") && artifacts[i].addr == address(lpDesk)) deskFound = true;
        }
        if (splitter == address(0) || !deskFound) revert ArtifactMissing();
        if (t.balanceOf(splitter) < EXPECTED_SUPPLY * 60 / 100) revert SplitterShort();
        if (requester.code.length == 0 || IFirmVaultView(requester).lpDesk() != address(lpDesk)) {
            revert WrongRecipient();
        }
        registered = true;
        registeredAt = uint64(block.timestamp);
        launchNumber = launchNumber_;
        firmVault = requester;
        _poolKey = key;
        emit Registered(launchNumber_, requester);
    }
}
