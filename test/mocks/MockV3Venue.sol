// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IV3PositionManager, ICLPositionManager, IPositionManagerCommon} from "../../src/interfaces/IVenues.sol";
import {FirmMath} from "../../src/libraries/FirmMath.sol";

interface ISwapCallback {
    function uniswapV3SwapCallback(int256, int256, bytes calldata) external;
    function pancakeV3SwapCallback(int256, int256, bytes calldata) external;
}

/// @dev A fixed-price pool: slot0 price, token order, and an exact-input swap at that price less a 1% fee
/// paid through the V3 swap callback (or the PancakeSwap one when `pancake` is set).
contract MockV3Pool {
    address public token0;
    address public token1;
    uint160 public sqrtPriceX96;
    bool public pancake;
    uint256 public constant FEE_BPS = 100;

    constructor(address t0, address t1, uint160 price, bool pancake_) {
        token0 = t0;
        token1 = t1;
        sqrtPriceX96 = price;
        pancake = pancake_;
    }

    function setPrice(uint160 price) external {
        sqrtPriceX96 = price;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function quoteOut(bool zeroForOne, uint256 amountIn) public view returns (uint256 out) {
        uint256 p = FirmMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96); // price1/0 * 2^96
        out = zeroForOne ? FirmMath.mulDiv(amountIn, p, 1 << 96) : FirmMath.mulDiv(amountIn, 1 << 96, p);
        out = out * (10_000 - FEE_BPS) / 10_000;
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified > 0, "exact in only");
        uint256 amountIn = uint256(amountSpecified);
        uint256 out = quoteOut(zeroForOne, amountIn);
        (address tIn, address tOut) = zeroForOne ? (token0, token1) : (token1, token0);
        uint256 before = IERC20(tIn).balanceOf(address(this));
        require(IERC20(tOut).transfer(recipient, out), "out");
        (amount0, amount1) = zeroForOne ? (int256(amountIn), -int256(out)) : (-int256(out), int256(amountIn));
        if (pancake) ISwapCallback(msg.sender).pancakeV3SwapCallback(amount0, amount1, data);
        else ISwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(IERC20(tIn).balanceOf(address(this)) >= before + amountIn, "unpaid");
    }
}

/// @dev A V3/CL style position manager that is also its own factory. Positions are priced exactly like
/// Uniswap's (liquidity from desired amounts at the pool price, amounts for that liquidity), fees accrue
/// only when a test calls accrueFees, and the manager holds every deposited token itself.
contract MockV3Venue {
    struct Pos {
        address owner;
        address pool;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 owed0;
        uint128 owed1;
    }

    bool public immutable isCL;
    bool public immutable pancake;
    address public constant WETH9 = 0x4200000000000000000000000000000000000006;
    uint256 public nextId;
    mapping(uint256 => Pos) public pos;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    mapping(bytes32 => address) internal _pools;

    constructor(bool cl, bool pancake_) {
        isCL = cl;
        pancake = pancake_;
    }

    /// @dev Pure tiers so the mock keeps working when its code is etched at a Base venue address.
    function feeAmountTickSpacing(uint24 fee) public pure returns (int24) {
        if (fee == 500) return 10;
        if (fee == 3000) return 60;
        if (fee == 10_000) return 200;
        return 0;
    }

    function tickSpacingToFee(int24 ts) public pure returns (uint24) {
        if (ts == 1) return 100;
        if (ts == 100) return 500;
        if (ts == 200) return 3000;
        return 0;
    }

    function factory() external view returns (address) {
        return address(this);
    }

    // ---- factory surface
    function getPool(address a, address b, uint24 fee) external view returns (address) {
        return _pools[keccak256(abi.encode(a, b, uint256(fee)))];
    }

    function getPool(address a, address b, int24 ts) external view returns (address) {
        return _pools[keccak256(abi.encode(a, b, uint256(int256(ts))))];
    }

    function _create(address t0, address t1, uint256 tier, uint160 price) internal returns (address pool) {
        bytes32 k = keccak256(abi.encode(t0, t1, tier));
        pool = _pools[k];
        if (pool == address(0)) {
            pool = address(new MockV3Pool(t0, t1, price, pancake));
            _pools[k] = pool;
        }
    }

    function createAndInitializePoolIfNecessary(address t0, address t1, uint24 fee, uint160 price)
        external
        payable
        returns (address)
    {
        return _create(t0, t1, uint256(fee), price);
    }

    /// @dev Test helper: create a pool at a price before LpDesk opens on it.
    function createPoolAt(address t0, address t1, uint256 tier, uint160 price) external returns (address) {
        return _create(t0, t1, tier, price);
    }

    // ---- positions
    function mint(IV3PositionManager.MintParams calldata p)
        external
        payable
        returns (uint256, uint128, uint256, uint256)
    {
        require(!isCL, "CL manager");
        address pool = _pools[keccak256(abi.encode(p.token0, p.token1, uint256(p.fee)))];
        require(pool != address(0), "no pool");
        return _mint(
            pool, p.tickLower, p.tickUpper, p.amount0Desired, p.amount1Desired, p.amount0Min, p.amount1Min, p.recipient
        );
    }

    function mint(ICLPositionManager.MintParams calldata p)
        external
        payable
        returns (uint256, uint128, uint256, uint256)
    {
        require(isCL, "V3 manager");
        address pool = _create(p.token0, p.token1, uint256(int256(p.tickSpacing)), p.sqrtPriceX96);
        return _mint(
            pool, p.tickLower, p.tickUpper, p.amount0Desired, p.amount1Desired, p.amount0Min, p.amount1Min, p.recipient
        );
    }

    function _mint(
        address pool,
        int24 lower,
        int24 upper,
        uint256 d0,
        uint256 d1,
        uint256 min0,
        uint256 min1,
        address recipient
    ) internal returns (uint256 id, uint128 liquidity, uint256 a0, uint256 a1) {
        (liquidity, a0, a1) = _add(pool, lower, upper, d0, d1);
        require(a0 >= min0 && a1 >= min1, "Price slippage check");
        id = ++nextId;
        pos[id] = Pos({
            owner: recipient, pool: pool, tickLower: lower, tickUpper: upper, liquidity: liquidity, owed0: 0, owed1: 0
        });
    }

    function _add(address pool, int24 lower, int24 upper, uint256 d0, uint256 d1)
        internal
        returns (uint128 liquidity, uint256 a0, uint256 a1)
    {
        uint160 price = MockV3Pool(pool).sqrtPriceX96();
        uint160 sa = FirmMath.getSqrtRatioAtTick(lower);
        uint160 sb = FirmMath.getSqrtRatioAtTick(upper);
        liquidity = FirmMath.getLiquidityForAmounts(price, sa, sb, d0, d1);
        (a0, a1) = FirmMath.getAmountsForLiquidity(price, sa, sb, liquidity);
        if (a0 > 0) require(IERC20(MockV3Pool(pool).token0()).transferFrom(msg.sender, address(this), a0), "t0");
        if (a1 > 0) require(IERC20(MockV3Pool(pool).token1()).transferFrom(msg.sender, address(this), a1), "t1");
    }

    function increaseLiquidity(IPositionManagerCommon.IncreaseLiquidityParams calldata p)
        external
        payable
        returns (uint128 liquidity, uint256 a0, uint256 a1)
    {
        Pos storage s = pos[p.tokenId];
        (liquidity, a0, a1) = _add(s.pool, s.tickLower, s.tickUpper, p.amount0Desired, p.amount1Desired);
        require(a0 >= p.amount0Min && a1 >= p.amount1Min, "Price slippage check");
        s.liquidity += liquidity;
    }

    function decreaseLiquidity(IPositionManagerCommon.DecreaseLiquidityParams calldata p)
        external
        payable
        returns (uint256 a0, uint256 a1)
    {
        Pos storage s = pos[p.tokenId];
        _auth(s.owner);
        require(p.liquidity <= s.liquidity, "liquidity");
        uint160 price = MockV3Pool(s.pool).sqrtPriceX96();
        (a0, a1) = FirmMath.getAmountsForLiquidity(
            price, FirmMath.getSqrtRatioAtTick(s.tickLower), FirmMath.getSqrtRatioAtTick(s.tickUpper), p.liquidity
        );
        require(a0 >= p.amount0Min && a1 >= p.amount1Min, "Price slippage check");
        s.liquidity -= p.liquidity;
        s.owed0 += uint128(a0);
        s.owed1 += uint128(a1);
    }

    function collect(IPositionManagerCommon.CollectParams calldata p)
        external
        payable
        returns (uint256 a0, uint256 a1)
    {
        Pos storage s = pos[p.tokenId];
        _auth(s.owner);
        a0 = s.owed0 < p.amount0Max ? s.owed0 : p.amount0Max;
        a1 = s.owed1 < p.amount1Max ? s.owed1 : p.amount1Max;
        s.owed0 -= uint128(a0);
        s.owed1 -= uint128(a1);
        if (a0 > 0) require(IERC20(MockV3Pool(s.pool).token0()).transfer(p.recipient, a0), "c0");
        if (a1 > 0) require(IERC20(MockV3Pool(s.pool).token1()).transfer(p.recipient, a1), "c1");
    }

    function burn(uint256 id) external payable {
        Pos storage s = pos[id];
        _auth(s.owner);
        require(s.liquidity == 0 && s.owed0 == 0 && s.owed1 == 0, "Not cleared");
        delete pos[id];
    }

    function positions(uint256 id)
        external
        view
        returns (uint96, address, address, address, uint256, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        Pos storage s = pos[id];
        address t0 = s.pool == address(0) ? address(0) : MockV3Pool(s.pool).token0();
        address t1 = s.pool == address(0) ? address(0) : MockV3Pool(s.pool).token1();
        return (0, address(0), t0, t1, 0, s.tickLower, s.tickUpper, s.liquidity, 0, 0, s.owed0, s.owed1);
    }

    function setApprovalForAll(address op, bool approved) external {
        isApprovedForAll[msg.sender][op] = approved;
    }

    function ownerOf(uint256 id) external view returns (address) {
        return pos[id].owner;
    }

    /// @dev Test helper: fees accrue; the test mints the tokens to this manager first.
    function accrueFees(uint256 id, uint128 f0, uint128 f1) external {
        pos[id].owed0 += f0;
        pos[id].owed1 += f1;
    }

    function _auth(address owner) internal view {
        require(msg.sender == owner || isApprovedForAll[owner][msg.sender], "Not approved");
    }
}
