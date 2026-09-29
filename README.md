# Swarm Cities contracts

This source-stage deliverable contains the GRID launch token, soulbound city registry,
grant executor, tests, and compiler-generated ABIs. It contains no deployment transactions,
wallet keys, or frontend. The existing `launch.json` records deployment intent; this
revision changes source only. It does not deploy, replace, upgrade, or re-mint any live token.

## Universal GRID transfer tax

`LaunchToken.transfer` and `transferFrom` deduct **400 basis points (4%)** from the
sent gross amount. For 1,000 GRID, the recipient receives 960 GRID, City Rewards gets
20, Resource Pot gets 12, 4 is burned, and the fixed treasury receives 4. There are no
sender/recipient exemptions: claims, funding, self-transfers, treasury transfers, and
contract transfers all use the same rule. The previous fee-free implementation and
optional-only tax have been replaced. Old exact-transfer admission checks must be
updated to the approved fee-on-transfer requirement before release.

`TaxTaken` is emitted by **LaunchToken**, including gross amount and all four shares.
Both pool shares are credited to the existing registry accounting, backed by its GRID
balance. Until the one-time registry binding, those shares are escrowed in LaunchToken
as `pendingRewards` and `pendingResources`; tax is active from the first transfer.

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
permissions; universal tax and rounding; failed token operations; reentrancy; and CREATE2
constructor execution, runtime bounds, and prohibited opcodes.

## Deployment parameters

The intended network is **Sepolia, chain ID 11155111**. No chain transactions have been
performed by this revision. Every constructor is nonpayable. Token transfers are taxed
immediately, but routing pool revenue requires the one-time binding described below.

| Order | Source / identifier | Constructor arguments |
| --- | --- | --- |
| Token | `src/LaunchToken.sol:LaunchToken` | None |
| Application 1 | `src/GrantExecutor.sol:GrantExecutor` | `address operator_` |
| Application 2 | `src/CityRegistry.sol:CityRegistry` | `address token_`, `address grantExecutor_` |

`LaunchToken` has name **Swarm Cities**, symbol **GRID**, 18 decimals, and mints exactly
`1000000000000000000000000000` minor units (one billion GRID) once to its constructor
caller, which is the factory. It has no owner, later minting, upgrade mechanism, pause,
blocklist, or adjustable fee. Its deploying address has only a one-time registry-binding
power; the rate and treasury cannot be changed. Holder burns and approved-spender `burnFrom` reduce
supply without a transfer tax, preserving city purchase and level-up burns. Burns emit `Transfer(from, address(0), amount)` and do not credit a zero-address
balance. Application constructors neither move nor burn the factory's launch supply.

The manifest should identify `GrantExecutor` before `CityRegistry`. Registry address
arguments are `$token` and `$contract:GrantExecutor`, respectively. The executor's
operator is an explicit address argument, never constructor `msg.sender`.

After both application contracts exist, the **token constructor caller** must call
`LaunchToken.setCityRegistry(registry)` exactly once. If a factory deploys the token,
that factory must expose an authorized way to make this call; an EOA cannot substitute
for it. The caller must verify the reviewed registry bytecode and addresses before
binding. The setter rejects zero/no-code/self addresses, a different token, or a registry
whose treasury differs from the approved treasury, and cannot be called a second time.
Getter checks alone do not authenticate bytecode: selecting the correct registry is a
trust assumption on the deploying authority. Binding transfers only the recorded pool
escrow, without another tax, and credits it through the registry callback. Direct donations
to the token are not included. A failed callback rolls the entire binding back.

Operationally, bind before opening the application or distributing the supply. Before
binding, transfers and burns work, treasury/burn shares settle immediately, and pool shares
wait in escrow. There is no alternate withdrawal, delayed tax activation, reconfiguration,
or recovery mechanism if the deploying factory cannot bind. This additional setup call
must be supported by the publication/admission service; `launch.json` notes it but does
not execute it. Existing immutable deployments cannot acquire this behavior through a
source update; this task authorizes no on-chain migration or deployment.

**The approved operator and treasury are both
`0x5b95A971B4583A5f011E9DA082acdD679b870D06`.** `LaunchToken.TREASURY` hard-codes this wallet. `CityRegistry` retains its immutable
`treasury` derived from `GrantExecutor.operator()`, and token binding requires that it
match. A different operator parameter changes grant authority and prevents binding
that registry; it never redirects the token treasury. If the canonical
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
- `fundRewards(amount)` and `fundResources(amount)` debit the approved **gross** minor
  GRID units. They credit the intended pool with the net amount, in addition to the
  automatic tax shares. For 1,000 GRID funding, reward funding adds 980 rewards and 12
  resources; resource funding adds 20 rewards and 972 resources. The custody check
  separately accounts for tax callback credits so they cannot be counted twice.
  Ordinary direct transfers to the registry credit only their tax shares to the pools;
  the net recipient amount remains inaccessible surplus with no administrator sweep.
- Reward weight is `level^2`. Rewards accrue on funding and every taxed transfer,
  independently of heartbeat timing. Funding before any city exists is queued and awarded
  to the first city. Later buyers do not share earlier rewards, apart from tiny global
  division dust. Claims debit and report the gross entitlement; their token payout is taxed and the
  recipient receives the net. The claim tax can create new claimable rewards immediately.
  Fractional minor-unit credits are retained for later. Claim timing can therefore affect
  later allocations through those new distributions; the original gross entitlement is preserved.
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
  Net direct donations can increase custody beyond these balances.

## Rounding and compatibility route

Tax is `floor(grossAmount * 400 / 10000)`, computed as `grossAmount / 25` without
multiplication overflow. Resources receive `floor(tax * 3 / 10)`, burn and treasury
each receive `floor(tax / 10)`, and rewards receive the remainder. This preserves
`rewards + resources + burned + treasury == tax` for every integer amount; split dust
belongs to rewards (up to three minor units above `floor(tax / 2)`). The split is exactly
50/30/10/10 when tax is divisible by ten. Transfers below 25 minor units round to zero
tax; splitting transfers into dust-sized units can avoid rounded fees. There is no
minimum fee or rounding up. Zero token transfers succeed and emit a zero-valued tax event.
Transfers to zero revert; the burn share uses the base ERC-20 burn update, reduces total
supply, emits `Transfer(from, address(0), burned)`, and never credits the zero address.

`CityRegistry.transferWithTax(to, grossAmount)` remains as a compatibility entrypoint.
It spends the registry allowance once via token `transferFrom(sender, recipient, gross)`;
LaunchToken takes the single universal tax and emits `TaxTaken`. It does not pull then
resend tokens or impose an extra application fee. As before, this registry wrapper
rejects zero amounts and zero/registry recipients. Direct ERC-20 transfers allow zero
amounts and transfers to the registry. Allowances are consumed by **gross** spend,
including self-transfers. OpenZeppelin's unlimited allowance semantics remain unchanged.

When sender or recipient coincides with treasury/registry, its observed balance change
includes its beneficiary share; gross debit and individual transfer legs remain defined.
Self-transfers require the entire gross balance even though their net loss is only tax.
Tax allocation uses base ERC-20 updates, avoiding recursive taxation. All debits, burns,
allowance consumption and callback accounting revert together on failure. The only token
callback goes to the permanently bound registry; its token-only `onTaxReceived` performs
accounting without external calls. It intentionally works during guarded funding/claims.

Integration operators must quote net received amounts and account for fee-on-transfer
behavior. The existing pool manifest is not evidence that its DEX/router supports GRID;
confirm fee-on-transfer support before admission or trading. No DEX compatibility or
on-chain transaction was tested here.

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
the compatibility transfer route, token transfers, and reward claims remain live. There is no general
emergency pause, key rotation, upgrade, or recovery path; loss of the operator key can
permanently disable future grants. Current owners retain their claims and city operations.

The source and tests received a separate adversarial agent review after implementation;
see `docs/TRANSFER_TAX_REVIEW.md` for scope and findings. This is not an external audit
or the contributor network's separate release approval. The release reviewer must inspect
accepted source and manifest, verify the binding path and operator address, and reconcile
any remaining admission or DEX compatibility constraints. Services own source publication,
signed artifact/policy linkage, admission, deployment, explorer verification, and frontend
publication. The approved operator owns grant selection and key security; the treasury
recipient controls its received GRID. Slither and Mythril were not run. Foundry validation
covers local behavior only.
