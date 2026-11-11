# The Firm financial model (token notSTOCK, $NOTSTOCK)

Cash-budget model for FirmVault, LpDesk and Burner, not a forecast or price prediction. No ETH or dollar amount is invested by the developer at launch; the only launch cost is the swarm fee of the one launch order, not a model input here. All volumes, the LpDesk yield assumptions and the LpDesk fee-side share are authored inputs, not observed NOTSTOCK activity.

## Fixed inputs

| Item | Value |
| --- | --- |
| Chain / pair | Base mainnet (8453) / NOTSTOCK-IMD |
| Supply / decimals | 1,000,000,000 / 18 |
| Distribution | 10% swarm, 30% pool, 10% dev wallet, 50% LpDesk |
| Pool fee / launching side / network | 1.25% / 1% / 0.25% of trade |
| FirmVault split of the 1% launching side, IMD | 25% buyback and burn, 25% project wallet, 25% LpDesk top-up basket, 25% LpDesk free balance |
| NOTSTOCK fees (FirmVault and LpDesk) | 100% to Burner, burn() by anyone to the dead address |
| Project wallet | 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C, one constructor value for FirmVault and LpDesk, separate from the dev wallet |

V_m is the month's NOTSTOCK/IMD pool volume in USD equivalent (trade volume, exogenous). FirmVault fee cash is modeled as collected in IMD and distributed within the month; any NOTSTOCK fee goes to Burner and is not modeled. USD is a reporting unit only.

| Formula | Meaning |
| --- | --- |
| F_m = 0.01 * V_m | launching-side fee cash for the month |
| ProjectIncome_m = 0.25 * F_m | to the project wallet by FirmVault distribute(IMD), callable by anyone |
| LiquidityIn_m = 0.50 * F_m | to LpDesk: half to the IMD top-up basket (existing positions), half to free IMD (new positions) |
| Buyback_m = 0.25 * F_m | FirmVault buyback bucket, spent only on buying NOTSTOCK and sending it to the dead address |

## Daily volume path by month (USD equivalent, NOTSTOCK/IMD pool only)

Base is kept below USD 20,000 per day by month 12 by design. Good is a sensitivity (2.5x Base in months 1 to 3, about 2x Base for the year), not a target. Bad assumes fading attention. No LP Desk self-swaps or wash volume are included.

| Month | Bad $/day | Base $/day | Good $/day |
| --- | --- | --- | --- |
| 1 | 1,500 | 3,000 | 7,500 |
| 2 | 1,200 | 4,000 | 10,000 |
| 3 | 1,000 | 5,000 | 12,500 |
| 4 | 850 | 6,500 | 15,000 |
| 5 | 700 | 8,000 | 17,500 |
| 6 | 600 | 9,500 | 20,000 |
| 7 | 500 | 11,000 | 22,500 |
| 8 | 450 | 12,500 | 25,000 |
| 9 | 400 | 14,000 | 27,500 |
| 10 | 350 | 15,500 | 30,000 |
| 11 | 320 | 17,000 | 32,500 |
| 12 | 300 | 18,000 | 35,000 |

## Monthly budgets (USD), 30.4-day average month applied to the daily figures above

### Bad

| Month | V_m | ProjectIncome | LiquidityIn | Buyback |
| --- | --- | --- | --- | --- |
| 1 | 45,600 | 114 | 228 | 114 |
| 2 | 36,480 | 91.20 | 182.40 | 91.20 |
| 3 | 30,400 | 76 | 152 | 76 |
| 4 | 25,840 | 64.60 | 129.20 | 64.60 |
| 5 | 21,280 | 53.20 | 106.40 | 53.20 |
| 6 | 18,240 | 45.60 | 91.20 | 45.60 |
| 7 | 15,200 | 38 | 76 | 38 |
| 8 | 13,680 | 34.20 | 68.40 | 34.20 |
| 9 | 12,160 | 30.40 | 60.80 | 30.40 |
| 10 | 10,640 | 26.60 | 53.20 | 26.60 |
| 11 | 9,728 | 24.32 | 48.64 | 24.32 |
| 12 | 9,120 | 22.80 | 45.60 | 22.80 |
| Year | 248,368 | 620.92 | 1,241.84 | 620.92 |

### Base

| Month | V_m | ProjectIncome | LiquidityIn | Buyback |
| --- | --- | --- | --- | --- |
| 1 | 91,200 | 228 | 456 | 228 |
| 2 | 121,600 | 304 | 608 | 304 |
| 3 | 152,000 | 380 | 760 | 380 |
| 4 | 197,600 | 494 | 988 | 494 |
| 5 | 243,200 | 608 | 1,216 | 608 |
| 6 | 288,800 | 722 | 1,444 | 722 |
| 7 | 334,400 | 836 | 1,672 | 836 |
| 8 | 380,000 | 950 | 1,900 | 950 |
| 9 | 425,600 | 1,064 | 2,128 | 1,064 |
| 10 | 471,200 | 1,178 | 2,356 | 1,178 |
| 11 | 516,800 | 1,292 | 2,584 | 1,292 |
| 12 | 547,200 | 1,368 | 2,736 | 1,368 |
| Year | 3,769,600 | 9,424 | 18,848 | 9,424 |

### Good

| Month | V_m | ProjectIncome | LiquidityIn | Buyback |
| --- | --- | --- | --- | --- |
| 1 | 228,000 | 570 | 1,140 | 570 |
| 2 | 304,000 | 760 | 1,520 | 760 |
| 3 | 380,000 | 950 | 1,900 | 950 |
| 4 | 456,000 | 1,140 | 2,280 | 1,140 |
| 5 | 532,000 | 1,330 | 2,660 | 1,330 |
| 6 | 608,000 | 1,520 | 3,040 | 1,520 |
| 7 | 684,000 | 1,710 | 3,420 | 1,710 |
| 8 | 760,000 | 1,900 | 3,800 | 1,900 |
| 9 | 836,000 | 2,090 | 4,180 | 2,090 |
| 10 | 912,000 | 2,280 | 4,560 | 2,280 |
| 11 | 988,000 | 2,470 | 4,940 | 2,470 |
| 12 | 1,064,000 | 2,660 | 5,320 | 2,660 |
| Year | 7,752,000 | 19,380 | 38,760 | 19,380 |

## Three numbers per scenario (year total)

| Scenario | Project income (USD) | Spent on buyback and burn (USD) | Liquidity to LpDesk (USD) |
| --- | --- | --- | --- |
| Bad | 620.92 | 620.92 | 1,241.84 |
| Base | 9,424 | 9,424 | 18,848 |
| Good | 19,380 | 19,380 | 38,760 |

Buybacks swap at the pool's price with the operator's minimum out set by hand (SPEC.md section 5); the model counts the burn only as the USD equivalent of IMD spent.

## LpDesk position income (separate line, explicit assumption)

LpDesk holds 50% of supply (500,000,000 NOTSTOCK) plus the LiquidityIn above, deployed into concentrated positions on any listed venue on Base (the six of SPEC.md section 2b: Uniswap v4, Uniswap v3, PancakeSwap v3, SushiSwap v3 and two Aerodrome Slipstream position managers, and any venue added by AddVenue vote), against listed assets (IMD, WETH, USDC, cbBTC, Coinbase tokenized stocks): by the operator (dev wallet) directly during the 7 days after NOTSTOCK registration, by OpenPosition vote after that. LpDesk never stakes position NFTs; positions earn only pool fees. This income is not part of FirmVault's fee split and is not counted in ProjectIncome, Buyback or LiquidityIn above.

| Assumption | Value |
| --- | --- |
| Share of LpDesk's held value actually in-range and earning fees at any time | 40% |
| Assumed concentrated-position fee yield, in-range value, per year | 15% (illustrative; depends entirely on the operator's chosen range and pair volume) |
| Modeled LpDesk fee income, per year | about 6% of the value of LpDesk's positions (40% in range x 15%), not a committed or guaranteed figure |

This income is split by LpDesk under SPEC.md section 2, per token: NOTSTOCK fees 100% to Burner and burned; IMD fees 25% to FirmVault's buyback bucket, 25% project wallet, 25% top-up basket, 25% free; WETH, USDC, cbBTC and stock fees 25% to that asset's buyback basket (bought back for NOTSTOCK in that position's pool and sent to the dead address), 25% project wallet, 25% top-up basket, 25% free. If half of that fee income is earned in NOTSTOCK (assumption): burned 62.5% of it (the NOTSTOCK half plus the buyback quarter of the other half), project wallet 12.5%, top-up basket 12.5% and free balance 12.5%; at about 6% a year of position value that is about 3.75% a year burned and about 0.75% a year to each of the other three. None of it is pre-counted in the Buyback rows above, which only model the launching-side fee. Impermanent loss on LpDesk's own two-asset exposure is not modeled; a falling NOTSTOCK price reduces the dollar value of the 50% LpDesk allocation regardless of fee income.

## No invested capital

No ETH, USDC or other developer capital funds this launch. The only recurring cost is the IMD fee paid to the swarm per order (0.5 IMD per order, not a model input here). FirmVault and LpDesk run entirely from the pool's own trading fee from the first trade; at zero volume every FirmVault share, the LpDesk baskets and LpDesk income are zero and no spending occurs.

## Roadmap

1. Launch on Base: NOTSTOCK token, NOTSTOCK/IMD pool, FirmVault, GenesisSplitter, LpDesk with Burner; right after, LpDesk's modules by deployModule. The website of SITE.md is built in the same order.
2. LpDesk on Base: positions against the listed assets on any listed venue (the six of SPEC.md section 2b plus any added by AddVenue vote), opened directly by the operator in the first 7 days, by OpenPosition vote after, and closed by the operator at any time with no vote, back to LpDesk's free balance; the price and every range are set by hand, with no reference-price check; an open or top-up reverts if an existing pool's price differs from the given price by more than 0.5%; new assets only by AddAsset vote, which takes only the asset address; new venues only by AddVenue vote, which takes only the position manager address and its kind.

### Step 3: multichain (a separate swarm order after launch, once NOTSTOCK trades)

- Bridge: NOTSTOCK crosses chains through LayerZero, an OFT adapter on Base locking the original supply and token copies on other chains; supply on all chains together never exceeds 1 000 000 000.
- Each chain gets its own LpDesk with the same rules and a NOTSTOCK/IMD pool against that chain's IMD. The Base LpDesk already has the path (SPEC.md section 2a): an AddBridge vote registers the adapter and the destination LpDesk, then a BridgeOut vote sends free NOTSTOCK only to that LpDesk; no Base contract is replaced.
- Ethereum mainnet: pools against gold (PAXG, XAUT), against $YOLO, and against Ondo tokenized stocks.
- Robinhood Chain: pools against Robinhood tokenized stocks.
- No cost or income from step 3 is counted in the tables above.
