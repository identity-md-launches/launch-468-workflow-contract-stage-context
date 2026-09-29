// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {GrantExecutor} from "../src/GrantExecutor.sol";
import {CityRegistry} from "../src/CityRegistry.sol";

/// @dev Calls only the real contracts and records independent burn/grant/consumption totals.
/// Every selected action either performs a valid operation or returns when its preconditions
/// are unavailable. With fail-on-revert enabled, unexpected reverts fail the invariant run.
contract CityAccountingHandler is Test {
    uint256 public constant ACTOR_COUNT = 8;
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;
    LaunchToken public immutable token;
    GrantExecutor public immutable executor;
    CityRegistry public immutable registry;
    address[8] public actors;
    uint256 public totalBurned;
    uint256 public totalGrantedResources;
    uint256 public totalConsumedResources;

    constructor() {
        token = new LaunchToken();
        executor = new GrantExecutor(address(this));
        registry = new CityRegistry(address(token), address(executor));
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            address actor = address(uint160(0xAC7000 + i));
            actors[i] = actor;
            token.transfer(actor, 20_000_000 ether);
        }
    }

    function buy(uint256 actorSeed, uint256 plotSeed) external {
        uint256 actorIndex = actorSeed % ACTOR_COUNT;
        address actor = actors[actorIndex];
        if (registry.cityOf(actor) != 0) return;
        uint256 price = registry.cityPrice();
        if (token.balanceOf(actor) < price) return;
        // Each actor has its own 32-plot interval; this still exercises different city IDs.
        uint256 cityId = actorIndex * 32 + plotSeed % 32;
        vm.startPrank(actor);
        token.approve(address(registry), price);
        registry.buyCity(cityId);
        vm.stopPrank();
        totalBurned += price;
    }

    function fundRewards(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % ACTOR_COUNT];
        uint256 amount = _fundingAmount(actor, amountSeed);
        if (amount == 0) return;
        vm.startPrank(actor);
        token.approve(address(registry), amount);
        registry.fundRewards(amount);
        vm.stopPrank();
    }

    function fundResources(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % ACTOR_COUNT];
        uint256 amount = _fundingAmount(actor, amountSeed);
        if (amount == 0) return;
        vm.startPrank(actor);
        token.approve(address(registry), amount);
        registry.fundResources(amount);
        vm.stopPrank();
    }

    function taxedTransfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % ACTOR_COUNT];
        address to = actors[toSeed % ACTOR_COUNT];
        uint256 amount = _fundingAmount(from, amountSeed);
        if (amount == 0) return;
        vm.startPrank(from);
        token.approve(address(registry), amount);
        registry.transferWithTax(to, amount);
        vm.stopPrank();
        totalBurned += ((amount + 24) / 25) / 10;
    }

    function grant(uint256 actorSeed, uint256 amountSeed) external {
        uint256 cityIdPlusOne = registry.cityOf(actors[actorSeed % ACTOR_COUNT]);
        uint256 available = registry.resourcePot() / 1 ether;
        if (cityIdPlusOne == 0 || available == 0) return;
        uint256 amount = 1 + amountSeed % _min(available, 50_000);
        executor.grantResources(address(registry), cityIdPlusOne - 1, amount);
        totalGrantedResources += amount;
    }

    function heartbeat(uint256 firstSeed, uint256 amountSeed) external {
        uint256 first = firstSeed % ACTOR_COUNT;
        uint256 id1 = registry.cityOf(actors[first]);
        uint256 id2 = registry.cityOf(actors[(first + 1) % ACTOR_COUNT]);
        uint256 id3 = registry.cityOf(actors[(first + 2) % ACTOR_COUNT]);
        uint256 perCityAvailable = registry.resourcePot() / 1 ether / 3;
        if (id1 == 0 || id2 == 0 || id3 == 0 || perCityAvailable == 0) return;
        uint256 amount = 1 + amountSeed % _min(perCityAvailable, 10_000);
        executor.recordHeartbeat(address(registry), id1 - 1, amount, id2 - 1, amount, id3 - 1, amount);
        totalGrantedResources += 3 * amount;
    }

    function level(uint256 actorSeed) external {
        address actor = actors[actorSeed % ACTOR_COUNT];
        uint256 cityIdPlusOne = registry.cityOf(actor);
        if (cityIdPlusOne == 0) return;
        uint256 cityId = cityIdPlusOne - 1;
        (, uint256 currentLevel, uint256 resources,,) = registry.cities(cityId);
        if (currentLevel == 20) return;
        uint256 cost = 100 * (currentLevel + 1) ** 2;
        if (resources < cost) return;
        vm.prank(actor);
        registry.levelUp(cityId);
        totalConsumedResources += cost;
        totalBurned += cost * 1 ether;
    }

    function claim(uint256 actorSeed) external {
        address actor = actors[actorSeed % ACTOR_COUNT];
        uint256 cityIdPlusOne = registry.cityOf(actor);
        if (cityIdPlusOne == 0 || registry.claimableRewards(cityIdPlusOne - 1) == 0) return;
        vm.prank(actor);
        registry.claimRewards(cityIdPlusOne - 1);
    }

    function _fundingAmount(address actor, uint256 seed) private view returns (uint256) {
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return 0;
        // Include sub-token amounts frequently to expose levy and reward rounding boundaries.
        uint256 limit = seed % 4 == 0 ? 1_000 : 100_000 ether;
        return 1 + seed % _min(balance, limit);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract AccountingInvariantTest is Test {
    CityAccountingHandler private handler;
    LaunchToken private token;
    CityRegistry private registry;

    function setUp() public {
        handler = new CityAccountingHandler();
        token = handler.token();
        registry = handler.registry();
        // Start with rewards awaiting the first buyer and enough resources for grants.
        handler.fundRewards(0, 100);
        handler.fundResources(1, 100_000 ether - 1);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.fundRewards.selector;
        selectors[2] = handler.fundResources.selector;
        selectors[3] = handler.taxedTransfer.selector;
        selectors[4] = handler.grant.selector;
        selectors[5] = handler.heartbeat.selector;
        selectors[6] = handler.level.selector;
        selectors[7] = handler.claim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_CustodyCreditsAndResourceAccountingRemainConserved() public view {
        _assertAccounting();
    }

    function testActionSequenceExercisesEveryAccountingTransition() public {
        _assertAccounting();
        assertEq(registry.queuedRewards(), 101);
        for (uint256 i; i < 4; ++i) {
            handler.buy(i, 255 - i);
            _assertAccounting();
        }
        handler.fundRewards(7, 5_000 ether - 1);
        handler.taxedTransfer(6, 5, 100_000 ether - 1);
        _assertAccounting();
        handler.grant(0, 1_000);
        handler.level(0);
        handler.heartbeat(0, 999);
        handler.level(1);
        handler.level(2);
        _assertAccounting();
        handler.fundRewards(4, 999);
        handler.claim(0);
        handler.claim(1);
        handler.claim(2);
        handler.claim(3);
        _assertAccounting();
        assertGt(handler.totalConsumedResources(), 0);
        assertGt(registry.heartbeatCount(), 0);
        assertEq(registry.queuedRewards(), 0);
    }

    function _assertAccounting() private view {
        assertEq(
            token.balanceOf(address(registry)),
            registry.rewardsPool() + registry.resourcePot() + registry.allocatedResourceBacking(),
            "registry custody equals all pool and resource liabilities"
        );

        uint256 weight;
        uint256 resources;
        uint256 ownedCities;
        uint256 scaledCredits;
        uint256 accumulator = registry.accRewardPerWeight();
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            address actor = handler.actors(i);
            uint256 cityIdPlusOne = registry.cityOf(actor);
            if (cityIdPlusOne == 0) continue;
            (address owner, uint256 level, uint256 remaining, uint256 index, uint256 accrued) =
                registry.cities(cityIdPlusOne - 1);
            assertEq(owner, actor);
            assertGe(level, 1);
            assertLe(level, 20);
            assertLe(index, accumulator);
            ++ownedCities;
            weight += level * level;
            resources += remaining;
            scaledCredits += accrued + level * level * (accumulator - index);
        }

        uint256 scale = registry.REWARD_SCALE();
        assertEq(
            scaledCredits + registry.queuedRewards() * scale + registry.rewardRemainder(),
            registry.rewardsPool() * scale,
            "every scaled reward unit belongs to city credit, queue or remainder"
        );
        assertEq(registry.totalWeight(), weight, "weight is the sum of squared city levels");
        assertEq(registry.soldPlots(), ownedCities);
        assertEq(
            handler.totalGrantedResources(),
            resources + handler.totalConsumedResources(),
            "granted resources are either available or consumed"
        );
        assertEq(
            registry.allocatedResourceBacking(),
            resources * 1 ether,
            "only unspent resources retain GRID backing"
        );
        assertEq(
            token.totalSupply() + handler.totalBurned(),
            handler.INITIAL_SUPPLY(),
            "purchases, the explicit levy and resource consumption account for every burn"
        );
    }
}
