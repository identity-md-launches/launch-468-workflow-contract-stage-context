# Independent transfer-tax review

Reviewed on 2026-09-29 by a separate adversarial review agent after implementation.
The reviewer did not implement or edit production contracts. No actionable security
finding was identified in the reviewed canonical LaunchToken/CityRegistry pair.
Deployment and integration assumptions below remain requirements for any later release.
This is an independent agent review, not an external audit or the contributor network's
separate release approval.

## Scope and source identity

Reviewed the changes from baseline `77dfba03d98c68ac600d72e82b23b885915bf1aa` to
`src/LaunchToken.sol`, `src/CityRegistry.sol`, and `src/interfaces/IGridToken.sol`;
the unchanged `src/GrantExecutor.sol`; vendored OpenZeppelin 5.1.0 transfer/burn logic;
the token, binding, city, hostile-dependency, workflow, and accounting tests; README,
ABI documentation, and `launch.json`. Pinned project history and security references
were read as supporting data. No network requests or chain transactions were needed.

Reviewed production source SHA-256 hashes:

| File | SHA-256 |
| --- | --- |
| `src/LaunchToken.sol` | `ceb314f8038c1c59b9cf9056533f798893e5932ca64df400d5fc1670a3a0af1b` |
| `src/CityRegistry.sol` | `dd76eee91bb8391874c92db98dd9accbd86b7ae26586e1084f3671048e53a98e` |
| `src/interfaces/IGridToken.sol` | `6e5031251a1c62e55633e3e3f02a0a55fd6f3092337e4d5ac356c0d47c2cf976` |
| `src/GrantExecutor.sol` | `42c054b0c6a2f5f61a39eaa53d590993f0e5c7032249e6d26997f7c04b09c2f4` |

Independent comparison confirmed that `cityPrice`, `buyCity`, `levelUpCost`, `levelUp`,
`claimableRewards`, `claimRewards`, coordinates, grant/heartbeat functions and their
accounting/ownership helpers have identical function definitions and bodies to baseline.
The entire GrantExecutor file is unchanged. The changed token transfer behavior applies
to the existing claim call without changing its gross entitlement calculation.

## Findings and checked properties

No critical, high, medium, or low security finding was reproduced within this scope.

- **Universal transfer path and conservation:** both inherited ERC-20 entrypoints reach
  `LaunchToken._update` at line 75. Tax is `floor(gross / 25)`, resources receive
  `floor(3 * tax / 10)`, burn and treasury receive `floor(tax / 10)` each, and rewards
  receive the remainder. The four allocations sum exactly to tax. Internal allocation
  uses base updates and cannot recursively levy another tax. The burn reduces supply
  and emits a zero-address transfer without creating a zero-address balance.
- **Aliases and gross authorization:** the balance check at LaunchToken lines 80–82
  runs before any recipient/beneficiary credit. Self-transfers and treasury/registry
  overlaps therefore cannot authorize an amount exceeding the sender's gross balance.
  ERC-20 allowance consumption uses the gross amount, including self-transfers; failed
  transfers restore allowance, balances, supply, pending tax, and callback effects.
- **Routing authority and escrow:** LaunchToken lines 48–67 restrict binding to the
  constructor caller, reject a second binding, validate token/treasury wiring, and move
  only recorded escrow. Pending balances are cleared before the callback. A callback
  failure reverts both binding and escrow movement. Ordinary callers cannot redirect
  taxes or forge pool credits. Direct donations are excluded from recorded escrow.
- **Funding and callback accounting:** CityRegistry lines 243–254 separate net funding
  from tax credits already booked by the callback and verify the complete custody
  increase. Before binding, only net funding is credited; subsequent binding credits
  escrow once. Funding, claiming, and then binding also preserve reserve backing.
- **Claim callback and reentrancy:** CityRegistry lines 163–171 settle and debit gross
  rewards before transfer. Its token-only callback at lines 197–202 has no external
  calls and may run during the guarded claim/funding operation. Newly collected reward
  tax becomes subsequent entitlement instead of being erased by the original claim.
  Hostile-token attempts to reenter guarded claims, funding, purchases, and leveling
  revert without duplicating the operation.
- **Permissions and unchanged economics:** city ownership, purchase pricing and full
  purchase burns, level costs/resource-backing burns, and executor/operator/pause
  permissions retain their original source logic. Explicit burns are not taxed.

## Validation performed by the independent reviewer

Used Foundry 1.8.3, the unchanged project configuration, pinned Solidity **0.8.26**,
Cancun EVM, and optimizer 200. The reviewer ran:

```sh
forge test \
  --match-contract 'LaunchTokenTest|TransferTaxIntegrationTest|AdversarialTest|IndependentTransferTaxReviewTest' \
  --fuzz-runs 1024 \
  --out test/scratch/review-out \
  --cache-path test/scratch/review-cache -vv
```

Result: **64 tests passed, zero failed, zero skipped** across four suites:
27 token tests, 21 binding/integration tests, 12 hostile-dependency tests, and four
independently written scratch probes. Four fuzz properties each ran 1,024 cases.
The scratch probes cover mixed funding/claim activity before binding, a treasury-owned
city claim, unauthorized tax callbacks, and randomized sender/recipient/beneficiary
overlaps with independent balance/supply arithmetic. Alias fuzzing uses impersonation
to test token arithmetic; it does not claim that the real token/registry exposes an
arbitrary-transfer or approval function.

Scratch probes were written and run under `test/scratch/IndependentTransferTaxReview.t.sol`
and archived outside the repository after review, at
`/tmp/grid-tax-independent-review-sxk3c6mu/scratch/`. They are ephemeral local evidence,
excluded from submission; delivered regressions do not depend on them. Production
source and compiler settings were unchanged by the reviewer.

The implementing agent separately supplied mutation evidence from isolated temporary
copies: replacing only `transfer`, then only `transferFrom`, with fee-free movement
while retaining plausible `TaxTaken` events caused each corresponding fixed-value
regression to fail its recipient balance assertion (25,000 versus 24,000 GRID and
750 versus 720 GRID). This supports regression sensitivity and is distinguished from
the independent reviewer's own runs. Final whole-project build/test/format/ABI checks
are recorded by the implementing agent separately.

## Assumptions and limitations

1. **The deploying authority must choose and bind the reviewed registry.** Getter checks
   establish wiring, not code authenticity. A malicious receiver selected by that
   authority could misroute pool tax or revert future taxed transfers. There is no
   recovery or replacement setter. A deploying factory must support the authorized
   `setCityRegistry` call; this review did not verify any live factory implementation.
   `launch.json` describes setup but does not execute it. Bind before opening the app
   or distributing supply; otherwise pool revenues remain escrowed and their eventual
   allocation follows the cities present when binding occurs.
2. **Manifest policy must resolve `$owner` to the approved treasury/operator address.**
   Another executor operator retains its own grant authority but makes that registry
   fail LaunchToken's fixed-treasury binding check. Services must verify encoded
   constructor arguments and the factory binding path before release.
3. **Integer rounding is explicit.** Amounts below 25 minor units produce zero tax;
   splitting into such dust amounts can avoid rounded fees. Split dust goes to rewards,
   so exact 50/30/10/10 proportions occur when tax is divisible by ten. No minimum fee
   was added. Zero transfers emit zero-valued tax events.
4. **Transfers into external integrations are fee-on-transfer.** Manifest pool fields
   do not prove router/pool compatibility or admission support. No DEX, factory,
   explorer, live token, or network behavior was tested. Existing immutable deployments
   remain unchanged by this source revision.
5. **Documented application behavior remains material.** Claims report gross amounts
   and pay net; their tax creates additional reward/resource credits. Claim timing can
   change later tax revenue allocations. Direct donations leave inaccessible surplus;
   first-city queued rewards and executor-selected grants retain their existing
   economic implications. Tests against hostile tokens establish specific defensive
   behavior, not general support for arbitrary token implementations.

No Slither, Mythril, formal verification, external audit, chain deployment, or live-wallet
operation was performed by this reviewer. Passing local checks does not replace the
separate contributor release review or service-owned publication/admission verification.
