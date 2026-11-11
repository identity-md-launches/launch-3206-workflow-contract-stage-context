# Adaptations

Each entry is a departure from the letter of SPEC.md that a launch rule or a reproduced audit finding
required, with the rule or finding that required it. Rates, recipients, limits, splits and the token are
unchanged; no owner power, pause, upgrade or minting was added.

1. registerNotStock compares the recorded pool key's fee with the constant 12500 (`PriceGuard.LAUNCH_POOL_FEE`)
   instead of the factory's live `fees().poolFee()`. Finding ab061abb: the live value is owner-settable
   by an outside protocol, and SPEC section 0 forbids a rule that depends on an outside owner's action.
   The hooks field is still compared with the factory's `poolHook()`, which is set once.
2. IMD credits are measured. LpDesk credits FirmVault with the balance change its transfer produced, and
   FirmVault credits LpDesk the same way; FirmVault's undistributed IMD clamps at zero instead of
   underflowing. Finding e318d3fb (IMD is a tax/blacklist token with live owner powers). The splits
   themselves (25/25/25/25, 100% to Burner, 100% of the LpDesk share to the bucket) are unchanged.
3. src/FirmAddresses.sol is removed. Finding ca260315: the operator and project wallet are constructor
   arguments of LpDesk and FirmVault, the dev wallet of GenesisSplitter, and the launch factory is LpDesk's
   constructor `msg.sender`; the venue and asset constants live in PriceGuard, where SPEC puts the lists.
4. The factory surface uses `uint64` launch numbers and `(bytes32 role, bytes32 name, address addr)`
   artifacts. Finding 0706cca9.
5. Module set. LpDesk's code is split into four modules: PriceGuard, LpGovernor, VenueV3 (the V3 and CL
   venue code and their swap callbacks, used by LpDesk buybacks on those kinds) and VenueV4 (the V4
   venue code and the PoolManager swap used by LpDesk buybacks on V4 pools and by FirmVault's buyback in
   the registered pool). SPEC section 2 names DeskSwap as a possible module for "only the swap code of
   buyback()"; here that code lives in the venue module of each kind, so there is no separate DeskSwap.
   FirmVault reads the swap module through LpDesk's `venueV4()` view and reaches the PoolManager through
   the Uniswap v4 PositionManager at its fixed Base address (section 2b).
6. Liquidity-math library. FirmMath (internal functions only) carries mulDiv, the tick-to-sqrt-price
   series and the liquidity/amount conversions in plain Solidity, as SPEC section 0 requires (no vendored
   BitMath/TickMath assembly shifts). The tick-from-price direction is never needed, so it is not written.
7. Shift creates a new position record (the old one is closed and burned at the venue, the new one gets
   the next position id). Moving balance between positions (`moveLiquidity`) requires both positions to
   share the asset, because the withdrawn asset of one pair cannot enter a position of another pair
   without a swap, which section 2 forbids outside opening, closing and buyback.
8. The top-up `amount` is a cap: the position takes what its range needs for `amount` of the asset at
   the given price, never more; the top-up basket decreases by exactly what was taken (measured).
9. Tests. SPEC section 6 asks for Base-mainnet fork tests. The verifier builds and tests with no network
   access, so the delivered suite runs offline: the mock venues are etched at the Base addresses of
   PriceGuard's fixed list (Uniswap v3, PancakeSwap v3, Aerodrome Slipstream, BaseSwap for AddVenue), IMD,
   WETH and USDC are mock ERC-20s at their Base addresses, and the launch factory is a mock with the live
   factory's `positionOf`, `registry().artifactsOf`, `fees()`, `poolHook()` and `setRequester` surface.
   Not delivered: the fork run on the six live venues, the live BaseSwap AddVenue, the B20 etch test, the
   V4 PositionManager position path (mint, increase, decrease, burn) and the full launch rehearsal through
   the live ProjectFactory with its gas bound. These must run on a fork before deployment and are listed
   in the README as open.
10. GenesisSplitter exposes `hasSplit()`; FirmVault exposes `undistributed(token)`; LpDesk exposes
    `moduleAddress`, `moduleCodeHash`, `isModuleDeployed`, `managerApproved`, `positionCount`,
    `position(id)`, `positions()` and `positionLiquidity(id)`. These are views only. Pending (uncollected)
    fees per position are not computed on chain beyond the venue's own `positions()` tokensOwed; the
    section 2a "pending fees" read is left to the venue's view through the recorded tokenId.
11. Revision. Choices made for reproduced review findings: (a) the 0.5% open/top-up check compares prices
    (the square of the sqrtPriceX96 ratio), and an existing pool is quoted at its own price once inside
    that band; (b) VenueV3 passes sqrtPriceX96 to a Slipstream mint only to create a missing pool;
    (c) a partly filled buyback re-credits the unspent input (VenueV4 returns it to the caller, LpDesk or
    FirmVault); (d) BridgeOut amounts are multiples of 10^12 and bridgeOut requires the amount to be
    locked in the adapter itself, the only on-chain check available for an adapter deployed later by a
    separate order. The module creation code hashes in LpDesk were recomputed for the changed modules
    (LpGovernor, VenueV3, VenueV4); PriceGuard is unchanged.
