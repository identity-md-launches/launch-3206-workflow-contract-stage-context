// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "../../src/interfaces/IERC20.sol";
import {PoolKey} from "../../src/interfaces/IVenues.sol";
import {FirmMath} from "../../src/libraries/FirmMath.sol";
import {MockV4PoolManager} from "./MockV4.sol";

/// @dev Permit2's allowance-transfer surface: approve(token, spender, amount, expiration) and the
/// transferFrom a PositionManager uses to settle, pulling through the owner's ERC-20 approval of Permit2.
contract MockPermit2 {
    struct Allowance {
        uint160 amount;
        uint48 expiration;
    }

    mapping(address => mapping(address => mapping(address => Allowance))) public allowance;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        allowance[msg.sender][token][spender] = Allowance(amount, expiration);
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        Allowance storage a = allowance[from][token][msg.sender];
        require(block.timestamp <= a.expiration, "AllowanceExpired");
        require(a.amount >= amount, "InsufficientAllowance");
        if (a.amount != type(uint160).max) a.amount -= amount;
        require(IERC20(token).transferFrom(from, to, amount), "TRANSFER_FROM_FAILED");
    }
}

/// @dev A Uniswap v4 PositionManager modelled on v4-periphery for the actions VenueV4 sends:
/// MINT_POSITION, INCREASE_LIQUIDITY, DECREASE_LIQUIDITY, BURN_POSITION, SETTLE_PAIR and TAKE_PAIR.
/// - amounts owed for added liquidity round up, amounts returned for removed liquidity round down;
/// - amount0Max/amount1Max are checked on the net amount (principal less fees credited), as
///   `(liquidityDelta - feesAccrued).validateMaxIn` does, and min outs on the principal only;
/// - increase, decrease and burn require the caller to be the owner or approved;
/// - a zero-liquidity modify of an empty position reverts (CannotUpdateEmptyPosition);
/// - every currency delta must be zero when modifyLiquidities returns (CurrencyNotSettled);
/// - the pool price is the mock PoolManager's, so a test can move it between calls.
/// Deposited tokens stay in this contract; fees accrue only when a test calls accrueFees.
contract MockV4Posm {
    uint8 internal constant INCREASE_LIQUIDITY = 0x00;
    uint8 internal constant DECREASE_LIQUIDITY = 0x01;
    uint8 internal constant MINT_POSITION = 0x02;
    uint8 internal constant BURN_POSITION = 0x03;
    uint8 internal constant SETTLE_PAIR = 0x0d;
    uint8 internal constant TAKE_PAIR = 0x11;

    struct Pos {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 fees0;
        uint128 fees1;
    }

    address public immutable poolManager;
    address public immutable permit2;

    uint256 internal _lastId;
    mapping(uint256 => Pos) internal _pos;
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    mapping(address => int256) public delta;
    address[] internal _touched;

    constructor(address pm, address p2) {
        poolManager = pm;
        permit2 = p2;
    }

    // ------------------------------------------------------------ views

    function nextTokenId() external view returns (uint256) {
        return _lastId + 1;
    }

    function getPositionLiquidity(uint256 tokenId) external view returns (uint128) {
        return _pos[tokenId].liquidity;
    }

    function feesOf(uint256 tokenId) external view returns (uint128, uint128) {
        return (_pos[tokenId].fees0, _pos[tokenId].fees1);
    }

    function priceOf(PoolKey memory key) public view returns (uint160) {
        return MockV4PoolManager(poolManager).priceOf(keccak256(abi.encode(key)));
    }

    // ------------------------------------------------------------ ERC-721 surface used

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    // ------------------------------------------------------------ test helpers

    /// @dev Credits owed fees to a position; the test funds this contract with the tokens.
    function accrueFees(uint256 tokenId, uint128 f0, uint128 f1) external {
        _pos[tokenId].fees0 += f0;
        _pos[tokenId].fees1 += f1;
    }

    // ------------------------------------------------------------ PositionManager

    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24) {
        if (priceOf(key) != 0) return type(int24).max;
        return MockV4PoolManager(poolManager).initialize(key, sqrtPriceX96);
    }

    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable {
        require(block.timestamp <= deadline, "DeadlinePassed");
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        require(actions.length == params.length, "InputLengthMismatch");
        for (uint256 i; i < actions.length; ++i) {
            uint8 a = uint8(actions[i]);
            if (a == MINT_POSITION) _mint(params[i]);
            else if (a == INCREASE_LIQUIDITY) _increase(params[i]);
            else if (a == DECREASE_LIQUIDITY) _decreaseAction(params[i]);
            else if (a == BURN_POSITION) _burn(params[i]);
            else if (a == SETTLE_PAIR) _settlePair(params[i]);
            else if (a == TAKE_PAIR) _takePair(params[i]);
            else revert("UnsupportedAction");
        }
        for (uint256 i; i < _touched.length; ++i) {
            require(delta[_touched[i]] == 0, "CurrencyNotSettled");
        }
        delete _touched;
    }

    // ------------------------------------------------------------ actions

    function _mint(bytes memory data) internal {
        (PoolKey memory key, int24 lower, int24 upper, uint256 liquidity, uint128 max0, uint128 max1, address owner,) =
            abi.decode(data, (PoolKey, int24, int24, uint256, uint128, uint128, address, bytes));
        require(priceOf(key) != 0, "PoolNotInitialized");
        require(lower < upper, "TicksMisordered");
        require(lower % key.tickSpacing == 0 && upper % key.tickSpacing == 0, "TickMisaligned");
        require(liquidity > 0, "CannotUpdateEmptyPosition");
        uint256 id = ++_lastId;
        Pos storage p = _pos[id];
        p.key = key;
        p.tickLower = lower;
        p.tickUpper = upper;
        p.liquidity = uint128(liquidity);
        ownerOf[id] = owner;
        (uint256 a0, uint256 a1) = _amountsUp(key, lower, upper, uint128(liquidity));
        require(a0 <= max0 && a1 <= max1, "MaximumAmountExceeded");
        _account(key.currency0, -int256(a0));
        _account(key.currency1, -int256(a1));
    }

    function _increase(bytes memory data) internal {
        (uint256 id, uint256 liquidity, uint128 max0, uint128 max1,) =
            abi.decode(data, (uint256, uint256, uint128, uint128, bytes));
        _onlyApproved(id);
        Pos storage p = _pos[id];
        require(liquidity > 0 || p.liquidity > 0, "CannotUpdateEmptyPosition");
        (uint256 a0, uint256 a1) = _amountsUp(p.key, p.tickLower, p.tickUpper, uint128(liquidity));
        p.liquidity += uint128(liquidity);
        // Owed fees are credited into the same delta: the net amount is checked against the maximums.
        int256 net0 = int256(uint256(p.fees0)) - int256(a0);
        int256 net1 = int256(uint256(p.fees1)) - int256(a1);
        p.fees0 = 0;
        p.fees1 = 0;
        require((net0 >= 0 || uint256(-net0) <= max0) && (net1 >= 0 || uint256(-net1) <= max1), "MaximumAmountExceeded");
        _account(p.key.currency0, net0);
        _account(p.key.currency1, net1);
    }

    function _decreaseAction(bytes memory data) internal {
        (uint256 id, uint256 liquidity, uint128 min0, uint128 min1,) =
            abi.decode(data, (uint256, uint256, uint128, uint128, bytes));
        _onlyApproved(id);
        _decrease(id, uint128(liquidity), min0, min1);
    }

    function _decrease(uint256 id, uint128 liquidity, uint128 min0, uint128 min1) internal {
        Pos storage p = _pos[id];
        require(liquidity > 0 || p.liquidity > 0, "CannotUpdateEmptyPosition");
        require(liquidity <= p.liquidity, "LiquidityUnderflow");
        (uint256 a0, uint256 a1) = _amountsDown(p.key, p.tickLower, p.tickUpper, liquidity);
        require(a0 >= min0 && a1 >= min1, "MinimumAmountInsufficient");
        p.liquidity -= liquidity;
        _account(p.key.currency0, int256(a0 + p.fees0));
        _account(p.key.currency1, int256(a1 + p.fees1));
        p.fees0 = 0;
        p.fees1 = 0;
    }

    function _burn(bytes memory data) internal {
        (uint256 id, uint128 min0, uint128 min1,) = abi.decode(data, (uint256, uint128, uint128, bytes));
        _onlyApproved(id);
        Pos storage p = _pos[id];
        if (p.liquidity > 0) {
            _decrease(id, p.liquidity, min0, min1);
        } else if (p.fees0 > 0 || p.fees1 > 0) {
            _account(p.key.currency0, int256(uint256(p.fees0)));
            _account(p.key.currency1, int256(uint256(p.fees1)));
        }
        delete _pos[id];
        delete ownerOf[id];
    }

    function _settlePair(bytes memory data) internal {
        (address c0, address c1) = abi.decode(data, (address, address));
        _settle(c0);
        _settle(c1);
    }

    function _settle(address c) internal {
        int256 d = delta[c];
        require(d <= 0, "DeltaNotNegative");
        if (d == 0) return;
        MockPermit2(permit2).transferFrom(msg.sender, address(this), uint160(uint256(-d)), c);
        delta[c] = 0;
    }

    function _takePair(bytes memory data) internal {
        (address c0, address c1, address to) = abi.decode(data, (address, address, address));
        _take(c0, to);
        _take(c1, to);
    }

    function _take(address c, address to) internal {
        int256 d = delta[c];
        require(d >= 0, "DeltaNotPositive");
        if (d == 0) return;
        delta[c] = 0;
        require(IERC20(c).transfer(to, uint256(d)), "take");
    }

    // ------------------------------------------------------------ internals

    function _onlyApproved(uint256 id) internal view {
        address owner = ownerOf[id];
        require(owner != address(0), "NotMinted");
        require(msg.sender == owner || isApprovedForAll[owner][msg.sender], "NotApproved");
    }

    function _account(address c, int256 d) internal {
        if (d == 0) return;
        bool seen;
        for (uint256 i; i < _touched.length; ++i) {
            if (_touched[i] == c) seen = true;
        }
        if (!seen) _touched.push(c);
        delta[c] += d;
    }

    function _amountsUp(PoolKey memory key, int24 lower, int24 upper, uint128 liquidity)
        internal
        view
        returns (uint256 a0, uint256 a1)
    {
        uint160 sqrtP = priceOf(key);
        uint160 sqrtA = FirmMath.getSqrtRatioAtTick(lower);
        uint160 sqrtB = FirmMath.getSqrtRatioAtTick(upper);
        if (sqrtP <= sqrtA) {
            a0 = _amount0Up(sqrtA, sqrtB, liquidity);
        } else if (sqrtP < sqrtB) {
            a0 = _amount0Up(sqrtP, sqrtB, liquidity);
            a1 = FirmMath.mulDivUp(liquidity, sqrtP - sqrtA, 1 << 96);
        } else {
            a1 = FirmMath.mulDivUp(liquidity, sqrtB - sqrtA, 1 << 96);
        }
    }

    function _amount0Up(uint160 sqrtA, uint160 sqrtB, uint128 liquidity) internal pure returns (uint256) {
        uint256 n = FirmMath.mulDivUp(uint256(liquidity) << 96, sqrtB - sqrtA, sqrtB);
        return (n + sqrtA - 1) / sqrtA;
    }

    function _amountsDown(PoolKey memory key, int24 lower, int24 upper, uint128 liquidity)
        internal
        view
        returns (uint256, uint256)
    {
        return FirmMath.getAmountsForLiquidity(
            priceOf(key), FirmMath.getSqrtRatioAtTick(lower), FirmMath.getSqrtRatioAtTick(upper), liquidity
        );
    }
}
