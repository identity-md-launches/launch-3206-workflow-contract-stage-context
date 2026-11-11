// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "../../src/interfaces/IERC20.sol";
import {PoolKey, IV4PoolManager} from "../../src/interfaces/IVenues.sol";
import {FirmMath} from "../../src/libraries/FirmMath.sol";

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @dev A fixed-price Uniswap v4 PoolManager for swaps: slot0 readable through extsload exactly where
/// StateLibrary reads it, unlock -> unlockCallback, swap at the stored price less a 1.25% fee, and the
/// sync / settle / take settlement sequence with a balance check.
contract MockV4PoolManager {
    uint256 internal constant POOLS_SLOT = 6;
    uint256 public constant FEE_BPS = 125;
    mapping(bytes32 => uint160) public priceOf;
    address internal _synced;
    uint256 internal _syncedBalance;
    bool internal _unlocked;
    int256 internal _owedIn;
    /// @dev Test helper: when nonzero, a swap consumes at most this much input (a partial fill).
    uint256 public maxIn;

    function setMaxIn(uint256 m) external {
        maxIn = m;
    }

    function setPrice(PoolKey memory key, uint160 sqrtPriceX96) external {
        priceOf[keccak256(abi.encode(key))] = sqrtPriceX96;
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        // The caller asks for keccak256(abi.encode(poolId, POOLS_SLOT)); find the pool whose slot it is.
        return _slotValues[slot];
    }

    mapping(bytes32 => bytes32) internal _slotValues;

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24) {
        bytes32 poolId = keccak256(abi.encode(key));
        priceOf[poolId] = sqrtPriceX96;
        _slotValues[keccak256(abi.encode(poolId, POOLS_SLOT))] = bytes32(uint256(sqrtPriceX96));
        return 0;
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(!_unlocked, "locked");
        _unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        require(_owedIn == 0, "CurrencyNotSettled");
        _unlocked = false;
    }

    function quoteOut(PoolKey memory key, bool zeroForOne, uint256 amountIn) public view returns (uint256 out) {
        uint160 sqrtP = priceOf[keccak256(abi.encode(key))];
        uint256 p = FirmMath.mulDiv(sqrtP, sqrtP, 1 << 96);
        out = zeroForOne ? FirmMath.mulDiv(amountIn, p, 1 << 96) : FirmMath.mulDiv(amountIn, 1 << 96, p);
        out = out * (10_000 - FEE_BPS) / 10_000;
    }

    function swap(PoolKey memory key, IV4PoolManager.SwapParams memory params, bytes calldata)
        external
        returns (int256)
    {
        require(_unlocked, "ManagerLocked");
        require(params.amountSpecified < 0, "exact in only");
        uint256 amountIn = uint256(-params.amountSpecified);
        if (maxIn != 0 && amountIn > maxIn) amountIn = maxIn;
        uint256 out = quoteOut(key, params.zeroForOne, amountIn);
        _owedIn = int256(amountIn);
        int256 a0 = params.zeroForOne ? -int256(amountIn) : int256(out);
        int256 a1 = params.zeroForOne ? int256(out) : -int256(amountIn);
        // BalanceDelta packing: amount0 in the high 128 bits, amount1 in the low 128 bits.
        return int256((uint256(uint128(int128(a0))) << 128) | uint256(uint128(int128(a1))));
    }

    function sync(address currency) external {
        _synced = currency;
        _syncedBalance = IERC20(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        paid = IERC20(_synced).balanceOf(address(this)) - _syncedBalance;
        _owedIn -= int256(paid);
        require(_owedIn <= 0, "short");
        _owedIn = 0;
    }

    function take(address currency, address to, uint256 amount) external {
        require(IERC20(currency).transfer(to, amount), "take");
    }
}

/// @dev The PositionManager surface FirmVault's buyback path touches: poolManager() and permit2().
contract MockV4PositionManager {
    address public immutable poolManager;

    constructor(address pm) {
        poolManager = pm;
    }

    function permit2() external pure returns (address) {
        return address(0);
    }
}
