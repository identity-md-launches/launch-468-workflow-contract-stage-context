# Swarm Cities contracts

This source-stage deliverable contains the GRID launch token, soulbound city registry,
grant executor, tests, and compiler-generated ABIs. It contains no deployment transactions,
wallet keys, frontend, or `launch.json`. The separate manifest and review assignments and
publication/deployment services own those later stages.

## Release conflict: universal transfer tax

The approved workflow requires **every GRID transfer to charge 4%**, including a burn of
0.4% of the gross amount. The supplied `Token.protected.t.sol` test
`test_transferMovesExactlyWhatItWasAsked` instead requires the recipient to receive the
entire amount, the sender to lose exactly that amount, and total supply to remain unchanged.
These requirements cannot both hold for the same transfer.

This implementation follows the protected launch floor: **LaunchToken is fee-free**.
There are no exemptions, delayed tax switches, alternative token assets, or test-specific
behavior. `CityRegistry.transferWithTax` supplies an **optional application route** with the
requested split; direct `transfer`, `transferFrom`, ordinary DEX trades, and reward claims
do not collect a tax. Explicit funding methods can also fund both pots. This route does
**not** fulfill the universal-tax requirement. The workflow or launch admission requirements
must be reconciled before approving a release. Do not advertise that all trading funds the
pots, or use the workflow's proposed website tagline as a statement of current behavior.

## Build and check

The project pins Solidity **0.8.26**, Cancun EVM, optimizer 200 runs, and no bytecode hash or
CBOR trailer. Dependencies are ordinary vendored files; their versions, archive hashes,
and licenses are under `lib/`. No git submodules or package installation is required.
Foundry and the pinned compiler are supplied by the execution environment. Tests require
no environment variables, network, RPC, wallet, filesystem permissions, or FFI.

```sh
forge build
forge test
forge fmt --check
python3 scripts/export_abi.py --check
```

To refresh ABIs after a source change, run `python3 scripts/export_abi.py`.
The tests cover token supply/allowances/burns; city acquisition/prices; weighted reward
accounting; resource allocation and levels; heartbeat atomicity; operator and pause
permissions; fee-route rounding; failed token operations; reentrancy; and CREATE2
constructor execution, runtime bounds, and prohibited opcodes.

## Deployment parameters

The intended network is **Sepolia, chain ID 11155111**. No chain transactions have been
performed. Every constructor is nonpayable and complete; no initialization call is needed.

| Order | Source / identifier | Constructor arguments |
| --- | --- | --- |
| Token | `src/LaunchToken.sol:LaunchToken` | None |
| Application 1 | `src/GrantExecutor.sol:GrantExecutor` | `address operator_` |
| Application 2 | `src/CityRegistry.sol:CityRegistry` | `address token_`, `address grantExecutor_` |

`LaunchToken` has name **Swarm Cities**, symbol **GRID**, 18 decimals, and mints exactly
`1000000000000000000000000000` minor units (one billion GRID) once to its constructor
caller, which is the factory. It has no owner, later minting, upgrade mechanism, pause,
blocklist, or fee configuration. Holder burns and approved-spender `burnFrom` reduce
supply; burns emit `Transfer(from, address(0), amount)` and do not credit a zero-address
balance. Application constructors neither move nor burn the factory's launch supply.

The manifest should identify `GrantExecutor` before `CityRegistry`. Registry address
arguments are `$token` and `$contract:GrantExecutor`, respectively. The executor's
operator is an explicit address argument, never constructor `msg.sender`.

**The approved operator and treasury are both
`0x5b95A971B4583A5f011E9DA082acdD679b870D06`.** `CityRegistry` derives its immutable
treasury from `GrantExecutor.operator()`. Constructors reject zero/missing dependencies
but do not hard-code that wallet. A different operator parameter would redirect both
privileged grant access and treasury payments and violate the workflow. If the canonical
manifest uses `$owner`, the policy owner must equal this approved address. If it does not,
that is an unresolved authorization conflict for the manifest reviewer, not permission to
substitute another wallet. The manifest service must verify the actual encoded arguments.

Constructors check deployed dependency code and token decimals. They do not prove that
arbitrary contracts are authentic: deployment must use the reviewed LaunchToken and
GrantExecutor bytecode. The hostile-token tests establish defensive behavior, not support
for arbitrary rebasing or malicious tokens.

## City and pool behavior

- Plot IDs are 0–255; `x = id % 16`, `y = id / 16`. `cityOf(wallet)` is zero for no
  ownership, otherwise **id + 1**, so plot zero is unambiguous. A wallet may own one city;
  this does not establish one city per human. Cities cannot be transferred or abandoned.
- A buyer must hold at least 1,000 GRID before payment and also afford the full price.
  The price is `10000 * 1e18 * (256 + soldPlots)^2 / 65536`, rounded down only at the
  final division into minor units. The first city costs 10,000 GRID. Approve the registry
  for **exactly the displayed and accepted quote**; `buyCity(id)` burns the live price and
  starts level 1, resources 0. An intervening purchase raises the price; an exact allowance
  makes a stale quote revert. An oversized or unlimited allowance permits a higher burn.
  The frontend must replace any existing allowance with the exact quote, wait for that
  approval to confirm, and never silently increase it after a stale-quote failure. Display
  and obtain acceptance of a fresh quote before retrying. See `docs/ABI.md` for the flow.
- Level `n` to `n+1` costs `100 * (n+1)^2` **whole resources**, with maximum level 20.
  Only the city owner can level or claim. A level change settles old rewards before
  changing weight, so the new level earns only subsequent distributions.
- `fundRewards(amount)` and `fundResources(amount)` debit approved minor GRID units.
  Direct ERC-20 transfers into the registry do not fund either accounting pool. Such
  donations remain inaccessible surplus: there is deliberately no administrator sweep.
- Reward weight is `level^2`. Rewards accrue on funding or the optional fee route,
  independently of heartbeat timing. Funding before any city exists is queued and awarded
  to the first city. Later buyers do not share earlier rewards, apart from tiny global
  division dust. Claims are fee-free and retain fractional minor-unit credits for later.
  Accumulator precision is `1e27`; global remainder is carried into the next distribution.
  Following a weight change, fewer than `102400 / 1e27` minor units of old remainder can
  be shared under the new weights. There is no claim-all loop or owner withdrawal.
- One granted resource allocates **one GRID (1e18 minor units)** from the resource pot.
  Fractional GRID below one resource waits for further funding. `allocatedResourceBacking`
  covers unspent resources. When leveling consumes resources, the registry burns the
  corresponding GRID and reduces that backing atomically. A failed burn reverts the level,
  resource, weight, and reward-credit changes. Individual and heartbeat grants use the
  same accounting; granting alone does not burn. Resources cannot be redeemed, transferred,
  or regranted. This revision resolves spent-resource custody by burning on consumption:
  reaching level 20 consumes and burns 286,900 resources/GRID per city, in addition to its
  purchase burn. Unspent grants (including excess grants at level 20) retain backing and
  have no redemption or recovery path. No operator receives the consumed backing.
- `rewardsPool` and `resourcePot` are available accounting balances, not separate wallet
  addresses. The registry's token balance covers these two balances plus unspent-resource backing.
  Forced/direct token donations can increase custody without increasing these balances.

## Optional fee route

`transferWithTax(to, grossAmount)` requires approval for the full gross amount. The fee
is `ceil(grossAmount / 25)`; the recipient gets `grossAmount - fee`. Resources receive
`floor(fee * 3 / 10)`, `floor(fee / 10)` is burned, treasury receives `floor(fee / 10)`,
and rewards receive the remaining fee, including all split dust (at most three minor
units above `floor(fee / 2)`). Every positive gross amount pays at least one minor unit;
rounding up the levy adds less than one minor unit over exactly 4%. The split is exactly
50/30/10/10 when the fee is divisible by ten. For 1,000 GRID, the result is 960 to the
recipient, 20 to rewards, 12 to resources, 4 burned, and 4 to treasury. For 24 minor units,
the recipient receives 23 and rewards receive 1; for a single minor unit, the recipient
receives zero. Individual burn/resource/treasury shares can round to zero. The frontend
must show the rounded net and fee. Ordinary ERC-20 transfers still bypass this route.
Zero amount and zero/registry recipient are rejected. All debits, allocations, burns,
and sends revert together if an operation fails. There is no ETH fee or ETH entrypoint.

## Grant operation and responsibility

Only the configured operator can call the executor. It forwards typed
`grantResources(registry, cityId, amount)` and
`recordHeartbeat(registry, cityId1, amount1, cityId2, amount2, cityId3, amount3)` calls.
The registry target is passed per call so the executor can be deployed first; the registry
itself accepts grants only from its immutable executor. The executor cannot make arbitrary
calls, spend users' approvals, withdraw funds, or change its operator.

Heartbeat winners must be three distinct, owned, in-range plots with positive resource
amounts. All three grants must fit the pot, or the whole transaction reverts, preserving
the previous heartbeat. Success stores IDs, amounts, a sequence number, and timestamp.
Individual grants leave the last heartbeat unchanged. There is no enforced cadence or
on-chain ranking, randomness, tweet verification, or replay identifier: the operator
selects winners off-chain and may make repeated awards while funds remain. That operator
can preferentially allocate resources, indirectly affecting future reward weights.

Only the same operator can pause/unpause executor grants. Buying, funding, leveling,
optional fee routing, token transfers, and reward claims remain live. There is no general
emergency pause, key rotation, upgrade, or recovery path; loss of the operator key can
permanently disable future grants. Current owners retain their claims and city operations.

The source received an additional agent review and adversarial local tests during this
assignment. This is not the separate contributor review required for release. The final
independent reviewer must inspect accepted source **and** the generated manifest, confirm
operator/treasury linkage, and resolve the tax conflict and resource assumptions. Services
own source publication, signed artifact/policy linkage, admission, deployment, explorer
verification, and the subsequent frontend/IPFS publication. Those activities are not
performed here. Slither and Mythril were not run; local Foundry results are not an audit.
