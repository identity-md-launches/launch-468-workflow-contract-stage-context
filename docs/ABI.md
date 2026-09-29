# Contract interface guide

Canonical compiler ABI arrays are in `abi/LaunchToken.json`, `abi/GrantExecutor.json`,
and `abi/CityRegistry.json`. Regenerate with `python3 scripts/export_abi.py`; validate
with `python3 scripts/export_abi.py --check`. Solidity NatSpec and README describe the
economic assumptions and the one-time registry binding.

All token amounts are uint256 **minor GRID units (18 decimals)**. City IDs, levels, and
resource amounts are uint256 integers. A resource amount of `400` means 400 resources,
requiring 400 GRID backing; it does not mean 400 token wei.

## LaunchToken

Standard ERC-20 getters and approvals retain their usual semantics. Every `transfer`
and `transferFrom` pays the fixed `TAX_BPS() = 400`, with treasury `TREASURY()` fixed to
`0x5b95A971B4583A5f011E9DA082acdD679b870D06`. `transferTax(gross)` returns the rounded-down
tax. The recipient gets gross minus tax; allowances spend gross. `TaxTaken` comes from
the token address and reports all four allocations, including any rounding dust.
`burn(amount)` burns the caller's balance; `burnFrom(account, amount)` requires that
account's allowance to the caller. Explicit burns have no transfer tax. No constructor
arguments. `deployer()` may call `setCityRegistry(address)` exactly once with the reviewed
registry; `cityRegistry()` is zero until then. `pendingRewards()` and `pendingResources()`
report pool tax escrow collected before binding. Binding releases those amounts and has
no token minting or arbitrary withdrawal capability. Verify and bind before opening the
application; see README for the factory requirement and trust assumption.
Applications must request the exact intended spend. In particular, never request an
unlimited or oversized CityRegistry purchase allowance: it permits a higher live price
to be burned after intervening buys. Zero ERC-20 transfers are allowed and zero-address
recipients are rejected.

## CityRegistry reads

| Method | Result / use |
| --- | --- |
| `coordinates(cityId)` | `(x, y)` grid coordinates, invalid IDs revert |
| `cities(cityId)` | `(owner, level, resources, rewardIndex, accruedScaled)`; zero owner means empty |
| `cityOf(wallet)` | City ID plus one, or zero if no city |
| `cityPrice()` | Current purchase price in minor units; reverts when all 256 plots are sold |
| `levelUpCost(cityId)` | Whole resources required for the next level; empty/max-level plots revert |
| `claimableRewards(cityId)` | Current whole minor units claimable; empty valid plot returns zero |
| `rewardsPool()`, `resourcePot()` | Unpaid reward reserve and unallocated resource backing, respectively |
| `allocatedResourceBacking()` | GRID backing unspent granted resources; decreases when leveling burns the backing |
| `soldPlots()`, `totalWeight()` | Occupied count and sum of squared levels |
| `token()`, `grantExecutor()`, `treasury()` | Immutable dependency and beneficiary addresses |
| `heartbeatCount()`, `lastHeartbeatTimestamp()` | Last sequence/time; count zero means no heartbeat yet |
| `lastHeartbeatCityIds(i)`, `lastHeartbeatAmounts(i)` | Winner ID and whole resource grant for slot `i = 0,1,2` |

`rewardIndex`, `accruedScaled`, `accRewardPerWeight`, `queuedRewards`, and `rewardRemainder`
are accounting inspection fields. Frontends should display `claimableRewards` instead of
reimplementing scaled arithmetic. Read all 256 cities via batched eth_calls; no enumerable
NFT interface exists. Built-in fixed-array getters reject indexes outside their bounds.

## CityRegistry writes

| Method | Caller / preconditions |
| --- | --- |
| `buyCity(cityId)` | Unowned plot, caller has no city, >=1,000 GRID held; approve exactly the accepted quote to cap the burn |
| `levelUp(cityId)` | Owner, below level 20, enough whole resources; consumes resources and burns their GRID backing atomically |
| `claimRewards(cityId)` | Owner, at least one minor GRID unit accrued; returns gross amount; token recipient receives net |
| `fundRewards(amount)` | Any caller with balance/allowance; amount positive |
| `fundResources(amount)` | Any caller with balance/allowance; amount positive |
| `transferWithTax(to, amount)` | Single transferFrom wrapper; positive gross amount and allowance, valid recipient |
| `grantResources(cityId, amount)` | Only immutable executor; owned city, positive grant, sufficient pot |
| `recordHeartbeat(id1,a1,id2,a2,id3,a3)` | Only immutable executor; three distinct owned cities and sufficient pot for all |

Approvals for buys/funding/wrapped transfers name **CityRegistry** as spender.
Approvals are not needed for claims, leveling, or executor awards.

The frontend purchase flow is: read `cityPrice()`, display that exact minor-unit quote,
obtain the buyer's acceptance, and call `token.approve(registry, quote)` even if an
existing allowance exceeds the quote. Wait for confirmation before `buyCity(cityId)`.
Do not use `increaseAllowance`, add a buffer, or retain an unlimited allowance. If another
buy raises the price, the burn reverts with `ERC20InsufficientAllowance`, preserving the
buyer's balance and allowance and all city/reward state. Show the new quote and obtain
fresh acceptance before replacing the allowance and retrying. On success the exact
allowance is consumed. If the buyer cancels or a purchase fails for another reason,
offer to revoke the remaining allowance with `approve(registry, 0)`. `buyCity` has no
separate price-limit parameter; the allowance supplies that limit. The frontend is a
subsequent service deliverable and must implement this flow before release.

For all token transfers, show `fee = floor(amount / 25)` and `net = amount - fee`.
Resources receive `floor(3 * fee / 10)`, burn and treasury each receive `floor(fee / 10)`,
and rewards receive the remainder. Amounts below 25 minor units pay zero rounded tax.
`transferWithTax` uses this same token rule, without an additional levy. `fundRewards`
and `fundResources` credit net funding plus the automatically allocated tax shares;
`PoolsFunded` reports net explicit funding only. `TransferTaxReceived(rewards, resources)`
reports the separate callback allocation. `onTaxReceived` accepts only the immutable
token and is not a funding method for users. The callback is intentionally unguarded
because it runs during guarded funding and claim operations, and makes no external calls.

`claimableRewards`, `claimRewards`' return, and `RewardsClaimed.amount` are **gross**.
A claim creates a taxed token transfer and can immediately credit new rewards to owners.
Display the token net payout and any new claimable balance separately.

## GrantExecutor

`operator()` and `paused()` expose configuration. Only operator can call `pause()`,
`unpause()`, `grantResources(registry, cityId, amount)`, or
`recordHeartbeat(registry, id1, a1, id2, a2, id3, a3)`.
Targets must have code; forwarded failures bubble unchanged. Pausing affects only the
two grant methods. Repeated pause/unpause transitions revert. No owner-transfer API.

## Events and failures

| Event | Indexable fields / data |
| --- | --- |
| `CityBought` | Indexed city ID and owner; full burned price |
| `ResourcesGranted` | Indexed city ID; whole resource amount |
| `CityLeveled` | Indexed city ID; new level, resources consumed |
| `RewardsClaimed` | Indexed city ID and owner; amount paid in minor GRID |
| `TaxTaken` (LaunchToken) | Indexed sender and recipient; gross, fee, rewards, resources, burned, treasury, all minor GRID |
| `HeartbeatRecorded` | Indexed sequence; fixed arrays of three IDs and whole resource amounts |
| `PoolsFunded` | Indexed funder; net explicit reward/resource funding in minor GRID |
| `TransferTaxReceived` | Registry pool credits from token tax (including escrow released at binding) |
| `CityRegistrySet` | Token's permanently bound registry address |
| `GrantsPauseChanged` | New boolean pause state |
| `Transfer`, `Approval` | Standard ERC-20 logs, including zero-address burn destinations |

The ABI includes custom errors for invalid IDs, insufficient holdings/resources/pot,
occupied/already-owned cities, unauthorized ownership/executor/operator, duplicate winners,
zero amounts, empty rewards, sold-out grid, invalid dependencies/recipients, and paused or
duplicate pause transitions. Token balance/allowance failures use OpenZeppelin ERC-20
errors. Failed transactions roll back all state and events; replay emitted logs only from
successful receipts and handle chain reorganizations in the frontend.
