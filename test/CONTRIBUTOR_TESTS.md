# Transfer tax and adversarial tests

The production `LaunchToken` is used by token, city, full-grid, and accounting/model
suites. The hostile dependency in `Adversarial.t.sol` remains an explicit test double
for rejected receipts/payouts and reentrancy; it is not evidence of GRID tax behavior.
Some city unit-test fixtures seed precise balances with `deal` to isolate acquisition
and reward arithmetic. The stateful model and full-grid tests exercise real taxed
funding and payouts throughout.

`LaunchToken.t.sol` pins the 400-bps direct and allowance-based transfer behavior,
all four allocations and their sum, event fields, rounding, alias addresses, finite
and infinite allowances, explicit burns, zero/maximum inputs and failure rollback.
The fixed-value regressions must fail against a fee-free transfer implementation.
`TransferTax.t.sol` covers one-time registry binding, escrow release, callback
permissions and atomicity, funding, taxed claims and recipient/beneficiary overlap.

`RevisionFindings.t.sol` replaces the earlier fee-free evidence with required universal
tax behavior and preserves purchase-approval, resource-backing and level-up regressions.
`CityRegistry.t.sol` retains soulbound city, price, holding, grant, resource, reward,
heartbeat and pause tests while asserting gross debits and net payouts.
`WorkflowEdges.t.sol` checks stale quote approvals, partial heartbeat rollback,
maximum/out-of-range inputs, large funding and conservation across repeated taxed
claims. Claim timing can affect subsequent revenue because payouts now generate tax;
it is no longer correct to assume claim-frequency independence.

`AccountingInvariant.t.sol` checks 64 sequences of 64 calls. It reconciles custody
with all reward/resource liabilities, scaled credits, city weights, resource grants
and consumption, and every burn, including funding and payout taxes.
`RewardModelInvariant.t.sol` checks 256 sequences of 128 calls across six actors.
Its independent eager per-city oracle records both explicit funding and transfer-tax
revenue, without using the contract's lazy reward accumulator to calculate entitlement.
It checks payouts plus outstanding claims against each history within one minor unit,
as well as supply, resources, permissions, heartbeat history and pause state. Unexpected
reverts fail both invariant campaigns. A deterministic sequence reaches level 20.

`FullGridLimits.t.sol` fills all 256 plots and levels every city to 20, attaining maximum
weight 102,400. It verifies limits, new equal-weight allocations, taxed claims and the
resulting recycled rewards, whole-resource backing, self/treasury recipients, pause
scope across multiple registries, and invalid forwarding targets. Fuzz cases cover
coordinates and equal-level funding. Pool-zero assumptions were replaced with exact
accounting for remaining/recycled reserves.

```sh
forge build
forge test
forge fmt --check
python3 scripts/export_abi.py --check
```

All checks use the unchanged configuration and its pinned Solidity 0.8.26 compiler.
Tests require no RPC, network, environment variables, filesystem permissions or FFI.
Independent review repros may live in `test/scratch/`; that directory is discarded by
the verifier and is not needed by the delivered suite.
