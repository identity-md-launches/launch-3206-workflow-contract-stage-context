# The Firm: notSTOCK ($NOTSTOCK)

Don't work for the firm. Let the firm work for you.

Token notSTOCK, symbol NOTSTOCK, on Base (chain 8453), paired with IMD. 18 decimals, 1 000 000 000 NOTSTOCK, minted once at launch. The binding rules are in SPEC.md; the cash model is in FINMODEL.md.

## Tokenomics

- 30% seeded into the NOTSTOCK/IMD pool.
- 10% to the swarm that launches it.
- 10% to the dev wallet 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981, via GenesisSplitter.
- 50% to LpDesk, via GenesisSplitter.

## Launch

- One launch on Base: the notSTOCK token, its NOTSTOCK/IMD pool and, beside the token, LpDesk (its constructor creates Burner), FirmVault and GenesisSplitter. LpDesk's modules LpGovernor, PriceGuard and any further module are deployed after the launch by deployModule, callable by anyone, once per module, with the code hash fixed in LpDesk.
- After the launch the project wallet transfers 600 000 000 NOTSTOCK (60%) to GenesisSplitter and sets FirmVault as the pool fee recipient.

## Rules in short

- Pool fee to FirmVault: received fees stay on FirmVault until anyone calls distribute(token), which splits the whole undistributed IMD 25% buyback and burn, 25% project wallet 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C, 25% LpDesk top-up basket, 25% LpDesk free balance, and sends NOTSTOCK to Burner.
- LpDesk: liquidity positions only on listed venues: six at deploy (Uniswap v4, Uniswap v3, PancakeSwap v3, SushiSwap v3 and two Aerodrome Slipstream position managers), more only by an AddVenue vote of stakers (V3, CL or V4 interface), never removed; no transfer to any wallet but the project wallet; operator may close positions, burn free NOTSTOCK and move ranges; new positions after the first 7 days need a passed, unvetoed LpGovernor proposal.
- LpDesk never deposits a position NFT into any staking, gauge or farm contract; positions earn only pool fees.
- Burner: anyone may call burn(); its whole NOTSTOCK balance goes to 0x000000000000000000000000000000000000dEaD.
- No owner, mint, pause or upgrade in any contract.

## Files

- SPEC.md: binding specification.
- FINMODEL.md: 12-month cash model, three scenarios.
- SITE.md: rules of the website, built in the same order as the launch.
- brand/: logo, logo-64, compare.
