// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {CityRegistry} from "src/CityRegistry.sol";
import {GrantExecutor} from "src/GrantExecutor.sol";

/// @dev An eager, per-city reward oracle: no use of the registry's accumulator,
/// reward indexes, remainder, or preview when computing earned rewards. Ownership,
/// levels and resources are modeled from successful calls and their inputs.
contract RewardModelHandler is Test {
    uint256 public constant N = 6;
    uint256 public constant PRECISION = 1e27;
    address public constant OPERATOR = 0x5b95A971B4583A5f011E9DA082acdD679b870D06;
    LaunchToken public immutable token;
    CityRegistry public immutable registry;
    GrantExecutor public immutable executor;
    address[6] public actors;
    uint256[6] public plots = [uint256(0), 15, 16, 127, 240, 255];
    uint256[6] public levels;
    uint256[6] public resources;
    uint256[6] public earnedScaled;
    uint256[6] public paid;
    uint256 public fundedRewards;
    uint256 public fundedResources;
    uint256 public granted;
    uint256 public consumed;
    uint256 public burned;
    uint256 public queued;
    uint256 public successfulClaims;
    uint256 public successfulLevels;
    uint256 public rejectedCalls;
    uint256 public heartbeats;
    uint256 public heartbeatTime;
    uint256[3] public winners;
    uint256[3] public awards;
    bool public paused;

    constructor() {
        token = new LaunchToken();
        executor = new GrantExecutor(OPERATOR);
        registry = new CityRegistry(address(token), address(executor));
        token.approve(address(registry), type(uint256).max);
        for (uint256 i; i < N; ++i) {
            actors[i] = address(uint160(0xC17000 + i));
            token.transfer(actors[i], 10_000_000 ether);
            vm.prank(actors[i]);
            token.approve(address(registry), type(uint256).max);
        }
    }

    function buy(uint256 seed) public {
        uint256 i = seed % N;
        if (levels[i] != 0) {
            vm.expectRevert(CityRegistry.AlreadyOwnsCity.selector);
            vm.prank(actors[i]);
            registry.buyCity(17); // Always empty; never an occupied-plot false positive.
            ++rejectedCalls;
            return;
        }
        uint256 price = registry.cityPrice();
        uint256 beforeBalance = token.balanceOf(actors[i]);
        vm.prank(actors[i]);
        registry.buyCity(plots[i]);
        assertEq(beforeBalance - token.balanceOf(actors[i]), price);
        levels[i] = 1;
        burned += price;
        if (queued != 0) {
            earnedScaled[i] += queued * PRECISION;
            queued = 0;
        }
    }

    function fundRewards(uint256 seed) public {
        // Frequently exercise one wei and other sub-token amounts.
        uint256 amount = seed % 4 == 0 ? bound(seed, 1, 101) : bound(seed, 1, 100_000 ether);
        registry.fundRewards(amount);
        _creditRewards(amount);
    }

    function fundResources(uint256 seed) public {
        uint256 amount = bound(seed, 1, 1_000_000 ether);
        registry.fundResources(amount);
        fundedResources += amount;
    }

    function taxedTransfer(uint256 seed, uint256 recipientSeed) public {
        // Multiples of 250 give exact 50/30/10/10 splits; no copied rounding formula.
        uint256 units = bound(seed, 1, 100 ether);
        registry.transferWithTax(actors[recipientSeed % N], 250 * units);
        _creditRewards(5 * units);
        fundedResources += 3 * units;
        burned += units;
    }

    function grant(uint256 seed, uint256 amountSeed) public {
        uint256 i = seed % N;
        uint256 amount = bound(amountSeed, 1, 300_000);
        bytes4 failure;
        if (paused) {
            failure = GrantExecutor.GrantsPaused.selector;
        } else if (levels[i] == 0) {
            failure = CityRegistry.CityNotOwned.selector;
        } else if (amount > (fundedResources - granted * 1 ether) / 1 ether) {
            failure = CityRegistry.InsufficientResourcePot.selector;
        }
        if (failure != bytes4(0)) {
            vm.expectRevert(failure);
            vm.prank(OPERATOR);
            executor.grantResources(address(registry), plots[i], amount);
            ++rejectedCalls;
        } else {
            vm.prank(OPERATOR);
            executor.grantResources(address(registry), plots[i], amount);
            resources[i] += amount;
            granted += amount;
        }
    }

    function heartbeat(uint256 seed, uint256 amountSeed) public {
        uint256 i = seed % 3; // First three cities always exist after setUp.
        uint256 j = (i + 1) % 3;
        uint256 k = (i + 2) % 3;
        uint256 amount = bound(amountSeed, 1, 10_000);
        bytes4 failure;
        if (paused) {
            failure = GrantExecutor.GrantsPaused.selector;
        } else if (6 * amount > (fundedResources - granted * 1 ether) / 1 ether) {
            failure = CityRegistry.InsufficientResourcePot.selector;
        }
        if (failure != bytes4(0)) {
            vm.expectRevert(failure);
            vm.prank(OPERATOR);
            executor.recordHeartbeat(
                address(registry), plots[i], amount, plots[j], 2 * amount, plots[k], 3 * amount
            );
            ++rejectedCalls;
        } else {
            vm.warp(vm.getBlockTimestamp() + 1);
            vm.prank(OPERATOR);
            executor.recordHeartbeat(
                address(registry), plots[i], amount, plots[j], 2 * amount, plots[k], 3 * amount
            );
            resources[i] += amount;
            resources[j] += 2 * amount;
            resources[k] += 3 * amount;
            granted += 6 * amount;
            ++heartbeats;
            heartbeatTime = vm.getBlockTimestamp();
            winners = [plots[i], plots[j], plots[k]];
            awards = [amount, 2 * amount, 3 * amount];
        }
    }

    function level(uint256 seed) public {
        uint256 i = seed % N;
        uint256 cost = 100 * (levels[i] + 1) ** 2;
        bytes4 failure;
        if (levels[i] == 0) failure = CityRegistry.NotCityOwner.selector;
        else if (levels[i] == 20) failure = CityRegistry.MaximumLevel.selector;
        else if (resources[i] < cost) failure = CityRegistry.InsufficientResources.selector;
        if (failure != bytes4(0)) {
            vm.expectRevert(failure);
            vm.prank(actors[i]);
            registry.levelUp(plots[i]);
            ++rejectedCalls;
        } else {
            vm.prank(actors[i]);
            registry.levelUp(plots[i]);
            ++levels[i];
            resources[i] -= cost;
            consumed += cost;
            burned += cost * 1 ether;
            ++successfulLevels;
        }
    }

    function claim(uint256 seed) public {
        uint256 i = seed % N;
        uint256 quote = registry.claimableRewards(plots[i]);
        if (levels[i] == 0 || quote == 0) {
            vm.expectRevert(
                levels[i] == 0 ? CityRegistry.NotCityOwner.selector : CityRegistry.NoRewards.selector
            );
            vm.prank(actors[i]);
            registry.claimRewards(plots[i]);
            ++rejectedCalls;
            return;
        }
        uint256 beforeBalance = token.balanceOf(actors[i]);
        vm.prank(actors[i]);
        uint256 amount = registry.claimRewards(plots[i]);
        assertEq(amount, quote, "claim must pay its quote");
        assertEq(token.balanceOf(actors[i]) - beforeBalance, amount, "actual payout");
        paid[i] += amount;
        ++successfulClaims;
        vm.expectRevert(CityRegistry.NoRewards.selector);
        vm.prank(actors[i]);
        registry.claimRewards(plots[i]);
        ++rejectedCalls;
    }

    function togglePause() public {
        vm.prank(OPERATOR);
        if (paused) executor.unpause();
        else executor.pause();
        paused = !paused;
    }

    function unauthorized(uint256 seed, uint256 operation) public {
        uint256 i = seed % 3;
        address attacker = actors[(i + 1) % N];
        operation %= 7;
        bytes4 failure = operation < 2
            ? CityRegistry.NotCityOwner.selector
            : operation < 4 ? CityRegistry.UnauthorizedExecutor.selector : GrantExecutor.Unauthorized.selector;
        vm.expectRevert(failure);
        vm.prank(attacker);
        if (operation == 0) registry.claimRewards(plots[i]);
        else if (operation == 1) registry.levelUp(plots[i]);
        else if (operation == 2) registry.grantResources(plots[i], 1);
        else if (operation == 3) registry.recordHeartbeat(0, 1, 15, 1, 16, 1);
        else if (operation == 4) executor.grantResources(address(registry), plots[i], 1);
        else if (operation == 5) executor.pause();
        else executor.unpause();
        ++rejectedCalls;
    }

    function _creditRewards(uint256 amount) private {
        fundedRewards += amount;
        uint256 weight;
        for (uint256 i; i < N; ++i) {
            weight += levels[i] ** 2;
        }
        if (weight == 0) {
            queued += amount;
            return;
        }
        for (uint256 i; i < N; ++i) {
            earnedScaled[i] += amount * PRECISION * levels[i] ** 2 / weight;
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract RewardModelInvariantTest is Test {
    RewardModelHandler private handler;
    CityRegistry private registry;
    LaunchToken private token;

    function setUp() public {
        handler = new RewardModelHandler();
        registry = handler.registry();
        token = handler.token();
        handler.fundRewards(17);
        handler.fundResources(1_000_000 ether);
        for (uint256 i; i < 3; ++i) {
            handler.buy(i);
        }
        handler.grant(0, 300_000);
        handler.level(0);
        handler.fundRewards(7);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.fundRewards.selector;
        selectors[2] = handler.fundResources.selector;
        selectors[3] = handler.taxedTransfer.selector;
        selectors[4] = handler.grant.selector;
        selectors[5] = handler.heartbeat.selector;
        selectors[6] = handler.level.selector;
        selectors[7] = handler.claim.selector;
        selectors[8] = handler.togglePause.selector;
        selectors[9] = handler.unauthorized.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_EntitlementsOwnershipAndCustodyMatchIndependentHistory() public view {
        _assertModel();
    }

    function afterInvariant() public {
        // Every owner can collect after an arbitrary sequence, even if grants are paused.
        for (uint256 i; i < handler.N(); ++i) {
            handler.claim(i);
        }
        _assertModel();
    }

    function testModelExercisesClaimsRejectionsHeartbeatsAndMaximumLevel() public {
        handler.heartbeat(0, 10);
        handler.togglePause();
        handler.buy(5);
        handler.grant(0, 1);
        handler.fundRewards(100 ether);
        handler.claim(0);
        for (uint256 i; i < 19; ++i) {
            handler.level(0);
        }
        handler.togglePause();
        handler.taxedTransfer(250, 2);
        handler.fundResources(100 ether);
        for (uint256 i; i < 7; ++i) {
            handler.unauthorized(0, i);
        }
        afterInvariant();
        assertEq(handler.levels(0), 20);
        assertGt(handler.successfulClaims(), 0);
        assertEq(handler.successfulLevels(), 19);
        assertEq(handler.consumed(), 286_900, "total resource cost of levels 2 through 20");
        assertGt(handler.rejectedCalls(), 0);
        assertEq(handler.heartbeats(), 1);
    }

    function testModelTracksConsumptionWithoutReplenishingTheGrantPot() public {
        // setUp already upgraded the first city once, consuming 400 resources.
        _assertModel();
        assertEq(handler.consumed(), 400);
        uint256 pot = registry.resourcePot();
        uint256 supply = token.totalSupply();
        handler.level(0); // Level 2 -> 3 consumes another 900 resources.
        _assertModel();
        assertEq(handler.consumed(), 1300);
        assertEq(token.totalSupply(), supply - 900 ether);
        assertEq(registry.resourcePot(), pot, "consumption never refunds the grant pot");

        handler.grant(1, 300_000);
        handler.grant(2, 300_000);
        handler.grant(0, 100_000);
        _assertModel();
        assertEq(registry.resourcePot(), 0);

        handler.level(1);
        _assertModel();
        assertEq(handler.consumed(), 1700);
        uint256 rejected = handler.rejectedCalls();
        uint256 granted = handler.granted();
        supply = token.totalSupply();
        handler.grant(1, 1); // Burned backing cannot be awarded again.
        handler.heartbeat(0, 1);
        _assertModel();
        assertEq(handler.rejectedCalls(), rejected + 2);
        assertEq(handler.granted(), granted);
        assertEq(token.totalSupply(), supply, "failed grants cannot burn backing");
    }

    function _assertModel() private view {
        uint256 totalPaid;
        uint256 weight;
        uint256 sold;
        uint256 unspentResources;
        uint256 balances = token.balanceOf(address(handler)) + token.balanceOf(address(registry))
            + token.balanceOf(handler.OPERATOR());
        for (uint256 i; i < handler.N(); ++i) {
            uint256 plot = handler.plots(i);
            uint256 expectedLevel = handler.levels(i);
            address actor = handler.actors(i);
            (address owner, uint256 level, uint256 resources,,) = registry.cities(plot);
            assertEq(owner, expectedLevel == 0 ? address(0) : actor, "soulbound ownership");
            assertEq(registry.cityOf(actor), expectedLevel == 0 ? 0 : plot + 1);
            assertEq(level, expectedLevel, "level follows only successful upgrades");
            assertEq(resources, handler.resources(i), "grants minus consumption");
            unspentResources += handler.resources(i);
            if (level != 0) ++sold;
            weight += expectedLevel ** 2;
            uint256 paid = handler.paid(i);
            uint256 entitlement = paid + registry.claimableRewards(plot);
            // Different eager vs lazy division orders can straddle ONE minor unit.
            // At depth 128, cumulative scaled rounding is <128*2400 << 1e27.
            // Tolerance is independent of reward magnitude and number of claims.
            assertApproxEqAbs(
                entitlement,
                handler.earnedScaled(i) / handler.PRECISION(),
                1,
                "historical level-squared share"
            );
            totalPaid += paid;
            balances += token.balanceOf(actor);
        }
        assertEq(registry.soldPlots(), sold);
        assertEq(registry.totalWeight(), weight);
        assertEq(registry.queuedRewards(), handler.queued());
        assertEq(registry.rewardsPool() + totalPaid, handler.fundedRewards(), "no missing reward deposits");
        assertEq(registry.resourcePot() + handler.granted() * 1 ether, handler.fundedResources());
        assertEq(handler.granted(), unspentResources + handler.consumed(), "every resource is accounted for");
        assertEq(registry.allocatedResourceBacking(), unspentResources * 1 ether);
        assertEq(
            token.balanceOf(address(registry)) + handler.consumed() * 1 ether,
            registry.rewardsPool() + handler.fundedResources(),
            "resource funding remains in custody or is burned on consumption"
        );
        assertEq(balances, token.totalSupply(), "complete closed actor set conserves supply");
        assertEq(token.totalSupply() + handler.burned(), 1_000_000_000 ether);
        assertEq(handler.executor().paused(), handler.paused());
        assertEq(handler.executor().operator(), handler.OPERATOR());
        assertEq(registry.heartbeatCount(), handler.heartbeats());
        assertEq(registry.lastHeartbeatTimestamp(), handler.heartbeatTime());
        for (uint256 i; i < 3; ++i) {
            assertEq(registry.lastHeartbeatCityIds(i), handler.winners(i));
            assertEq(registry.lastHeartbeatAmounts(i), handler.awards(i));
        }
    }
}
