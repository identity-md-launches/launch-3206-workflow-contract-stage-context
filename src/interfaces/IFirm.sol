// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "./IVenues.sol";

// Venue kinds of SPEC section 2b.
uint8 constant KIND_V4 = 0;
uint8 constant KIND_V3 = 1;
uint8 constant KIND_CL = 2;

// Module kinds: the CREATE2 salt of each LpDesk module.
bytes32 constant MODULE_LPGOVERNOR = "LpGovernor";
bytes32 constant MODULE_PRICEGUARD = "PriceGuard";
bytes32 constant MODULE_VENUEV3 = "VenueV3";
bytes32 constant MODULE_VENUEV4 = "VenueV4";

/// @notice One LpDesk position: NOTSTOCK paired with one listed asset on one listed venue.
struct Position {
    address manager; // position manager of the venue
    uint8 kind; // KIND_V4, KIND_V3 or KIND_CL
    address asset; // the listed asset paired with NOTSTOCK
    uint24 fee; // V4/V3: the pool fee; CL: the fee the factory maps to the tick spacing
    int24 tickSpacing; // V4/CL: given at open; V3: the factory's spacing for the fee
    int24 tickLower;
    int24 tickUpper;
    uint256 tokenId;
    bool open;
}

/// @notice Open parameters of SPEC section 2 (direct open and OpenPosition proposal).
struct OpenParams {
    address asset;
    address venue;
    uint24 fee;
    int24 tickSpacing;
    int24 tickLower;
    int24 tickUpper;
    uint160 sqrtPriceX96;
    uint256 amount;
    uint256 amount0Min;
    uint256 amount1Min;
}

/// @notice What LpDesk asks of a venue module (VenueV3 for the V3 and CL kinds, VenueV4 for V4).
interface IVenueModule {
    /// @dev Validates the fee tier against the venue and fills the derived field (V3 tick spacing, CL fee).
    function prepare(Position memory p) external view returns (Position memory);
    /// @dev Pool price and existence for the position's pair on its venue.
    function poolPrice(Position memory p) external view returns (uint160 sqrtPriceX96, bool exists);
    /// @dev Amounts and liquidity the range takes at `sqrtPriceX96` for `amount` of NOTSTOCK (or of the asset).
    function quote(Position memory p, uint160 sqrtPriceX96, uint256 amount, bool amountIsAsset)
        external
        view
        returns (uint256 amountNotstock, uint256 amountAsset, uint128 liquidity);
    /// @dev Mints with LpDesk as recipient from the tokens LpDesk pushed; creates the pool at the price if absent;
    /// returns every unused token to LpDesk in the same call.
    function mint(
        Position memory p,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint256 amountNotstock,
        uint256 amountAsset
    ) external returns (uint256 tokenId);
    function increase(Position memory p, uint128 liquidity, uint256 amountNotstock, uint256 amountAsset)
        external
        returns (uint128 added);
    /// @dev Collects the position's owed fees to LpDesk.
    function collect(Position memory p) external;
    /// @dev Removes `liquidity` and sends the withdrawn amounts to LpDesk.
    function decrease(Position memory p, uint128 liquidity, uint256 min0, uint256 min1) external;
    function burnPosition(Position memory p) external;
    function liquidityOf(Position memory p) external view returns (uint128);
    /// @dev Exact-input swap in the position's own pool from the tokens LpDesk pushed; output to `to`.
    function swapExactIn(Position memory p, address tokenIn, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 amountOut);
}

interface IPriceGuard {
    struct Venue {
        address manager;
        uint8 kind;
        address factory;
    }

    function registered() external view returns (bool);
    function registeredAt() external view returns (uint64);
    function poolKey() external view returns (PoolKey memory);
    function firmVault() external view returns (address);
    function isAsset(address asset) external view returns (bool);
    function venueKind(address manager) external view returns (bool listed, uint8 kind);
    function venues() external view returns (Venue[] memory);
    function assets() external view returns (address[] memory);
    function checkAsset(address asset) external view;
    function checkVenue(address manager, uint8 kind) external view;
    function addAsset(address asset) external;
    function addVenue(address manager, uint8 kind) external;
}

interface ILpDesk {
    function token() external view returns (address);
    function burner() external view returns (address);
    function operator() external view returns (address);
    function projectWallet() external view returns (address);
    function launchFactory() external view returns (address);
    function lpGovernor() external view returns (address);
    function priceGuard() external view returns (address);
    function venueV3() external view returns (address);
    function venueV4() external view returns (address);
    function firmVault() external view returns (address);
    function registered() external view returns (bool);
    function registeredPoolKey() external view returns (PoolKey memory);
    function freeBalance(address token) external view returns (uint256);
    function openFromGovernor(OpenParams calldata p) external returns (uint256 positionId);
    function addAsset(address asset) external;
    function addVenue(address manager, uint8 kind) external;
    function bridgeOut(address adapter, uint32 dstEid, address dstLpDesk, uint256 amount, address refund)
        external
        payable;
}
