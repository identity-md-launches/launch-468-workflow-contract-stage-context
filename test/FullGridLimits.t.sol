// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {CityRegistry} from "src/CityRegistry.sol";
import {GrantExecutor} from "src/GrantExecutor.sol";

/// @dev Drives the registry to its largest reachable state (every plot sold, every city at the
/// maximum level, the maximum reward weight) and checks the boundaries there, plus the
/// recipient, pause-scope and forwarding edges the other suites leave to random selection.
/// forge-config: default.fuzz.runs = 256
contract FullGridLimitsTest is Test {
    address private constant OPERATOR = 0x5b95A971B4583A5f011E9DA082acdD679b870D06;
    address private constant ALICE = address(0xA11CE);
    address private constant OUTSIDER = address(0x0075);
    uint256 private constant CITY_COUNT = 256;
    uint256 private constant MAX_WEIGHT = 256 * 20 * 20;
    uint256 private constant RESOURCES_TO_MAX = 286_900;
    LaunchToken private token;
    GrantExecutor private executor;
    CityRegistry private registry;

    function setUp() public {
        token = new LaunchToken();
        executor = new GrantExecutor(OPERATOR);
        registry = new CityRegistry(address(token), address(executor));
        token.setCityRegistry(address(registry));
        token.approve(address(registry), type(uint256).max);
        token.transfer(ALICE, 1_000_000 ether);
        vm.prank(ALICE);
        token.approve(address(registry), type(uint256).max);
    }

    /// @dev All 256 cities reach level 20. New rewards remain proportional to equal weights,
    /// while every claim pays a transfer tax and recycles its rewards share to all owners.
    function testFullGridAtMaximumLevelSplitsRewardsExactlyAndStaysClosed() public {
        uint256 supplyBefore = token.totalSupply();
        (uint256 purchaseBurn, uint256 transferBurn) = _fillGridToMaximumLevel();
        assertEq(registry.soldPlots(), CITY_COUNT);
        assertEq(registry.totalWeight(), MAX_WEIGHT);
        assertEq(registry.allocatedResourceBacking(), 0);
        _assertCustody();
        assertEq(
            token.totalSupply(),
            supplyBefore - purchaseBurn - transferBurn - CITY_COUNT * RESOURCES_TO_MAX * 1 ether,
            "purchases, transfer taxes and consumed resources account for burns"
        );

        vm.expectRevert(CityRegistry.SoldOut.selector);
        registry.cityPrice();
        token.transfer(OUTSIDER, 100_000 ether);
        vm.prank(OUTSIDER);
        token.approve(address(registry), type(uint256).max);
        for (uint256 id; id < CITY_COUNT; ++id) {
            vm.expectRevert(CityRegistry.CityOccupied.selector);
            vm.prank(OUTSIDER);
            registry.buyCity(id);
            vm.expectRevert(CityRegistry.MaximumLevel.selector);
            registry.levelUpCost(id);
            vm.expectRevert(CityRegistry.MaximumLevel.selector);
            vm.prank(_buyer(id));
            registry.levelUp(id);
        }

        uint256[256] memory previous;
        for (uint256 id; id < CITY_COUNT; ++id) {
            previous[id] = registry.claimableRewards(id);
        }
        uint256 poolBefore = registry.rewardsPool();
        registry.fundRewards(1);
        assertEq(registry.rewardsPool(), poolBefore + 1, "sub-tax-unit funding remains accounted for");
        for (uint256 id; id < CITY_COUNT; ++id) {
            assertLe(registry.claimableRewards(id) - previous[id], 1);
        }

        // 25,600,000 gross wei contributes 25,088,000 reward wei, exactly 98,000 per city.
        for (uint256 id; id < CITY_COUNT; ++id) {
            previous[id] = registry.claimableRewards(id);
        }
        registry.fundRewards(MAX_WEIGHT * 250);
        for (uint256 id; id < CITY_COUNT; ++id) {
            assertEq(registry.claimableRewards(id) - previous[id], 98_000);
            previous[id] = registry.claimableRewards(id);
        }

        uint256 remaining = token.balanceOf(address(this));
        poolBefore = registry.rewardsPool();
        registry.fundRewards(remaining);
        uint256 distributed = registry.rewardsPool() - poolBefore;
        for (uint256 id; id < CITY_COUNT; ++id) {
            assertApproxEqAbs(registry.claimableRewards(id) - previous[id], distributed / CITY_COUNT, 1);
        }
        uint256 pool = registry.rewardsPool();
        uint256 resources = registry.resourcePot();
        for (uint256 id; id < CITY_COUNT; ++id) {
            uint256 quote = registry.claimableRewards(id);
            uint256 tax = quote * 400 / 10_000;
            uint256 resourceShare = tax * 30 / 100;
            uint256 rewardsShare = tax - resourceShare - 2 * (tax / 10);
            address owner = _buyer(id);
            uint256 beforeBalance = token.balanceOf(owner);
            vm.prank(owner);
            assertEq(registry.claimRewards(id), quote, "claim still returns gross accrued rewards");
            assertEq(token.balanceOf(owner) - beforeBalance, quote - tax, "wallet receives net rewards");
            pool = pool - quote + rewardsShare;
            resources += resourceShare;
            assertEq(registry.rewardsPool(), pool);
            assertEq(registry.resourcePot(), resources);
        }
        assertGt(registry.claimableRewards(255), 0, "each claim earns a share of its own tax");
        _assertCustody();
        assertEq(token.balanceOf(address(this)), 0);
    }

    /// @dev Grants to a level-20 city are accepted and keep their backing in custody: nothing
    /// can consume them and nothing refunds them, exactly as the README documents.
    function testGrantsToMaximumLevelCityStayBackedButUnusable() public {
        _buy(ALICE, 0);
        registry.fundResources(300_000 ether);
        vm.prank(OPERATOR);
        executor.grantResources(address(registry), 0, RESOURCES_TO_MAX);
        for (uint256 i; i < 19; ++i) {
            vm.prank(ALICE);
            registry.levelUp(0);
        }
        (, uint256 level, uint256 resources,,) = registry.cities(0);
        assertEq(level, 20);
        assertEq(resources, 0);
        assertEq(registry.allocatedResourceBacking(), 0);
        _buy(_buyer(1), 1);
        _buy(_buyer(2), 2);
        uint256 supply = token.totalSupply();
        uint256 pot = registry.resourcePot();
        uint256 rewards = registry.claimableRewards(0);
        vm.startPrank(OPERATOR);
        executor.grantResources(address(registry), 0, 1);
        executor.recordHeartbeat(address(registry), 0, 1, 1, 1, 2, 1);
        vm.stopPrank();
        (, level, resources,,) = registry.cities(0);
        assertEq(level, 20);
        assertEq(resources, 2);
        assertEq(registry.resourcePot(), pot - 4 ether);
        assertEq(registry.allocatedResourceBacking(), 4 ether);
        _assertCustody();
        assertEq(token.totalSupply(), supply, "unusable grants burn nothing");
        vm.expectRevert(CityRegistry.MaximumLevel.selector);
        vm.prank(ALICE);
        registry.levelUp(0);
        assertEq(registry.claimableRewards(0), rewards, "grants themselves are not rewards");
        assertEq(registry.lastHeartbeatCityIds(0), 0);
        assertEq(registry.lastHeartbeatAmounts(0), 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzCoordinatesRoundTripAndWalkTheGrid(uint8 rawId) public view {
        uint256 id = rawId;
        (uint256 x, uint256 y) = registry.coordinates(id);
        assertLt(x, 16);
        assertLt(y, 16);
        assertEq(y * 16 + x, id, "coordinates invert the id");
        if (id == 255) return;
        (uint256 nextX, uint256 nextY) = registry.coordinates(id + 1);
        assertEq(nextX, (x + 1) % 16, "the next id moves one column right, wrapping");
        assertEq(nextY, x == 15 ? y + 1 : y, "a wrap moves one row down");
    }

    /// @dev Once all levels match, each new funding adds an equal share, regardless of
    /// unequal historic rewards accrued while building the cities. Claims return gross amounts.
    function testFuzzEqualLevelsShareEquallyAtEveryLevel(uint256 amountSeed, uint8 levelSeed) public {
        uint256 level = bound(levelSeed, 1, 20);
        uint256 amount = bound(amountSeed, 1, 100_000_000 ether);
        uint256[3] memory ids = [uint256(0), 17, 255];
        uint256 resourcesEach = _resourcesToLevel(level);
        registry.fundResources(3 * resourcesEach * 1 ether * 1000 / 972 + 1);
        for (uint256 j; j < 3; ++j) {
            _buy(_buyer(ids[j]), ids[j]);
            if (resourcesEach != 0) {
                vm.prank(OPERATOR);
                executor.grantResources(address(registry), ids[j], resourcesEach);
            }
            for (uint256 n = 1; n < level; ++n) {
                vm.prank(_buyer(ids[j]));
                registry.levelUp(ids[j]);
            }
        }
        assertEq(registry.totalWeight(), 3 * level * level);
        assertEq(registry.allocatedResourceBacking(), 0);
        uint256[3] memory beforeQuotes;
        for (uint256 j; j < 3; ++j) {
            beforeQuotes[j] = registry.claimableRewards(ids[j]);
        }
        uint256 poolBefore = registry.rewardsPool();
        registry.fundRewards(amount);
        uint256 rewardIncrease = registry.rewardsPool() - poolBefore;
        for (uint256 j; j < 3; ++j) {
            assertApproxEqAbs(
                registry.claimableRewards(ids[j]) - beforeQuotes[j],
                rewardIncrease / 3,
                1,
                "equal levels receive equal shares of each new reward"
            );
        }
        for (uint256 j; j < 3; ++j) {
            uint256 quote = registry.claimableRewards(ids[j]);
            if (quote == 0) continue;
            address buyer = _buyer(ids[j]);
            uint256 balanceBefore = token.balanceOf(buyer);
            vm.prank(buyer);
            assertEq(registry.claimRewards(ids[j]), quote);
            assertEq(token.balanceOf(buyer) - balanceBefore, quote - quote * 400 / 10_000);
            _assertCustody();
        }
    }

    /// @dev Sending to yourself is not a way around the levy; the sender simply loses the fee.
    function testSelfTransferWithTaxStillPaysTheFullLevy() public {
        _buy(ALICE, 0);
        uint256 balance = token.balanceOf(ALICE);
        uint256 supply = token.totalSupply();
        uint256 rewards = registry.rewardsPool();
        uint256 resources = registry.resourcePot();
        uint256 treasury = token.balanceOf(OPERATOR);
        uint256 quote = registry.claimableRewards(0);
        vm.startPrank(ALICE);
        token.approve(address(registry), 250 ether);
        registry.transferWithTax(ALICE, 250 ether);
        vm.stopPrank();
        assertEq(token.allowance(ALICE, address(registry)), 0);
        assertEq(balance - token.balanceOf(ALICE), 10 ether, "net loss is exactly the fee");
        assertEq(registry.rewardsPool() - rewards, 5 ether);
        assertEq(registry.resourcePot() - resources, 3 ether);
        assertEq(supply - token.totalSupply(), 1 ether);
        assertEq(token.balanceOf(OPERATOR) - treasury, 1 ether);
        assertEq(registry.claimableRewards(0) - quote, 5 ether);
    }

    /// @dev The treasury as recipient receives the net amount plus its own share, nothing more.
    function testTreasuryRecipientReceivesNetPlusItsShare() public {
        uint256 treasury = token.balanceOf(OPERATOR);
        uint256 alice = token.balanceOf(ALICE);
        uint256 custody = token.balanceOf(address(registry));
        vm.prank(ALICE);
        registry.transferWithTax(OPERATOR, 250 ether);
        assertEq(token.balanceOf(OPERATOR) - treasury, 241 ether);
        assertEq(alice - token.balanceOf(ALICE), 250 ether);
        assertEq(token.balanceOf(address(registry)) - custody, 8 ether);
    }

    /// @dev Pause lives on the executor: one pause stops grants to every registry it serves,
    /// while purchases and claims on every registry stay live.
    function testPauseIsExecutorWideAcrossRegistries() public {
        CityRegistry second = new CityRegistry(address(token), address(executor));
        token.approve(address(second), type(uint256).max);
        vm.prank(ALICE);
        token.approve(address(second), type(uint256).max);
        _buy(ALICE, 0);
        _buyFrom(second, ALICE, 9);
        registry.fundResources(10 ether);
        second.fundResources(10 ether);

        vm.startPrank(OPERATOR);
        executor.pause();
        vm.expectRevert(GrantExecutor.GrantsPaused.selector);
        executor.grantResources(address(registry), 0, 1);
        vm.expectRevert(GrantExecutor.GrantsPaused.selector);
        executor.grantResources(address(second), 9, 1);
        vm.expectRevert(GrantExecutor.GrantsPaused.selector);
        executor.recordHeartbeat(address(second), 9, 1, 0, 1, 1, 1);
        vm.stopPrank();

        registry.fundRewards(2 ether);
        second.fundRewards(3 ether);
        _buy(_buyer(1), 1);
        _buyFrom(second, _buyer(1), 1);
        uint256 firstQuote = registry.claimableRewards(0);
        uint256 otherQuote = second.claimableRewards(9);
        vm.startPrank(ALICE);
        assertEq(registry.claimRewards(0), firstQuote);
        assertEq(second.claimRewards(9), otherQuote);
        vm.stopPrank();
        uint256 firstPot = registry.resourcePot();
        uint256 otherPot = second.resourcePot();

        vm.startPrank(OPERATOR);
        executor.unpause();
        executor.grantResources(address(registry), 0, 1);
        executor.grantResources(address(second), 9, 2);
        vm.stopPrank();
        (,, uint256 first,,) = registry.cities(0);
        (,, uint256 other,,) = second.cities(9);
        assertEq(first, 1);
        assertEq(other, 2);
        assertEq(registry.resourcePot(), firstPot - 1 ether);
        assertEq(second.resourcePot(), otherPot - 2 ether);
    }

    /// @dev A contract that is not a registry rejects the forwarded call; the executor keeps no
    /// state and the real registry is untouched.
    function testForwardingToANonRegistryContractRevertsWithoutSideEffects() public {
        _buy(ALICE, 0);
        registry.fundResources(10 ether);
        uint256 pot = registry.resourcePot();
        vm.startPrank(OPERATOR);
        vm.expectRevert();
        executor.grantResources(address(token), 0, 1);
        vm.expectRevert();
        executor.recordHeartbeat(address(executor), 0, 1, 1, 1, 2, 1);
        vm.stopPrank();
        assertFalse(executor.paused());
        assertEq(registry.resourcePot(), pot);
        assertEq(registry.allocatedResourceBacking(), 0);
        assertEq(registry.heartbeatCount(), 0);
        (,, uint256 resources,,) = registry.cities(0);
        assertEq(resources, 0);
    }

    function _fillGridToMaximumLevel() private returns (uint256 purchaseBurn, uint256 transferBurn) {
        uint256 funding = CITY_COUNT * RESOURCES_TO_MAX * 1 ether * 1000 / 972 + 1;
        registry.fundResources(funding);
        transferBurn = funding / 250;
        for (uint256 id; id < CITY_COUNT; ++id) {
            address buyer = _buyer(id);
            uint256 price = registry.cityPrice();
            purchaseBurn += price;
            uint256 gross = (price * 25 + 23) / 24;
            token.transfer(buyer, gross);
            transferBurn += gross / 250;
            vm.startPrank(buyer);
            token.approve(address(registry), price);
            registry.buyCity(id);
            vm.stopPrank();
            vm.prank(OPERATOR);
            executor.grantResources(address(registry), id, RESOURCES_TO_MAX);
            for (uint256 n = 1; n < 20; ++n) {
                vm.prank(buyer);
                registry.levelUp(id);
            }
            (address owner, uint256 level, uint256 resources,,) = registry.cities(id);
            assertEq(owner, buyer);
            assertEq(level, 20);
            assertEq(resources, 0);
            assertLe(token.balanceOf(buyer), 1, "purchase funding includes the transfer tax");
        }
    }

    function _assertCustody() private view {
        assertEq(
            token.balanceOf(address(registry)),
            registry.rewardsPool() + registry.resourcePot() + registry.allocatedResourceBacking()
        );
    }

    function _resourcesToLevel(uint256 level) private pure returns (uint256 total) {
        for (uint256 n = 2; n <= level; ++n) {
            total += 100 * n * n;
        }
    }

    function _buyer(uint256 id) private pure returns (address) {
        return address(uint160(0x600000 + id));
    }

    function _buy(address buyer, uint256 id) private {
        _buyFrom(registry, buyer, id);
    }

    function _buyFrom(CityRegistry target, address buyer, uint256 id) private {
        uint256 price = target.cityPrice();
        if (token.balanceOf(buyer) < price) token.transfer(buyer, (price * 25 + 23) / 24);
        vm.startPrank(buyer);
        token.approve(address(target), price);
        target.buyCity(id);
        vm.stopPrank();
    }
}
