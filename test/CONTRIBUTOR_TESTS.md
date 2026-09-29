# Additional adversarial tests

`WorkflowEdges.t.sol` checks stale price approvals, partial heartbeat rollback with a
one-wei resource shortfall, maximum grant inputs, out-of-range IDs, large reward
funding, and claim-frequency independence. Three boundary properties run 1,000 cases
each; the claim-timing comparison runs 256 cases.

`RewardModelInvariant.t.sol` runs 256 sequences of 128 calls across six actors.
Its eager per-city reward model uses the funding history and ghost levels, independently
of the implementation's lazy reward accumulator. Lifetime payouts plus outstanding
claims must match level-squared allocations within one minor unit, regardless of
claim frequency. At this sequence length, accumulated rounding error is far below one
minor unit; the tolerance permits crossing an integer boundary, not proportional loss.
Separate exact checks cover ownership, resource accounting, pool custody, supply,
authorization, pause state, and heartbeat history. Expected failures are exercised
inside the handler; any unexpected revert fails the campaign. A deterministic sequence
reaches level 20, and each randomized sequence ends by attempting every owner's claim.

The resource model now tracks consumption separately from cumulative grants, reflecting
the accepted contract revision that burns backing on level-up. Unspent resources must
equal allocated backing, and resource deposits must remain in custody or have been
burned on consumption. The regression sequence checks these identities after upgrades,
exhausts the grant pot, and verifies that burning allocated backing does not make it
available for a second grant or heartbeat. Reaching level 20 consumes exactly 286,900
resources. The reward oracle and its one-minor-unit rounding tolerance are unchanged.

`FullGridLimits.t.sol` drives the registry to its largest reachable state: all 256 plots
sold and every city at level 20, the maximum reward weight of 102,400. There it checks that
the grid is closed to every purchase, quote and upgrade, that one wei of funding rounds to
nothing for every city with no remainder, that funding exactly the weight in wei pays each
city exactly its level squared, and that the entire remaining supply splits equally within
one wei per city and is claimed in full. It pins grants to a level-20 city as accepted but
unusable with their backing kept in custody, self-transfers and the treasury as recipients
on the explicit levy route, the executor-wide scope of pause across two registries, and
forwarding to a contract that is not a registry. Two fuzz properties cover the coordinate
round-trip across the grid walk and equal shares for equal levels at every level and
funding size.

Run without writing build artifacts outside the permitted scratch directory:

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
forge test --out test/scratch/out --cache-path test/scratch/cache
```

The universal-transfer-tax requirement remains unmet and conflicts with the protected
exact-transfer check. The separately submitted `.imd-findings.json` contains the
reproduced failing proof. These tests extend the accepted suite and do not resolve that
source requirement. They need only the already-vendored dependencies and no RPC or
environment configuration.
