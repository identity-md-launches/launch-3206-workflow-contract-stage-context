// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "../interfaces/IERC20.sol";
import {
    IV3PositionManager,
    ICLPositionManager,
    IPositionManagerCommon,
    IV3Factory,
    ICLFactory,
    IV3Pool
} from "../interfaces/IVenues.sol";
import {Position, KIND_CL} from "../interfaces/IFirm.sol";
import {FirmMath} from "../libraries/FirmMath.sol";

/// @title VenueV3 (LpDesk module): the V3 and CL (Aerodrome Slipstream) venue code.
/// @notice Callable only by LpDesk, except the swap callbacks, each answering only the pool of a swap this
/// module made. Positions are minted with LpDesk as recipient; every unused or received token goes back
/// to LpDesk (or to the buyback destination) in the same call; the module holds nothing between calls.
contract VenueV3 {
    uint160 internal constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
    uint160 internal constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

    address public immutable lpDesk;
    address internal _expectedPool;

    error NotLpDesk();
    error NotPool();
    error FeeTierDisabled();
    error NoPool();
    error TransferFailed();
    error BelowMinOut();
    error BadSlot0();

    modifier onlyLpDesk() {
        if (msg.sender != lpDesk) revert NotLpDesk();
        _;
    }

    constructor() {
        lpDesk = msg.sender;
    }

    // ---------------------------------------------------------------- views

    function notstock() public view returns (address) {
        return IPositionManagerToken(lpDesk).token();
    }

    function prepare(Position memory p) external view returns (Position memory) {
        address factory = IV3PositionManager(p.manager).factory();
        if (p.kind == KIND_CL) {
            p.fee = ICLFactory(factory).tickSpacingToFee(p.tickSpacing);
            if (p.fee == 0) revert FeeTierDisabled();
        } else {
            p.tickSpacing = IV3Factory(factory).feeAmountTickSpacing(p.fee);
            if (p.tickSpacing == 0) revert FeeTierDisabled();
        }
        return p;
    }

    function poolOf(Position memory p) public view returns (address pool) {
        address factory = IV3PositionManager(p.manager).factory();
        (address t0, address t1) = FirmMath.sort(notstock(), p.asset);
        pool = p.kind == KIND_CL
            ? ICLFactory(factory).getPool(t0, t1, p.tickSpacing)
            : IV3Factory(factory).getPool(t0, t1, p.fee);
    }

    function poolPrice(Position memory p) public view returns (uint160 sqrtPriceX96, bool exists) {
        address pool = poolOf(p);
        if (pool == address(0)) return (0, false);
        return (_slot0(pool), true);
    }

    function _slot0(address pool) internal view returns (uint160 sqrtPriceX96) {
        (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        if (!ok || data.length < 64) revert BadSlot0();
        sqrtPriceX96 = abi.decode(data, (uint160));
    }

    function quote(Position memory p, uint160 sqrtPriceX96, uint256 amount, bool amountIsAsset)
        external
        view
        returns (uint256 amountNotstock, uint256 amountAsset, uint128 liquidity)
    {
        return _quote(p, sqrtPriceX96, amount, amountIsAsset, notstock());
    }

    function _quote(Position memory p, uint160 sqrtP, uint256 amount, bool amountIsAsset, address not_)
        internal
        pure
        returns (uint256 amountNotstock, uint256 amountAsset, uint128 liquidity)
    {
        uint160 sqrtA = FirmMath.getSqrtRatioAtTick(p.tickLower);
        uint160 sqrtB = FirmMath.getSqrtRatioAtTick(p.tickUpper);
        bool notIs0 = not_ < p.asset;
        bool amountIs0 = notIs0 != amountIsAsset;
        if (amountIs0) {
            if (sqrtP >= sqrtB) return (0, 0, 0);
            liquidity = FirmMath.getLiquidityForAmount0(sqrtP > sqrtA ? sqrtP : sqrtA, sqrtB, amount);
        } else {
            if (sqrtP <= sqrtA) return (0, 0, 0);
            liquidity = FirmMath.getLiquidityForAmount1(sqrtA, sqrtP < sqrtB ? sqrtP : sqrtB, amount);
        }
        (uint256 a0, uint256 a1) = FirmMath.getAmountsForLiquidity(sqrtP, sqrtA, sqrtB, liquidity);
        (amountNotstock, amountAsset) = notIs0 ? (a0, a1) : (a1, a0);
    }

    function liquidityOf(Position memory p) external view returns (uint128) {
        (bool ok, bytes memory data) = p.manager.staticcall(abi.encodeWithSignature("positions(uint256)", p.tokenId));
        if (!ok || data.length < 12 * 32) return 0;
        (,,,,,,, uint128 liquidity,,,,) = abi.decode(
            data,
            (uint96, address, address, address, uint256, int24, int24, uint128, uint256, uint256, uint128, uint128)
        );
        return liquidity;
    }

    // ---------------------------------------------------------------- LpDesk-only actions

    function mint(Position memory p, uint160 sqrtPriceX96, uint128, uint256 amountNotstock, uint256 amountAsset)
        external
        onlyLpDesk
        returns (uint256 tokenId)
    {
        address not_ = notstock();
        (address t0, address t1) = FirmMath.sort(not_, p.asset);
        (uint256 a0, uint256 a1) = not_ < p.asset ? (amountNotstock, amountAsset) : (amountAsset, amountNotstock);
        _approve(t0, p.manager, a0);
        _approve(t1, p.manager, a1);
        if (p.kind == KIND_CL) {
            // Slipstream's mint creates the pool whenever sqrtPriceX96 != 0, and creating an existing pool
            // reverts; so the price is passed only to create a missing pool, and 0 on an existing one.
            uint160 createAt = poolOf(p) == address(0) ? sqrtPriceX96 : 0;
            (tokenId,,,) = ICLPositionManager(p.manager)
                .mint(
                    ICLPositionManager.MintParams({
                        token0: t0,
                        token1: t1,
                        tickSpacing: p.tickSpacing,
                        tickLower: p.tickLower,
                        tickUpper: p.tickUpper,
                        amount0Desired: a0,
                        amount1Desired: a1,
                        amount0Min: 0,
                        amount1Min: 0,
                        recipient: lpDesk,
                        deadline: block.timestamp,
                        sqrtPriceX96: createAt
                    })
                );
        } else {
            IV3PositionManager(p.manager).createAndInitializePoolIfNecessary(t0, t1, p.fee, sqrtPriceX96);
            (tokenId,,,) = IV3PositionManager(p.manager)
                .mint(
                    IV3PositionManager.MintParams({
                        token0: t0,
                        token1: t1,
                        fee: p.fee,
                        tickLower: p.tickLower,
                        tickUpper: p.tickUpper,
                        amount0Desired: a0,
                        amount1Desired: a1,
                        amount0Min: 0,
                        amount1Min: 0,
                        recipient: lpDesk,
                        deadline: block.timestamp
                    })
                );
        }
        _returnAll(t0, t1, p.manager);
    }

    function increase(Position memory p, uint128, uint256 amountNotstock, uint256 amountAsset)
        external
        onlyLpDesk
        returns (uint128 added)
    {
        address not_ = notstock();
        (address t0, address t1) = FirmMath.sort(not_, p.asset);
        (uint256 a0, uint256 a1) = not_ < p.asset ? (amountNotstock, amountAsset) : (amountAsset, amountNotstock);
        _approve(t0, p.manager, a0);
        _approve(t1, p.manager, a1);
        (added,,) = IPositionManagerCommon(p.manager)
            .increaseLiquidity(
                IPositionManagerCommon.IncreaseLiquidityParams({
                    tokenId: p.tokenId,
                    amount0Desired: a0,
                    amount1Desired: a1,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
        _returnAll(t0, t1, p.manager);
    }

    function collect(Position memory p) external onlyLpDesk {
        IPositionManagerCommon(p.manager)
            .collect(
                IPositionManagerCommon.CollectParams({
                    tokenId: p.tokenId, recipient: lpDesk, amount0Max: type(uint128).max, amount1Max: type(uint128).max
                })
            );
    }

    function decrease(Position memory p, uint128 liquidity, uint256 min0, uint256 min1) external onlyLpDesk {
        IPositionManagerCommon(p.manager)
            .decreaseLiquidity(
                IPositionManagerCommon.DecreaseLiquidityParams({
                    tokenId: p.tokenId,
                    liquidity: liquidity,
                    amount0Min: min0,
                    amount1Min: min1,
                    deadline: block.timestamp
                })
            );
        IPositionManagerCommon(p.manager)
            .collect(
                IPositionManagerCommon.CollectParams({
                    tokenId: p.tokenId, recipient: lpDesk, amount0Max: type(uint128).max, amount1Max: type(uint128).max
                })
            );
    }

    function burnPosition(Position memory p) external onlyLpDesk {
        IPositionManagerCommon(p.manager).burn(p.tokenId);
    }

    /// @notice Exact-input swap in the position's pool; the output goes to `to` (the dead address for buybacks).
    function swapExactIn(Position memory p, address tokenIn, uint256 amountIn, uint256 minOut, address to)
        external
        onlyLpDesk
        returns (uint256 amountOut)
    {
        address pool = poolOf(p);
        if (pool == address(0)) revert NoPool();
        (address t0,) = FirmMath.sort(notstock(), p.asset);
        bool zeroForOne = tokenIn == t0;
        _expectedPool = pool;
        (int256 d0, int256 d1) = IV3Pool(pool)
            .swap(to, zeroForOne, int256(amountIn), zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE, "");
        _expectedPool = address(0);
        amountOut = uint256(-(zeroForOne ? d1 : d0));
        if (amountOut < minOut) revert BelowMinOut();
        // Any unspent input (a partial fill at the price limit) goes back to LpDesk.
        uint256 rest = IERC20(tokenIn).balanceOf(address(this));
        if (rest > 0) _send(tokenIn, lpDesk, rest);
    }

    // ---------------------------------------------------------------- swap callbacks

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        _pay(amount0Delta, amount1Delta);
    }

    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        _pay(amount0Delta, amount1Delta);
    }

    function _pay(int256 amount0Delta, int256 amount1Delta) internal {
        address pool = _expectedPool;
        if (pool == address(0) || msg.sender != pool) revert NotPool();
        (bool ok0, bytes memory d0) = pool.staticcall(abi.encodeWithSignature("token0()"));
        (bool ok1, bytes memory d1) = pool.staticcall(abi.encodeWithSignature("token1()"));
        if (!ok0 || !ok1) revert NotPool();
        if (amount0Delta > 0) _send(abi.decode(d0, (address)), pool, uint256(amount0Delta));
        if (amount1Delta > 0) _send(abi.decode(d1, (address)), pool, uint256(amount1Delta));
    }

    // ---------------------------------------------------------------- internals

    function _returnAll(address t0, address t1, address manager) internal {
        _approve(t0, manager, 0);
        _approve(t1, manager, 0);
        uint256 b0 = IERC20(t0).balanceOf(address(this));
        uint256 b1 = IERC20(t1).balanceOf(address(this));
        if (b0 > 0) _send(t0, lpDesk, b0);
        if (b1 > 0) _send(t1, lpDesk, b1);
    }

    function _approve(address t, address spender, uint256 amount) internal {
        if (!IERC20(t).approve(spender, amount)) revert TransferFailed();
    }

    function _send(address t, address to, uint256 amount) internal {
        if (!IERC20(t).transfer(to, amount)) revert TransferFailed();
    }
}

interface IPositionManagerToken {
    function token() external view returns (address);
}
