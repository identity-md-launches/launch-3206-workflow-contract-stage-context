// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "../interfaces/IERC20.sol";
import {PoolKey, IV4PoolManager, IV4PositionManager, IPermit2} from "../interfaces/IVenues.sol";
import {Position, ILpDesk} from "../interfaces/IFirm.sol";
import {FirmMath} from "../libraries/FirmMath.sol";

/// @title VenueV4 (LpDesk module): the Uniswap v4 venue code and the swap code of both buybacks.
/// @notice Callable only by LpDesk (position actions and LpDesk buybacks) and by FirmVault (its buyback in
/// the registered NOTSTOCK/IMD pool), plus unlockCallback answering only the PoolManager of a swap this
/// module started. Positions are minted with LpDesk as owner; the module holds nothing between calls.
contract VenueV4 {
    uint8 internal constant INCREASE_LIQUIDITY = 0x00;
    uint8 internal constant DECREASE_LIQUIDITY = 0x01;
    uint8 internal constant MINT_POSITION = 0x02;
    uint8 internal constant BURN_POSITION = 0x03;
    uint8 internal constant SETTLE_PAIR = 0x0d;
    uint8 internal constant TAKE_PAIR = 0x11;
    uint160 internal constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
    uint160 internal constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;
    uint256 internal constant POOLS_SLOT = 6;

    address public immutable lpDesk;
    address internal _expectedManager;

    error NotLpDesk();
    error NotAllowed();
    error NotPoolManager();
    error BelowMinOut();
    error TransferFailed();
    error NoPool();

    modifier onlyLpDesk() {
        if (msg.sender != lpDesk) revert NotLpDesk();
        _;
    }

    constructor() {
        lpDesk = msg.sender;
    }

    // ---------------------------------------------------------------- views

    function notstock() public view returns (address) {
        return ILpDesk(lpDesk).token();
    }

    function keyOf(Position memory p) public view returns (PoolKey memory key) {
        (address c0, address c1) = FirmMath.sort(notstock(), p.asset);
        key = PoolKey({currency0: c0, currency1: c1, fee: p.fee, tickSpacing: p.tickSpacing, hooks: address(0)});
    }

    function prepare(Position memory p) external pure returns (Position memory) {
        return p;
    }

    function poolPrice(Position memory p) public view returns (uint160 sqrtPriceX96, bool exists) {
        return _price(IV4PositionManager(p.manager).poolManager(), keyOf(p));
    }

    function _price(address poolManager, PoolKey memory key) internal view returns (uint160 sqrtPriceX96, bool exists) {
        bytes32 poolId = keccak256(abi.encode(key));
        bytes32 slot = keccak256(abi.encode(poolId, POOLS_SLOT));
        bytes32 data = IV4PoolManager(poolManager).extsload(slot);
        sqrtPriceX96 = uint160(uint256(data));
        exists = sqrtPriceX96 != 0;
    }

    function quote(Position memory p, uint160 sqrtP, uint256 amount, bool amountIsAsset)
        external
        view
        returns (uint256 amountNotstock, uint256 amountAsset, uint128 liquidity)
    {
        uint160 sqrtA = FirmMath.getSqrtRatioAtTick(p.tickLower);
        uint160 sqrtB = FirmMath.getSqrtRatioAtTick(p.tickUpper);
        bool notIs0 = notstock() < p.asset;
        bool amountIs0 = notIs0 != amountIsAsset;
        if (amountIs0) {
            if (sqrtP >= sqrtB) return (0, 0, 0);
            liquidity = FirmMath.getLiquidityForAmount0(sqrtP > sqrtA ? sqrtP : sqrtA, sqrtB, amount);
        } else {
            if (sqrtP <= sqrtA) return (0, 0, 0);
            liquidity = FirmMath.getLiquidityForAmount1(sqrtA, sqrtP < sqrtB ? sqrtP : sqrtB, amount);
        }
        (uint256 a0, uint256 a1) = FirmMath.getAmountsForLiquidity(sqrtP, sqrtA, sqrtB, liquidity);
        // The PositionManager rounds the amounts for `liquidity` up; one extra unit covers that.
        if (a0 > 0) a0 += 1;
        if (a1 > 0) a1 += 1;
        (amountNotstock, amountAsset) = notIs0 ? (a0, a1) : (a1, a0);
    }

    function liquidityOf(Position memory p) external view returns (uint128) {
        return IV4PositionManager(p.manager).getPositionLiquidity(p.tokenId);
    }

    // ---------------------------------------------------------------- LpDesk-only actions

    function mint(
        Position memory p,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint256 amountNotstock,
        uint256 amountAsset
    ) external onlyLpDesk returns (uint256 tokenId) {
        IV4PositionManager posm = IV4PositionManager(p.manager);
        PoolKey memory key = keyOf(p);
        (, bool exists) = _price(posm.poolManager(), key);
        if (!exists) posm.initializePool(key, sqrtPriceX96);
        (uint256 a0, uint256 a1) =
            key.currency0 == p.asset ? (amountAsset, amountNotstock) : (amountNotstock, amountAsset);
        _permit(posm, key.currency0);
        _permit(posm, key.currency1);
        tokenId = posm.nextTokenId();
        bytes memory actions = abi.encodePacked(MINT_POSITION, SETTLE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, p.tickLower, p.tickUpper, liquidity, a0, a1, lpDesk, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        _returnAll(key.currency0, key.currency1);
    }

    function increase(Position memory p, uint128 liquidity, uint256 amountNotstock, uint256 amountAsset)
        external
        onlyLpDesk
        returns (uint128 added)
    {
        IV4PositionManager posm = IV4PositionManager(p.manager);
        PoolKey memory key = keyOf(p);
        (uint256 a0, uint256 a1) =
            key.currency0 == p.asset ? (amountAsset, amountNotstock) : (amountNotstock, amountAsset);
        _permit(posm, key.currency0);
        _permit(posm, key.currency1);
        uint128 before = posm.getPositionLiquidity(p.tokenId);
        bytes memory actions = abi.encodePacked(INCREASE_LIQUIDITY, SETTLE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(p.tokenId, liquidity, a0, a1, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        added = posm.getPositionLiquidity(p.tokenId) - before;
        _returnAll(key.currency0, key.currency1);
    }

    function collect(Position memory p) external onlyLpDesk {
        _decrease(p, 0, 0, 0);
    }

    function decrease(Position memory p, uint128 liquidity, uint256 min0, uint256 min1) external onlyLpDesk {
        _decrease(p, liquidity, min0, min1);
    }

    function _decrease(Position memory p, uint128 liquidity, uint256 min0, uint256 min1) internal {
        PoolKey memory key = keyOf(p);
        bytes memory actions = abi.encodePacked(DECREASE_LIQUIDITY, TAKE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(p.tokenId, liquidity, min0, min1, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, lpDesk);
        IV4PositionManager(p.manager).modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function burnPosition(Position memory p) external onlyLpDesk {
        PoolKey memory key = keyOf(p);
        bytes memory actions = abi.encodePacked(BURN_POSITION, TAKE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(p.tokenId, uint256(0), uint256(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, lpDesk);
        IV4PositionManager(p.manager).modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    /// @notice LpDesk buyback in the position's own pool.
    function swapExactIn(Position memory p, address tokenIn, uint256 amountIn, uint256 minOut, address to)
        external
        onlyLpDesk
        returns (uint256 amountOut)
    {
        return _swap(IV4PositionManager(p.manager).poolManager(), keyOf(p), tokenIn, amountIn, minOut, to);
    }

    /// @notice FirmVault buyback in the registered NOTSTOCK/IMD pool (its key, hook included, from LpDesk's views).
    function swapExactInForVault(PoolKey calldata key, address tokenIn, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 amountOut)
    {
        if (msg.sender != ILpDesk(lpDesk).firmVault()) revert NotAllowed();
        address poolManager = IV4PositionManager(0x7C5f5A4bBd8fD63184577525326123B519429bDc).poolManager();
        return _swap(poolManager, key, tokenIn, amountIn, minOut, to);
    }

    function _swap(
        address poolManager,
        PoolKey memory key,
        address tokenIn,
        uint256 amountIn,
        uint256 minOut,
        address to
    ) internal returns (uint256 amountOut) {
        (, bool exists) = _price(poolManager, key);
        if (!exists) revert NoPool();
        _expectedManager = poolManager;
        bytes memory result = IV4PoolManager(poolManager).unlock(abi.encode(key, tokenIn, amountIn, to));
        _expectedManager = address(0);
        amountOut = abi.decode(result, (uint256));
        if (amountOut < minOut) revert BelowMinOut();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        address poolManager = _expectedManager;
        if (poolManager == address(0) || msg.sender != poolManager) revert NotPoolManager();
        (PoolKey memory key, address tokenIn, uint256 amountIn, address to) =
            abi.decode(data, (PoolKey, address, uint256, address));
        bool zeroForOne = tokenIn == key.currency0;
        int256 delta = IV4PoolManager(poolManager)
            .swap(
                key,
                IV4PoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(amountIn),
                    sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE
                }),
                ""
            );
        int128 amount0 = int128(delta >> 128);
        int128 amount1 = int128(delta);
        int128 inDelta = zeroForOne ? amount0 : amount1;
        int128 outDelta = zeroForOne ? amount1 : amount0;
        uint256 owed = uint256(uint128(-inDelta));
        IV4PoolManager(poolManager).sync(tokenIn);
        _send(tokenIn, poolManager, owed);
        IV4PoolManager(poolManager).settle();
        uint256 out = uint256(uint128(outDelta));
        IV4PoolManager(poolManager).take(zeroForOne ? key.currency1 : key.currency0, to, out);
        if (owed < amountIn) _send(tokenIn, lpDesk, amountIn - owed);
        return abi.encode(out);
    }

    // ---------------------------------------------------------------- internals

    function _permit(IV4PositionManager posm, address token) internal {
        address permit2 = posm.permit2();
        IERC20(token).approve(permit2, type(uint256).max);
        IPermit2(permit2).approve(token, address(posm), type(uint160).max, type(uint48).max);
    }

    function _returnAll(address c0, address c1) internal {
        uint256 b0 = IERC20(c0).balanceOf(address(this));
        uint256 b1 = IERC20(c1).balanceOf(address(this));
        if (b0 > 0) _send(c0, lpDesk, b0);
        if (b1 > 0) _send(c1, lpDesk, b1);
    }

    function _send(address t, address to, uint256 amount) internal {
        if (!IERC20(t).transfer(to, amount)) revert TransferFailed();
    }
}
