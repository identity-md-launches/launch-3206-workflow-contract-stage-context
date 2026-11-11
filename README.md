# The Firm: notSTOCK ($NOTSTOCK)

Don't work for the firm. Let the firm work for you.

Token name "The Firm", symbol NOTSTOCK, on Base (chain 8453), paired with IMD. 18 decimals,
1 000 000 000 NOTSTOCK, minted once at launch. The binding rules are in SPEC.md; the cash model is in
FINMODEL.md; every departure from SPEC.md that a launch rule or a reproduced audit finding required is
in ADAPTATION.md.

## Contracts

| Contract | File | Deployed by | Constructor |
| --- | --- | --- | --- |
| LaunchToken | src/LaunchToken.sol | the launch | none (1 000 000 000 NOTSTOCK to the factory) |
| LpDesk | src/LpDesk.sol | the launch | `($token, operator 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981, projectWallet 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C)`; creates Burner |
| FirmVault | src/FirmVault.sol | the launch | `(projectWallet 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C, $contract:LpDesk)` |
| GenesisSplitter | src/GenesisSplitter.sol | the launch | `($contract:LpDesk, devWallet 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981)` |
| Burner | src/Burner.sol | LpDesk's constructor | `(LpDesk)` |
| PriceGuard | src/modules/PriceGuard.sol | `LpDesk.deployModule("PriceGuard", code)` | none; `msg.sender` is LpDesk |
| LpGovernor | src/modules/LpGovernor.sol | `LpDesk.deployModule("LpGovernor", code)` | none |
| VenueV3 | src/modules/VenueV3.sol | `LpDesk.deployModule("VenueV3", code)` | none |
| VenueV4 | src/modules/VenueV4.sol | `LpDesk.deployModule("VenueV4", code)` | none |

Manifest order: LpDesk, FirmVault, GenesisSplitter (dependency order; the launch deploys at most these
three beside the token). Every constructor is nonpayable, calls no other contract and takes at most three
word-sized arguments. No contract has an owner, a pause, an upgrade path, a mint, a delegatecall or a
selfdestruct. ABIs are exported under docs/abi/.

The module creation-code hashes are constants in LpDesk (`LPGOVERNOR_CODE_HASH`, `PRICEGUARD_CODE_HASH`,
`VENUEV3_CODE_HASH`, `VENUEV4_CODE_HASH`). They are `keccak256(type(Module).creationCode)` of the
artifacts built with foundry.toml as pinned (solc 0.8.26, via_ir, optimizer runs 1, cancun, no bytecode
hash). test/Launch.t.sol asserts them; after any change to a module or to a file it imports, rebuild and
paste the new hashes (`forge inspect <Module> bytecode | cast keccak`).

## Tokenomics (1 000 000 000 NOTSTOCK)

- 30% seeded into the NOTSTOCK/IMD pool by the launch factory (poolBps 3000).
- 10% to the swarm, by the launch policy.
- 60% to the project wallet (remainderTo); it transfers exactly 600 000 000 NOTSTOCK to GenesisSplitter.
  GenesisSplitter.split() then sends 50/60 (500 000 000, 50% of supply) to LpDesk and 10/60
  (100 000 000, 10%) to the dev wallet 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981.

The launch request must carry poolBps = 3000 and remainderTo = 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C,
and the wallet that pays for the launch must be the project wallet: only the launch's requester can call
the factory's setRequester, and with remainderTo unset the factory sends the 60% to the network treasury.
Neither value is a launch.json field, so the manifest and review steps must record where they are set.

The token does nothing the standard launch token does not: SPEC.md asks for plain transfers and no
owner, mint, burn, fee, pause or upgrade, and that is what LaunchToken is.

## Fee rule

- Pool fee: the NOTSTOCK/IMD pool opens at the network's 1.25% fee (1% to the launching side, 0.25% to
  IMD). Pool fees are not pushed by trading: anyone calls the factory's `claimFees(launchNumber)`, which
  transfers the launching side's share to the pool fee recipient, FirmVault once setRequester was called.
  A transfer the IMD token refuses stays in the factory's `owed` mapping until anyone calls
  `withdraw(FirmVault, IMD)`.
- FirmVault.distribute(token), by anyone: the whole undistributed IMD (balance minus the buyback bucket)
  25% to the buyback bucket, 25% to the project wallet, 25% to LpDesk's top-up basket of IMD, 25% to
  LpDesk's free IMD balance (rounding dust goes with the LpDesk free share, so nothing is left
  unaccounted). NOTSTOCK: 100% to Burner. Any other token reverts. A repeat with no new transfer moves
  nothing.
- LpDesk collected fees, split in the call that collects them by the measured balance change: NOTSTOCK
  100% to Burner; every other token 25% buyback (IMD into FirmVault's bucket, anything else into LpDesk's
  buyback basket of that token), 25% project wallet, 25% LpDesk top-up basket, 25% LpDesk free balance.
- Burner: anyone calls burn(); its whole NOTSTOCK balance goes to 0x000000000000000000000000000000000000dEaD.

## LpDesk rules in short

- Positions only on listed venues (six at deploy: Uniswap v4, Uniswap v3, PancakeSwap v3, SushiSwap v3
  and both Aerodrome Slipstream managers; more only by an executed AddVenue), only pairing NOTSTOCK with
  a listed asset (IMD, WETH, USDC, cbBTC, nine Coinbase B20 stocks; more only by an executed AddAsset).
  Nothing removes a venue or an asset.
- Bootstrap: for 604 800 seconds from registerNotStock the operator opens positions directly; after that
  only an executed OpenPosition proposal opens one. Opens on an existing pool revert when its price is
  more than 0.5% from the given sqrtPriceX96; a missing pool is created at that price. Minimums must be
  at least 99.5% of the quoted amounts (a governor open sets exactly that).
- At any time the operator collects fees, shifts a range (`shift`, which closes the position and opens a
  new one with the same venue, pair and tier), moves liquidity between two positions of the same asset
  (`moveLiquidity`), closes (`close`), tops up from the top-up basket (`increaseLiquidity`, no NOTSTOCK
  taken), buys back from the buyback basket into the dead address (`buyback`, never for an IMD position)
  and burns free NOTSTOCK (`burn`). Every minimum out on shift, close and buyback is the operator's own
  argument: the contracts compare nothing with a market price.
- LpGovernor: stake NOTSTOCK (held by LpGovernor, returned on unstake at any time); proposals of kind
  OpenPosition, AddAsset, AddVenue, AddBridge, BridgeOut from a staker with at least 0.1% of the stake
  (the operator with any); weight and quorum base checkpointed at the block before creation; 3-day vote,
  3% quorum and a for-majority; 2-day operator veto; execute by anyone in the next 259 200 seconds, once;
  one open proposal per kind from non-operators and one per kind from the operator.
- No function moves a held asset to any wallet but the project wallet (its 25% fee share), the dead
  address (buybacks, burns), Burner (NOTSTOCK fees) or a registered destination LpDesk (executed BridgeOut).
- LpDesk never deposits a position NFT into any staking, gauge or farm contract; positions earn only
  pool fees.

## After launch

Nothing here is owner-set: every value is a constructor argument or a constant. These are the public
steps, in order, and who makes them.

1. Anyone: `LpDesk.deployModule(kind, creationCode)` for "PriceGuard", "LpGovernor", "VenueV3",
   "VenueV4" (script/DeployModules.s.sol does all four; a rerun skips deployed ones). Every function that
   needs a module reverts until it is deployed.
2. Project wallet: transfer exactly 600 000 000 NOTSTOCK to GenesisSplitter.
3. Project wallet (the launch's paying wallet): `ProjectFactory.setRequester(launchNumber, FirmVault)`
   (`setRequester(uint64,address)`).
4. Anyone: `PriceGuard.registerNotStock(launchNumber)` (uint64). It checks the factory's record: the pool
   key pairs NOTSTOCK with IMD at fee 12500 and the factory's poolHook, the token's name, symbol and
   supply, the registry artifacts named "LpDesk" (this LpDesk) and "GenesisSplitter", that GenesisSplitter
   holds at least 60% of supply, and that the pool fee recipient is a contract whose lpDesk() is this
   LpDesk. It starts the 7-day bootstrap and fixes FirmVault as the only IMD buyback destination.
5. Anyone: `GenesisSplitter.split()`.
6. Over time, anyone: `ProjectFactory.claimFees(launchNumber)`, then `FirmVault.distribute(IMD)` and
   `FirmVault.distribute(NOTSTOCK)`, then `Burner.burn()`.

Launch factory on Base: 0x82EcAA82B8C1A64773D99295B1157EE502539736 (LpDesk stores whatever factory
deployed it as `launchFactory`; the address is not hard-coded).

## Assumptions and trust

- Operator custody. The operator (dev wallet) sets every price, range and minimum by hand. A compromised
  operator key can open a position at any price during the bootstrap and set minimum outs of zero; the
  0.5% and 99.5% checks bind the deposit to the price the operator supplied, not to a market. The only
  control is the key's custody. The operator may hand the role to another address at once.
- IMD issuer powers. IMD (Fren Pet) has a live owner that can blacklist addresses, flag an address as an
  AMM pair (4% tax and a per-transfer cap on its transfers) and keep limits in force. If it flags
  FirmVault, LpDesk or the PoolManager, IMD flows of this launch settle short or revert; fees then wait
  in the factory's `owed` mapping. Credits between LpDesk and FirmVault are measured balance changes and
  FirmVault's undistributed amount clamps at zero, so a short arrival does not block later distributions.
- USDC, cbBTC and the B20 stocks can be paused, blocklisted (and the stocks seized) by their issuers; a
  position in such an asset can be frozen by the issuer.
- Registry artifact names are compared as right-padded bytes32 strings ("LpDesk", "GenesisSplitter");
  the manifest must name the contracts exactly LpDesk, FirmVault and GenesisSplitter.
- V4 action encoding follows Uniswap v4-periphery Actions (MINT_POSITION 0x02, INCREASE_LIQUIDITY 0x00,
  DECREASE_LIQUIDITY 0x01, BURN_POSITION 0x03, SETTLE_PAIR 0x0d, TAKE_PAIR 0x11) and settles through the
  PositionManager's permit2(); the V4 pool price is read from the PoolManager's extsload at the
  StateLibrary slot. V3 and CL swap callbacks answer only the pool of a swap the module started.
- A venue's mint can take up to one unit less than the quoted amounts; the quoted amounts are pushed and
  every unused unit returns to LpDesk in the same call. VenueV4 quotes one extra unit per side to cover
  the PositionManager's round-up.

## Tests

`forge build`, `forge test` and `forge fmt --check` pass offline with the pinned compiler. forge-std is
vendored under test/vendor/forge-std (relative imports; no lib/, no remappings). The suite runs the
launch as the factory does it (test/mocks/MockLaunchFactory.sol deploys token, LpDesk, FirmVault and
GenesisSplitter in one call), deploys every module through deployModule, performs the project wallet's
two transactions, registers and splits, and then exercises FirmVault, Burner, GenesisSplitter, LpDesk
(open, collect, close, shift, top-up, buyback, burn on the V3 and CL kinds with mock venues etched at the
Base addresses of PriceGuard's list, the PancakeSwap callback included), LpGovernor (checkpoints,
thresholds, quorum, veto, execute, expiry, blocking, AddAsset, AddVenue, AddBridge, BridgeOut) and the
FirmVault buyback through a mock v4 PoolManager.

Not delivered in this stage: the SPEC section 6 Base-mainnet fork tests (the six live venues, the
BaseSwap AddVenue, the B20 etch test and the full launch rehearsal through the live ProjectFactory). The
verifier runs without network access, and this stage had no fork run to validate them against; the V4
position path (VenueV4 mint/increase/decrease/burn) is therefore covered by the mock PoolManager swap
only and must be exercised on a fork before deployment. See ADAPTATION.md.

## Audit findings of the imported code

- Launch token absent (high): fixed, src/LaunchToken.sol, tested.
- Section 2 contracts absent (high): fixed, all contracts, modules, tests, script and ABI docs added.
- poolBps / remainderTo (medium): not a source change; recorded above for the manifest and review steps.
- registerNotStock against the live poolFee (medium): reproduced by reasoning (LaunchFees.setPoolFee is
  owner-settable); fixed by comparing the key's fee with the constant 12500, tested.
- IMD tax/blacklist (medium): reproduced with a taxed mock; credits are measured balance changes and
  undistributed clamps at zero, tested; the issuer powers are documented above.
- Factory types (low): uint64 launchNumber and (role, name, addr) artifacts used, tested against a mock.
- claimFees never named (low): documented above under After launch.
- FirmAddresses hardcodes roles (low): the library is removed; roles are constructor arguments and the
  factory is the constructor's msg.sender.
- Operator trust (info) and review scope (info): documented above.

## Files

- SPEC.md: binding specification. ADAPTATION.md: every adaptation and what is left out.
- FINMODEL.md: 12-month cash model, three scenarios.
- SITE.md: rules of the website, built after the launch.
- script/DeployModules.s.sol: deploys the modules after the launch.
- docs/abi/: ABI of every contract.
- brand/: logo, logo-64, compare.
