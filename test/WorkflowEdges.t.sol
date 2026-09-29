// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {CityRegistry} from "src/CityRegistry.sol";
import {GrantExecutor} from "src/GrantExecutor.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// forge-config: default.fuzz.runs = 1000
contract WorkflowEdgesTest is Test {
    address private constant OPERATOR = 0x5b95A971B4583A5f011E9DA082acdD679b870D06;
    address private constant ALICE = address(0xA110);
    address private constant BOB = address(0xB0B0);
    address private constant CAROL = address(0xCA401);
    LaunchToken private token;
    GrantExecutor private executor;
    CityRegistry private registry;

    function setUp() public {
        token = new LaunchToken();
        executor = new GrantExecutor(OPERATOR);
        registry = new CityRegistry(address(token), address(executor));
        token.setCityRegistry(address(registry));
        token.approve(address(registry), type(uint256).max);
        deal(address(token), ALICE, 1_000_000 ether);
        deal(address(token), BOB, 1_000_000 ether);
        deal(address(token), CAROL, 1_000_000 ether);
    }

    function testFuzzStalePurchaseQuoteRevertsWithoutChangingRewardsOrOwnership(uint8 plot) public {
        uint256 quoted = registry.cityPrice();
        vm.prank(ALICE);
        token.approve(address(registry), quoted);
        _buy(registry, BOB, (uint256(plot) + 1) % 256);
        registry.fundRewards(17 ether);
        uint256 newPrice = registry.cityPrice();
        uint256 balanceBefore = token.balanceOf(ALICE);
        uint256 supplyBefore = token.totalSupply();
        uint256 indexBefore = registry.accRewardPerWeight();
        assertGt(newPrice, quoted);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(registry), quoted, newPrice
            )
        );
        vm.prank(ALICE);
        registry.buyCity(plot);

        assertEq(registry.cityOf(ALICE), 0);
        (address owner, uint256 level, uint256 resources,,) = registry.cities(plot);
        assertEq(owner, address(0));
        assertEq(level, 0);
        assertEq(resources, 0);
        assertEq(registry.soldPlots(), 1);
        assertEq(registry.totalWeight(), 1);
        assertEq(registry.accRewardPerWeight(), indexBefore);
        assertEq(token.balanceOf(ALICE), balanceBefore);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(token.allowance(ALICE, address(registry)), quoted);
        assertEq(registry.claimableRewards((uint256(plot) + 1) % 256), 1666e16);

        _buy(registry, ALICE, plot);
        assertEq(registry.soldPlots(), 2);
        assertEq(registry.claimableRewards(plot), 0, "retry cannot capture old rewards");
        assertEq(token.balanceOf(ALICE), balanceBefore - newPrice);
    }

    function testFuzzHeartbeatOverdrawRollsBackAnEarlierValidHeartbeat(
        uint256 firstSeed,
        uint256 secondSeed,
        uint256 thirdSeed,
        bool failSecond
    ) public {
        _buyThree(registry);
        uint256 a = bound(firstSeed, 1, 100_000);
        uint256 b = bound(secondSeed, 1, 100_000);
        uint256 c = bound(thirdSeed, 1, 100_000);
        // The pot can cover earlier grants, but misses the failing one by ONE resource wei.
        uint256 remaining = (failSecond ? a + b : a + b + c) * 1 ether - 1;
        _fundResourcesExact(6 ether + remaining);
        vm.warp(100);
        vm.prank(OPERATOR);
        executor.recordHeartbeat(address(registry), 0, 1, 127, 2, 255, 3);
        bytes32 beforeState = _heartbeatState();
        vm.warp(200);
        vm.expectRevert(CityRegistry.InsufficientResourcePot.selector);
        vm.prank(OPERATOR);
        executor.recordHeartbeat(address(registry), 255, a, 127, b, 0, c);
        assertEq(_heartbeatState(), beforeState, "no partial grants or overwritten history");
        assertEq(registry.resourcePot(), remaining);
    }

    function testMaximumGrantAmountRevertsBeforeMultiplicationAndPreservesPot() public {
        _buy(registry, ALICE, 0);
        _fundResourcesExact(1 ether);
        vm.expectRevert(CityRegistry.InsufficientResourcePot.selector);
        vm.prank(OPERATOR);
        executor.grantResources(address(registry), 0, type(uint256).max);
        assertEq(registry.resourcePot(), 1 ether);
        assertEq(registry.allocatedResourceBacking(), 0);
        (,, uint256 resources,,) = registry.cities(0);
        assertEq(resources, 0);
    }

    function testFuzzOutOfRangeCityFailsEveryValidatedEntry(uint256 rawId) public {
        uint256 id = bound(rawId, 256, type(uint256).max);
        vm.expectRevert(CityRegistry.InvalidCityId.selector);
        registry.coordinates(id);
        vm.expectRevert(CityRegistry.InvalidCityId.selector);
        registry.levelUpCost(id);
        vm.expectRevert(CityRegistry.InvalidCityId.selector);
        registry.claimableRewards(id);
        vm.expectRevert(CityRegistry.InvalidCityId.selector);
        registry.buyCity(id);
        vm.expectRevert(CityRegistry.InvalidCityId.selector);
        registry.levelUp(id);
        vm.expectRevert(CityRegistry.InvalidCityId.selector);
        registry.claimRewards(id);
        vm.startPrank(OPERATOR);
        vm.expectRevert(CityRegistry.InvalidCityId.selector);
        executor.grantResources(address(registry), id, 1);
        vm.expectRevert(CityRegistry.InvalidCityId.selector);
        executor.recordHeartbeat(address(registry), id, 1, 0, 1, 1, 1);
        vm.stopPrank();
        assertEq(registry.soldPlots(), 0);
        assertEq(registry.totalWeight(), 0);
        assertEq(registry.heartbeatCount(), 0);
    }

    function testFullRemainingSupplyCanBeFundedClaimedAndRecycled() public {
        _buy(registry, ALICE, 0);
        uint256 remaining = token.balanceOf(address(this));
        uint256 beforeBalance = token.balanceOf(ALICE);
        registry.fundRewards(remaining);
        uint256 grossClaim = remaining - remaining / 25 + _taxRewards(remaining);
        assertEq(registry.claimableRewards(0), grossClaim);
        vm.prank(OPERATOR);
        executor.pause();
        vm.prank(ALICE);
        assertEq(registry.claimRewards(0), grossClaim);
        uint256 net = grossClaim - grossClaim / 25;
        assertEq(token.balanceOf(ALICE), beforeBalance + net);
        assertEq(registry.rewardsPool(), _taxRewards(grossClaim));
        assertEq(token.balanceOf(address(registry)), registry.rewardsPool() + registry.resourcePot());

        vm.startPrank(ALICE);
        token.approve(address(registry), net);
        registry.fundRewards(net);
        uint256 secondGross = _taxRewards(grossClaim) + net - net / 25 + _taxRewards(net);
        assertEq(registry.claimRewards(0), secondGross);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), beforeBalance + secondGross - secondGross / 25);
        assertEq(registry.rewardsPool(), _taxRewards(secondGross));
        assertEq(token.balanceOf(address(registry)), registry.rewardsPool() + registry.resourcePot());
    }

    /// @dev Payouts themselves generate rewards. Track the independently calculated history
    /// of deposits and payout taxes through repeated claims, joining cities and weight changes.
    /// forge-config: default.fuzz.runs = 256
    function testFuzzRepeatedClaimsAndWeightChangesPreserveBacking(
        uint256 firstSeed,
        uint256 stepSeed,
        uint8 countSeed
    ) public {
        _buy(registry, ALICE, 0);
        _buy(registry, BOB, 127);
        _fundResourcesExact(400 ether);
        vm.prank(OPERATOR);
        executor.grantResources(address(registry), 0, 400);
        uint256 first = bound(firstSeed, 1, 100 ether);
        uint256 step = bound(stepSeed, 0, 100);
        uint256 count = bound(countSeed, 2, 25);
        uint256 expectedRewards = registry.rewardsPool();
        uint256 expectedResources = registry.resourcePot();
        address[3] memory owners = [ALICE, BOB, CAROL];
        uint256[3] memory ids = [uint256(0), 127, 255];
        for (uint256 i; i < count; ++i) {
            uint256 amount = first + step * i;
            registry.fundRewards(amount);
            expectedRewards += amount - amount / 25 + _taxRewards(amount);
            expectedResources += (amount / 25) * 3 / 10;
            for (uint256 j; j < 3; ++j) {
                uint256 index = (i + j) % 3;
                uint256 quote = registry.claimableRewards(ids[index]);
                if (quote == 0) continue;
                uint256 beforeBalance = token.balanceOf(owners[index]);
                vm.prank(owners[index]);
                assertEq(registry.claimRewards(ids[index]), quote);
                assertEq(token.balanceOf(owners[index]) - beforeBalance, quote - quote / 25);
                expectedRewards = expectedRewards - quote + _taxRewards(quote);
                expectedResources += (quote / 25) * 3 / 10;
            }
            if (i == count / 2) {
                vm.prank(ALICE);
                registry.levelUp(0);
                _buy(registry, CAROL, 255);
            }
            assertEq(registry.rewardsPool(), expectedRewards);
            assertEq(registry.resourcePot(), expectedResources);
            assertEq(
                token.balanceOf(address(registry)),
                expectedRewards + expectedResources + registry.allocatedResourceBacking()
            );
            uint256 claims = registry.claimableRewards(0) + registry.claimableRewards(127)
                + registry.claimableRewards(255);
            assertLe(claims, expectedRewards);
            assertLe(expectedRewards - claims, 3, "only fractional city credits remain unclaimable");
        }
    }

    function _taxRewards(uint256 amount) private pure returns (uint256) {
        uint256 tax = amount / 25;
        return tax - tax * 3 / 10 - 2 * (tax / 10);
    }

    function _fundResourcesExact(uint256 amount) private {
        uint256 gross = amount * 1000 / 972;
        gross = gross > 16 ? gross - 16 : 1;
        while (gross - gross / 25 + (gross / 25) * 3 / 10 != amount) ++gross;
        uint256 beforePot = registry.resourcePot();
        registry.fundResources(gross);
        assertEq(registry.resourcePot() - beforePot, amount);
    }

    function _buy(CityRegistry target, address buyer, uint256 id) private {
        uint256 price = target.cityPrice();
        vm.startPrank(buyer);
        token.approve(address(target), price);
        target.buyCity(id);
        vm.stopPrank();
    }

    function _pendingScaled(CityRegistry target, uint256 id) private view returns (uint256) {
        (, uint256 level,, uint256 index, uint256 accrued) = target.cities(id);
        return accrued + level * level * (target.accRewardPerWeight() - index);
    }

    function _buyThree(CityRegistry target) private {
        _buy(target, ALICE, 0);
        _buy(target, BOB, 127);
        _buy(target, CAROL, 255);
    }

    function _heartbeatState() private view returns (bytes32 state) {
        state = keccak256(
            abi.encode(
                registry.resourcePot(),
                registry.allocatedResourceBacking(),
                registry.heartbeatCount(),
                registry.lastHeartbeatTimestamp(),
                token.balanceOf(address(registry)),
                token.totalSupply()
            )
        );
        uint256[3] memory ids = [uint256(0), 127, 255];
        for (uint256 i; i < 3; ++i) {
            (address owner, uint256 level, uint256 resources, uint256 index, uint256 accrued) =
                registry.cities(ids[i]);
            state = keccak256(
                abi.encode(
                    state,
                    owner,
                    level,
                    resources,
                    index,
                    accrued,
                    registry.lastHeartbeatCityIds(i),
                    registry.lastHeartbeatAmounts(i)
                )
            );
        }
    }
}
