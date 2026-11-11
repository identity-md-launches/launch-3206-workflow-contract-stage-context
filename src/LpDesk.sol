// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {PoolKey, IOFT, IPositionManagerCommon} from "./interfaces/IVenues.sol";
import {
    Position,
    OpenParams,
    IVenueModule,
    IPriceGuard,
    KIND_V4,
    MODULE_LPGOVERNOR,
    MODULE_PRICEGUARD,
    MODULE_VENUEV3,
    MODULE_VENUEV4
} from "./interfaces/IFirm.sol";
import {Burner} from "./Burner.sol";
import {FirmMath} from "./libraries/FirmMath.sol";

interface IFirmVaultCredit {
    function creditFromLpDesk(uint256 amount) external;
}

/// @title LpDesk
/// @notice Holds the firm's NOTSTOCK and the assets its liquidity positions return. The operator opens
/// positions during the 7-day bootstrap and manages, closes, tops up, buys back and burns at any time;
/// after the bootstrap new positions need a passed, unvetoed LpGovernor proposal. Assets leave only into
/// positions on listed venues, as the fixed fee split, by buyback() to the dead address, by burn() and
/// by an executed BridgeOut. No owner, pause or upgrade.
contract LpDesk {
    // ---------------------------------------------------------------- constants
    address public constant IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant BOOTSTRAP_SECONDS = 604_800;
    uint256 public constant PRICE_TOLERANCE_BPS = 50; // 0.5%
    uint256 public constant MIN_BPS = 9_950; // 99.5%

    /// @dev keccak256(type(Module).creationCode) of every module (README "Contracts" says how they are recomputed).
    bytes32 public constant LPGOVERNOR_CODE_HASH = 0x0fc46e72ec8b2bcdf990b19aa94fa75b36772ba3760f759310a8c124896bec92;
    bytes32 public constant PRICEGUARD_CODE_HASH = 0xd7cbfc1e3a02e71d5d069f3a6c86379cfc5e71fb9f944dc09fa25266b28f606d;
    bytes32 public constant VENUEV3_CODE_HASH = 0x4728bed9169bb2058437c604cd5cc8ba12f224b15b162b6aed33e0b5f0569aa6;
    bytes32 public constant VENUEV4_CODE_HASH = 0xf3b9ae535cff2be3df93543e093219876fd10175986b1e50e5b56c3179f569e6;

    // ---------------------------------------------------------------- immutables
    address public immutable token;
    address public immutable launchFactory;
    address public immutable burner;
    address public immutable projectWallet;
    address public immutable lpGovernor;
    address public immutable priceGuard;
    address public immutable venueV3;
    address public immutable venueV4;

    // ---------------------------------------------------------------- state
    address public operator;
    mapping(address => uint256) public topUpBasket;
    mapping(address => uint256) public buybackBasket;
    mapping(address => bool) public managerApproved;
    Position[] internal _positions;

    // ---------------------------------------------------------------- events
    event OperatorChanged(address indexed previous, address indexed next);
    event ModuleDeployed(bytes32 indexed kind, address module);
    event PositionOpened(uint256 indexed id, address indexed venue, address indexed asset, uint256 tokenId);
    event PositionClosed(uint256 indexed id);
    event PositionShifted(uint256 indexed id, uint256 indexed newId);
    event FeesSplit(address indexed token, uint256 collected);
    event ToppedUp(uint256 indexed id, uint256 used, uint128 liquidity);
    event Buyback(uint256 indexed id, uint256 amountIn, uint256 notstockOut);
    event Burned(uint256 amount);
    event Credited(uint256 amount);
    event BridgedOut(address indexed adapter, uint32 dstEid, address dstLpDesk, uint256 amount);

    // ---------------------------------------------------------------- errors
    error NotOperator();
    error NotGovernor();
    error NotFirmVault();
    error ModuleMissing();
    error UnknownModule();
    error WrongModuleCode();
    error ModuleExists();
    error NotRegistered();
    error BootstrapOver();
    error UnlistedAsset();
    error UnlistedVenue();
    error PriceMoved();
    error MinTooLow();
    error BelowMinimum();
    error AboveFree();
    error AboveBasket();
    error NeedsNotstock();
    error NothingTaken();
    error PositionClosedError();
    error AssetMismatch();
    error ImdNotBuyable();
    error TransferFailed();
    error ZeroAddress();
    error NotLocked();

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    constructor(address token_, address operator_, address projectWallet_) {
        if (token_ == address(0) || operator_ == address(0) || projectWallet_ == address(0)) revert ZeroAddress();
        token = token_;
        operator = operator_;
        projectWallet = projectWallet_;
        launchFactory = msg.sender;
        burner = address(new Burner(address(this)));
        lpGovernor = _predict(MODULE_LPGOVERNOR, LPGOVERNOR_CODE_HASH);
        priceGuard = _predict(MODULE_PRICEGUARD, PRICEGUARD_CODE_HASH);
        venueV3 = _predict(MODULE_VENUEV3, VENUEV3_CODE_HASH);
        venueV4 = _predict(MODULE_VENUEV4, VENUEV4_CODE_HASH);
    }

    // ================================================================ modules

    function moduleCodeHash(bytes32 kind) public pure returns (bytes32) {
        if (kind == MODULE_LPGOVERNOR) return LPGOVERNOR_CODE_HASH;
        if (kind == MODULE_PRICEGUARD) return PRICEGUARD_CODE_HASH;
        if (kind == MODULE_VENUEV3) return VENUEV3_CODE_HASH;
        if (kind == MODULE_VENUEV4) return VENUEV4_CODE_HASH;
        revert UnknownModule();
    }

    function moduleAddress(bytes32 kind) public view returns (address) {
        if (kind == MODULE_LPGOVERNOR) return lpGovernor;
        if (kind == MODULE_PRICEGUARD) return priceGuard;
        if (kind == MODULE_VENUEV3) return venueV3;
        if (kind == MODULE_VENUEV4) return venueV4;
        revert UnknownModule();
    }

    function isModuleDeployed(bytes32 kind) public view returns (bool) {
        return moduleAddress(kind).code.length > 0;
    }

    /// @notice Anyone deploys a module once, by CREATE2 with salt = kind, from its exact creation code.
    function deployModule(bytes32 kind, bytes memory creationCode) external returns (address deployed) {
        if (keccak256(creationCode) != moduleCodeHash(kind)) revert WrongModuleCode();
        address predicted = moduleAddress(kind);
        if (predicted.code.length > 0) revert ModuleExists();
        assembly ("memory-safe") {
            deployed := create2(0, add(creationCode, 32), mload(creationCode), kind)
        }
        if (deployed != predicted) revert WrongModuleCode();
        emit ModuleDeployed(kind, deployed);
    }

    function _predict(bytes32 salt, bytes32 codeHash) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash)))));
    }

    function _guard() internal view returns (IPriceGuard g) {
        if (priceGuard.code.length == 0) revert ModuleMissing();
        g = IPriceGuard(priceGuard);
    }

    function _module(uint8 kind) internal view returns (IVenueModule m) {
        address a = kind == KIND_V4 ? venueV4 : venueV3;
        if (a.code.length == 0) revert ModuleMissing();
        m = IVenueModule(a);
    }

    // ================================================================ views

    function registered() public view returns (bool) {
        return priceGuard.code.length > 0 && IPriceGuard(priceGuard).registered();
    }

    function registeredPoolKey() external view returns (PoolKey memory) {
        return _guard().poolKey();
    }

    function firmVault() public view returns (address) {
        return _guard().firmVault();
    }

    function bootstrapEnd() public view returns (uint256) {
        if (!registered()) return 0;
        return uint256(IPriceGuard(priceGuard).registeredAt()) + BOOTSTRAP_SECONDS;
    }

    /// @notice Balance outside positions and baskets. NOTSTOCK has no baskets: its free balance is the whole balance.
    function freeBalance(address t) public view returns (uint256) {
        uint256 bal = IERC20(t).balanceOf(address(this));
        uint256 reserved = topUpBasket[t] + buybackBasket[t];
        return bal > reserved ? bal - reserved : 0;
    }

    function positionCount() external view returns (uint256) {
        return _positions.length;
    }

    function position(uint256 id) external view returns (Position memory) {
        return _positions[id];
    }

    function positions() external view returns (Position[] memory) {
        return _positions;
    }

    function positionLiquidity(uint256 id) external view returns (uint128) {
        Position memory p = _positions[id];
        if (!p.open) return 0;
        return _module(p.kind).liquidityOf(p);
    }

    // ================================================================ operator

    function setOperator(address next) external onlyOperator {
        if (next == address(0)) revert ZeroAddress();
        emit OperatorChanged(operator, next);
        operator = next;
    }

    /// @notice Direct open by the operator, only during the bootstrap window.
    function open(OpenParams calldata p) external onlyOperator returns (uint256) {
        uint256 end = bootstrapEnd();
        if (end == 0) revert NotRegistered();
        if (block.timestamp >= end) revert BootstrapOver();
        return _open(p, false);
    }

    /// @notice Open by an executed OpenPosition proposal; minimums are set to exactly 99.5% of the quoted amounts.
    function openFromGovernor(OpenParams calldata p) external returns (uint256) {
        if (msg.sender != lpGovernor) revert NotGovernor();
        if (!registered()) revert NotRegistered();
        return _open(p, true);
    }

    function _open(OpenParams calldata p, bool autoMin) internal returns (uint256 id) {
        IPriceGuard g = _guard();
        if (!g.isAsset(p.asset)) revert UnlistedAsset();
        (bool listed, uint8 kind) = g.venueKind(p.venue);
        if (!listed) revert UnlistedVenue();
        IVenueModule m = _module(kind);
        Position memory pos = m.prepare(
            Position({
                manager: p.venue,
                kind: kind,
                asset: p.asset,
                fee: p.fee,
                tickSpacing: p.tickSpacing,
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                tokenId: 0,
                open: true
            })
        );
        (uint160 current, bool exists) = m.poolPrice(pos);
        if (exists && !_within(current, p.sqrtPriceX96)) revert PriceMoved();
        // An existing pool is quoted and minted at its own price (within 0.5% of the given one); a new pool
        // is created at the given price.
        uint160 at = exists ? current : p.sqrtPriceX96;
        (uint256 amountNot, uint256 amountAsset, uint128 liquidity) = m.quote(pos, at, p.amount, false);
        if (amountNot == 0 || liquidity == 0) revert NeedsNotstock();
        if (amountNot > freeBalance(token)) revert AboveFree();
        if (amountAsset > freeBalance(p.asset)) revert AboveFree();
        (uint256 min0, uint256 min1) = _sortedMins(pos, amountNot, amountAsset, p.amount0Min, p.amount1Min, autoMin);
        _approveManager(pos.manager, address(m));
        _push(token, address(m), amountNot);
        _push(p.asset, address(m), amountAsset);
        uint256 notBefore = IERC20(token).balanceOf(address(this));
        uint256 assetBefore = IERC20(p.asset).balanceOf(address(this));
        pos.tokenId = m.mint(pos, at, liquidity, amountNot, amountAsset);
        _checkUsed(pos, amountNot, amountAsset, notBefore, assetBefore, min0, min1);
        id = _positions.length;
        _positions.push(pos);
        emit PositionOpened(id, p.venue, p.asset, pos.tokenId);
    }

    /// @notice Collects the position's owed fees and splits them (NOTSTOCK to Burner, other 25/25/25/25).
    function collect(uint256 id) external onlyOperator {
        Position memory pos = _openPosition(id);
        _collectAndSplit(pos);
    }

    /// @notice Closes a position: fees collected and split first, every other withdrawn amount to free balance.
    function close(uint256 id, uint256 min0, uint256 min1) external onlyOperator {
        Position memory pos = _openPosition(id);
        _collectAndSplit(pos);
        _withdrawAll(pos, min0, min1);
        _positions[id].open = false;
        emit PositionClosed(id);
    }

    /// @notice Moves the position to a new tick range: fees split, all liquidity withdrawn (at least the
    /// withdrawal minimums), then as much of the withdrawn amounts as the new range takes is re-deposited
    /// (at least the deposit minimums) into a new position with the same venue, pair and fee tier.
    function shift(
        uint256 id,
        int24 newLower,
        int24 newUpper,
        uint256 out0Min,
        uint256 out1Min,
        uint256 dep0Min,
        uint256 dep1Min
    ) external onlyOperator returns (uint256 newId) {
        Position memory pos = _openPosition(id);
        _collectAndSplit(pos);
        (uint256 w0, uint256 w1) = _withdrawAll(pos, out0Min, out1Min);
        _positions[id].open = false;
        pos.tickLower = newLower;
        pos.tickUpper = newUpper;
        pos.tokenId = 0;
        IVenueModule m = _module(pos.kind);
        (uint160 current,) = m.poolPrice(pos);
        (uint256 wNot, uint256 wAsset) = token < pos.asset ? (w0, w1) : (w1, w0);
        (uint256 amountNot, uint256 amountAsset, uint128 liquidity) = _fitBoth(m, pos, current, wNot, wAsset);
        if (liquidity == 0) revert NothingTaken();
        _push(token, address(m), amountNot);
        _push(pos.asset, address(m), amountAsset);
        uint256 notBefore = IERC20(token).balanceOf(address(this));
        uint256 assetBefore = IERC20(pos.asset).balanceOf(address(this));
        pos.tokenId = m.mint(pos, current, liquidity, amountNot, amountAsset);
        _checkUsed(pos, amountNot, amountAsset, notBefore, assetBefore, dep0Min, dep1Min);
        newId = _positions.length;
        _positions.push(pos);
        emit PositionShifted(id, newId);
    }

    /// @notice Moves `liquidity` from one open position into another with the same asset: fees of both
    /// split first, the withdrawn amounts (at least the withdrawal minimums) re-deposited into `to` as far
    /// as its range takes them (at least the deposit minimums); the rest stays free.
    function moveLiquidity(
        uint256 fromId,
        uint256 toId,
        uint128 liquidity,
        uint256 out0Min,
        uint256 out1Min,
        uint256 dep0Min,
        uint256 dep1Min
    ) external onlyOperator {
        Position memory from = _openPosition(fromId);
        Position memory to = _openPosition(toId);
        if (from.asset != to.asset || fromId == toId) revert AssetMismatch();
        _collectAndSplit(from);
        _collectAndSplit(to);
        IVenueModule mf = _module(from.kind);
        uint256 notBefore = IERC20(token).balanceOf(address(this));
        uint256 assetBefore = IERC20(from.asset).balanceOf(address(this));
        mf.decrease(from, liquidity, out0Min, out1Min);
        uint256 wNot = IERC20(token).balanceOf(address(this)) - notBefore;
        uint256 wAsset = IERC20(from.asset).balanceOf(address(this)) - assetBefore;
        _checkMins(from, wNot, wAsset, out0Min, out1Min);
        IVenueModule mt = _module(to.kind);
        (uint160 current,) = mt.poolPrice(to);
        (uint256 amountNot, uint256 amountAsset, uint128 liq) = _fitBoth(mt, to, current, wNot, wAsset);
        if (liq == 0) revert NothingTaken();
        _approveManager(to.manager, address(mt));
        _push(token, address(mt), amountNot);
        _push(to.asset, address(mt), amountAsset);
        notBefore = IERC20(token).balanceOf(address(this));
        assetBefore = IERC20(to.asset).balanceOf(address(this));
        mt.increase(to, liq, amountNot, amountAsset);
        _checkUsed(to, amountNot, amountAsset, notBefore, assetBefore, dep0Min, dep1Min);
    }

    /// @notice Adds up to `amount` of the position's asset from its top-up basket; takes no NOTSTOCK.
    function increaseLiquidity(uint256 id, uint256 amount, uint160 sqrtPriceX96, uint128 minLiquidity)
        external
        onlyOperator
    {
        Position memory pos = _openPosition(id);
        // Owed fees are collected and split first, so the venue never nets them into the top-up.
        _collectAndSplit(pos);
        if (amount > topUpBasket[pos.asset]) revert AboveBasket();
        IVenueModule m = _module(pos.kind);
        (uint160 current,) = m.poolPrice(pos);
        if (!_within(current, sqrtPriceX96)) revert PriceMoved();
        (uint256 amountNot, uint256 amountAsset, uint128 liquidity) = m.quote(pos, current, amount, true);
        if (amountNot != 0) revert NeedsNotstock();
        if (liquidity == 0 || amountAsset == 0) revert NothingTaken();
        if (uint256(minLiquidity) < uint256(liquidity) * MIN_BPS / 10_000) revert MinTooLow();
        _approveManager(pos.manager, address(m));
        _push(pos.asset, address(m), amountAsset);
        uint256 before = IERC20(pos.asset).balanceOf(address(this));
        uint128 added = m.increase(pos, liquidity, 0, amountAsset);
        uint256 used = amountAsset - (IERC20(pos.asset).balanceOf(address(this)) - before);
        if (added < minLiquidity || used > amount) revert BelowMinimum();
        topUpBasket[pos.asset] -= used;
        emit ToppedUp(id, used, added);
    }

    /// @notice Swaps `amount` of the position's asset from its buyback basket for NOTSTOCK in the position's
    /// own pool and sends every NOTSTOCK received to the dead address. minOut is the operator's manual bound.
    function buyback(uint256 id, uint256 amount, uint256 minOut) external onlyOperator {
        Position memory pos = _openPosition(id);
        if (pos.asset == IMD) revert ImdNotBuyable();
        if (amount > buybackBasket[pos.asset]) revert AboveBasket();
        IVenueModule m = _module(pos.kind);
        _push(pos.asset, address(m), amount);
        uint256 before = IERC20(pos.asset).balanceOf(address(this));
        uint256 out = m.swapExactIn(pos, pos.asset, amount, minOut, DEAD);
        // A partial fill (the pool ran out of liquidity at the price limit) returns the unspent input;
        // only what the swap consumed leaves the buyback basket, the rest stays in it.
        uint256 spent = amount - (IERC20(pos.asset).balanceOf(address(this)) - before);
        buybackBasket[pos.asset] -= spent;
        emit Buyback(id, spent, out);
    }

    /// @notice Sends `amount` of free NOTSTOCK to the dead address.
    function burn(uint256 amount) external onlyOperator {
        if (amount > freeBalance(token)) revert AboveFree();
        _push(token, DEAD, amount);
        emit Burned(amount);
    }

    // ================================================================ FirmVault and governance entry points

    /// @notice FirmVault credits the IMD it just transferred: half to the top-up basket, half free.
    function creditFromFirmVault(uint256 amount) external {
        if (msg.sender != firmVault()) revert NotFirmVault();
        topUpBasket[IMD] += amount / 2;
        emit Credited(amount);
    }

    function addAsset(address asset) external {
        if (msg.sender != lpGovernor) revert NotGovernor();
        _guard().addAsset(asset);
    }

    function addVenue(address manager, uint8 kind) external {
        if (msg.sender != lpGovernor) revert NotGovernor();
        _guard().addVenue(manager, kind);
    }

    /// @notice Executed BridgeOut: approves exactly `amount` of free NOTSTOCK to the adapter, sends it to the
    /// record's destination LpDesk and resets the approval. The caller's msg.value pays the messaging fee.
    function bridgeOut(address adapter, uint32 dstEid, address dstLpDesk, uint256 amount, address refund)
        external
        payable
    {
        if (msg.sender != lpGovernor) revert NotGovernor();
        if (amount > freeBalance(token)) revert AboveFree();
        uint256 deskBefore = IERC20(token).balanceOf(address(this));
        uint256 lockedBefore = IERC20(token).balanceOf(adapter);
        IERC20(token).approve(adapter, amount);
        IOFT(adapter).send{value: msg.value}(
            IOFT.SendParam({
                dstEid: dstEid,
                to: bytes32(uint256(uint160(dstLpDesk))),
                amountLD: amount,
                minAmountLD: amount,
                extraOptions: "",
                composeMsg: "",
                oftCmd: ""
            }),
            IOFT.MessagingFee({nativeFee: msg.value, lzTokenFee: 0}),
            refund
        );
        IERC20(token).approve(adapter, 0);
        // NOTSTOCK has a fixed supply, so its OFT on Base is a lockbox adapter: send() must lock exactly
        // `amount` in the adapter itself. Anything else (tokens pulled to another address) reverts.
        if (
            deskBefore - IERC20(token).balanceOf(address(this)) != amount
                || IERC20(token).balanceOf(adapter) - lockedBefore != amount
        ) revert NotLocked();
        emit BridgedOut(adapter, dstEid, dstLpDesk, amount);
    }

    // ================================================================ internals

    function _openPosition(uint256 id) internal view returns (Position memory pos) {
        pos = _positions[id];
        if (!pos.open) revert PositionClosedError();
    }

    /// @dev True when the price (sqrtPrice squared) of `actual` is within 0.5% of the price of `ref`, in
    /// either direction. The square-root ratio r = actual/ref is taken in Q96, and r^2 is compared.
    function _within(uint256 actual, uint256 ref) internal pure returns (bool) {
        if (ref == 0) return false;
        uint256 q96 = 1 << 96;
        uint256 r = FirmMath.mulDiv(actual, q96, ref);
        if (r > 2 * q96) return false;
        uint256 ratio = FirmMath.mulDiv(r, r, q96);
        return ratio * 10_000 <= q96 * (10_000 + PRICE_TOLERANCE_BPS)
            && ratio * 10_000 >= q96 * (10_000 - PRICE_TOLERANCE_BPS);
    }

    /// @dev Withdraws all liquidity to free balance, checks the operator's minimum outs, burns the NFT.
    function _withdrawAll(Position memory pos, uint256 min0, uint256 min1) internal returns (uint256 w0, uint256 w1) {
        IVenueModule m = _module(pos.kind);
        uint128 liquidity = m.liquidityOf(pos);
        uint256 notBefore = IERC20(token).balanceOf(address(this));
        uint256 assetBefore = IERC20(pos.asset).balanceOf(address(this));
        if (liquidity > 0) m.decrease(pos, liquidity, min0, min1);
        m.burnPosition(pos);
        uint256 wNot = IERC20(token).balanceOf(address(this)) - notBefore;
        uint256 wAsset = IERC20(pos.asset).balanceOf(address(this)) - assetBefore;
        _checkMins(pos, wNot, wAsset, min0, min1);
        (w0, w1) = token < pos.asset ? (wNot, wAsset) : (wAsset, wNot);
    }

    function _checkMins(Position memory pos, uint256 gotNot, uint256 gotAsset, uint256 min0, uint256 min1)
        internal
        view
    {
        (uint256 got0, uint256 got1) = token < pos.asset ? (gotNot, gotAsset) : (gotAsset, gotNot);
        if (got0 < min0 || got1 < min1) revert BelowMinimum();
    }

    /// @dev Checks what the venue took against the minimums (used = pushed - returned).
    function _checkUsed(
        Position memory pos,
        uint256 pushedNot,
        uint256 pushedAsset,
        uint256 notBefore,
        uint256 assetBefore,
        uint256 min0,
        uint256 min1
    ) internal view {
        uint256 usedNot = pushedNot - (IERC20(token).balanceOf(address(this)) - notBefore);
        uint256 usedAsset = pushedAsset - (IERC20(pos.asset).balanceOf(address(this)) - assetBefore);
        _checkMins(pos, usedNot, usedAsset, min0, min1);
    }

    /// @dev Operator minimums must be at least 99.5% of the quoted amounts; a governor open sets exactly that.
    function _sortedMins(
        Position memory pos,
        uint256 amountNot,
        uint256 amountAsset,
        uint256 min0,
        uint256 min1,
        bool autoMin
    ) internal view returns (uint256, uint256) {
        (uint256 q0, uint256 q1) = token < pos.asset ? (amountNot, amountAsset) : (amountAsset, amountNot);
        uint256 floor0 = q0 * MIN_BPS / 10_000;
        uint256 floor1 = q1 * MIN_BPS / 10_000;
        if (autoMin) return (floor0, floor1);
        if (min0 < floor0 || min1 < floor1) revert MinTooLow();
        return (min0, min1);
    }

    /// @dev The largest liquidity the range takes at `price` from both withdrawn amounts.
    function _fitBoth(IVenueModule m, Position memory pos, uint160 price, uint256 haveNot, uint256 haveAsset)
        internal
        view
        returns (uint256 amountNot, uint256 amountAsset, uint128 liquidity)
    {
        uint256 n;
        uint256 a;
        uint128 l;
        if (haveNot > 0) {
            (n, a, l) = m.quote(pos, price, haveNot, false);
            if (l > 0 && a <= haveAsset) return (n, a, l);
        }
        if (haveAsset > 0) {
            (n, a, l) = m.quote(pos, price, haveAsset, true);
            if (l > 0 && n <= haveNot) return (n, a, l);
        }
        return (0, 0, 0);
    }

    function _collectAndSplit(Position memory pos) internal {
        uint256 notBefore = IERC20(token).balanceOf(address(this));
        uint256 assetBefore = IERC20(pos.asset).balanceOf(address(this));
        _module(pos.kind).collect(pos);
        uint256 gotNot = IERC20(token).balanceOf(address(this)) - notBefore;
        uint256 gotAsset = IERC20(pos.asset).balanceOf(address(this)) - assetBefore;
        if (gotNot > 0) {
            _push(token, burner, gotNot);
            emit FeesSplit(token, gotNot);
        }
        if (gotAsset > 0) {
            uint256 quarter = gotAsset / 4;
            if (pos.asset == IMD) {
                address vault = firmVault();
                uint256 before = IERC20(IMD).balanceOf(vault);
                _push(IMD, vault, quarter);
                IFirmVaultCredit(vault).creditFromLpDesk(IERC20(IMD).balanceOf(vault) - before);
            } else {
                buybackBasket[pos.asset] += quarter;
            }
            _push(pos.asset, projectWallet, quarter);
            topUpBasket[pos.asset] += quarter;
            emit FeesSplit(pos.asset, gotAsset);
        }
    }

    function _approveManager(address manager, address module) internal {
        if (!managerApproved[manager]) {
            managerApproved[manager] = true;
            IPositionManagerCommon(manager).setApprovalForAll(module, true);
        }
    }

    function _push(address t, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (!IERC20(t).transfer(to, amount)) revert TransferFailed();
    }
}
