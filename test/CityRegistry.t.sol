// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {CityRegistry} from "../src/CityRegistry.sol";
import {GrantExecutor} from "../src/GrantExecutor.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract CityRegistryTest is Test {
    LaunchToken private token;
    CityRegistry private registry;
    GrantExecutor private executor;

    address private constant OPERATOR = 0x5b95A971B4583A5f011E9DA082acdD679b870D06;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant CAROL = address(0xCA401);

    event CityBought(uint256 indexed cityId, address indexed owner, uint256 price);
    event ResourcesGranted(uint256 indexed cityId, uint256 amount);
    event CityLeveled(uint256 indexed cityId, uint256 level, uint256 resourcesConsumed);
    event RewardsClaimed(uint256 indexed cityId, address indexed owner, uint256 amount);
    event HeartbeatRecorded(uint256 indexed sequence, uint256[3] cityIds, uint256[3] amounts);
    event TaxTaken(
        address indexed from,
        address indexed to,
        uint256 grossAmount,
        uint256 fee,
        uint256 rewards,
        uint256 resources,
        uint256 burned,
        uint256 treasuryAmount
    );

    function setUp() public {
        token = new LaunchToken();
        executor = new GrantExecutor(OPERATOR);
        registry = new CityRegistry(address(token), address(executor));
        token.setCityRegistry(address(registry));
    }

    function testInitialConfiguration() public view {
        assertEq(address(registry.token()), address(token));
        assertEq(address(registry.grantExecutor()), address(executor));
        assertEq(registry.treasury(), OPERATOR);
        assertEq(executor.operator(), OPERATOR);
        assertFalse(executor.paused());
        assertEq(registry.cityPrice(), 10_000e18);
        assertEq(registry.soldPlots(), 0);
        assertEq(registry.totalWeight(), 0);
        assertEq(registry.claimableRewards(0), 0);
        _assertBacking();
    }

    function testCoordinatesCoverGridIncludingEndpoints() public view {
        for (uint256 id; id < 256; ++id) {
            (uint256 x, uint256 y) = registry.coordinates(id);
            assertEq(x, id % 16);
            assertEq(y, id / 16);
            assertLt(x, 16);
            assertLt(y, 16);
        }
    }

    function testBuyZeroAnd255BurnsExactPriceAndConsumesAllowance() public {
        uint256 supplyBefore = token.totalSupply();
        uint256 firstPrice = registry.cityPrice();
        deal(address(token), ALICE, firstPrice);
        vm.startPrank(ALICE);
        token.approve(address(registry), firstPrice);
        vm.expectEmit(true, true, false, true, address(registry));
        emit CityBought(0, ALICE, firstPrice);
        registry.buyCity(0);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.allowance(ALICE, address(registry)), 0);
        assertEq(token.totalSupply(), supplyBefore - firstPrice);
        assertEq(token.balanceOf(address(registry)), 0);
        assertEq(registry.cityOf(ALICE), 1);
        assertEq(registry.cityPrice(), 10_000e18 * 257 * 257 / 65_536);
        _assertCity(0, ALICE, 1, 0);

        uint256 secondPrice = registry.cityPrice();
        _buy(BOB, 255);
        assertEq(token.totalSupply(), supplyBefore - firstPrice - secondPrice);
        assertEq(registry.cityOf(BOB), 256);
        assertEq(registry.soldPlots(), 2);
        assertEq(registry.totalWeight(), 2);
        _assertCity(255, BOB, 1, 0);
    }

    function testCannotBuyOccupiedPlotOrSecondCity() public {
        _buy(ALICE, 0);
        vm.prank(BOB);
        vm.expectRevert(CityRegistry.CityOccupied.selector);
        registry.buyCity(0);
        vm.prank(ALICE);
        vm.expectRevert(CityRegistry.AlreadyOwnsCity.selector);
        registry.buyCity(1);
        assertEq(registry.soldPlots(), 1);
        assertEq(registry.cityOf(BOB), 0);
    }

    function testHoldingGateAndInsufficientPaymentRevertAtomically() public {
        deal(address(token), ALICE, 1000e18 - 1);
        vm.startPrank(ALICE);
        token.approve(address(registry), 10_000e18);
        vm.expectRevert(CityRegistry.InsufficientHolding.selector);
        registry.buyCity(0);
        vm.stopPrank();
        token.transfer(ALICE, 1);
        uint256 supplyBefore = token.totalSupply();
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 1000e18, 10_000e18)
        );
        registry.buyCity(0);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(token.allowance(ALICE, address(registry)), 10_000e18);
        assertEq(registry.cityOf(ALICE), 0);
        assertEq(registry.soldPlots(), 0);
        assertEq(registry.totalWeight(), 0);
        _assertCity(0, address(0), 0, 0);
    }

    function testRevertedPurchasePreservesQueuedRewards() public {
        _fundRewards(17e18);
        deal(address(token), ALICE, 10_000e18);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(registry), 0, 10_000e18
            )
        );
        registry.buyCity(0);
        assertEq(registry.queuedRewards(), 17e18);
        assertEq(registry.accRewardPerWeight(), 0);
        assertEq(registry.cityOf(ALICE), 0);
        assertEq(registry.totalWeight(), 0);
        _assertBacking();
    }

    function testCityOwnershipCannotBeTransferred() public {
        _buy(ALICE, 0);
        vm.startPrank(ALICE);
        (bool cityTransfer,) =
            address(registry).call(abi.encodeWithSignature("transferCity(uint256,address)", 0, BOB));
        (bool nftTransfer,) = address(registry)
            .call(abi.encodeWithSignature("transferFrom(address,address,uint256)", ALICE, BOB, 0));
        (bool nftApproval,) =
            address(registry).call(abi.encodeWithSignature("approve(address,uint256)", BOB, 0));
        vm.stopPrank();
        assertFalse(cityTransfer);
        assertFalse(nftTransfer);
        assertFalse(nftApproval);
        assertEq(registry.cityOf(ALICE), 1);
        assertEq(registry.cityOf(BOB), 0);
        _assertCity(0, ALICE, 1, 0);
    }

    function testAllPlotsSellWithExactIncreasingPrices() public {
        uint256 initialSupply = token.totalSupply();
        uint256 burned;
        for (uint256 id; id < 256; ++id) {
            uint256 price = 10_000e18 * (256 + id) * (256 + id) / 65_536;
            assertEq(registry.cityPrice(), price);
            address buyer = address(uint160(0x10000 + id));
            _buy(buyer, id);
            burned += price;
            assertEq(registry.cityOf(buyer), id + 1);
            _assertCity(id, buyer, 1, 0);
        }
        assertEq(registry.soldPlots(), 256);
        assertEq(registry.totalWeight(), 256);
        assertEq(token.totalSupply(), initialSupply - burned);
        vm.expectRevert(CityRegistry.SoldOut.selector);
        registry.cityPrice();
        vm.expectRevert(CityRegistry.CityOccupied.selector);
        registry.buyCity(255);
        vm.expectRevert(CityRegistry.InvalidCityId.selector);
        registry.buyCity(256);
    }

    function testInvalidCityIdsRejectedAcrossPublicEntryPoints() public {
        vm.expectRevert(CityRegistry.InvalidCityId.selector);
        registry.coordinates(256);
        vm.expectRevert(CityRegistry.InvalidCityId.selector);
        registry.buyCity(type(uint256).max);
        vm.expectRevert(CityRegistry.InvalidCityId.selector);
        registry.levelUpCost(256);
        vm.expectRevert(CityRegistry.InvalidCityId.selector);
        registry.levelUp(256);
        vm.expectRevert(CityRegistry.InvalidCityId.selector);
        registry.claimRewards(256);
        vm.expectRevert(CityRegistry.InvalidCityId.selector);
        registry.claimableRewards(256);
        vm.prank(OPERATOR);
        vm.expectRevert(CityRegistry.InvalidCityId.selector);
        executor.grantResources(address(registry), 256, 1);
    }

    function testRewardsBeforeFirstCityAreQueuedForFirstBuyer() public {
        _fundRewards(11e18);
        _fundRewards(7e18);
        assertEq(registry.queuedRewards(), 18e18);
        assertEq(registry.rewardsPool(), 18e18);
        assertEq(registry.claimableRewards(0), 0);
        _buy(ALICE, 0);
        assertEq(registry.queuedRewards(), 0);
        assertEq(registry.claimableRewards(0), 18e18);
        _buy(BOB, 255);
        assertEq(registry.claimableRewards(255), 0);
        _claim(ALICE, 0, 18e18);
        _assertBacking();
    }

    function testNewCityDoesNotReceivePastRewards() public {
        _buy(ALICE, 0);
        _fundRewards(100e18);
        _buy(BOB, 1);
        assertEq(registry.claimableRewards(0), 100e18);
        assertEq(registry.claimableRewards(1), 0);
        _fundRewards(40e18);
        _claim(BOB, 1, 20e18);
        // Alice also receives half the tax rewards generated by Bob's payout.
        uint256 aliceGross = 120e18 + _taxRewards(20e18) / 2;
        _claim(ALICE, 0, aliceGross);
        assertEq(
            registry.rewardsPool(), 140e18 + _taxRewards(20e18) + _taxRewards(aliceGross) - 20e18 - aliceGross
        );
        _assertBacking();
    }

    function testLevelChangePreservesPastRewardsAndChangesOnlyFutureWeight() public {
        _buy(ALICE, 0);
        _buy(BOB, 1);
        _fundRewards(100e18);
        _fundResources(400e18);
        uint256 past = registry.claimableRewards(0);
        assertEq(registry.claimableRewards(1), past);
        _grant(0, 400);
        vm.prank(ALICE);
        registry.levelUp(0);
        assertEq(registry.totalWeight(), 5);
        assertEq(registry.claimableRewards(0), past);
        assertEq(registry.claimableRewards(1), past);
        _fundRewards(100e18);
        assertEq(registry.claimableRewards(0), past + 80e18);
        assertEq(registry.claimableRewards(1), past + 20e18);
        _claim(ALICE, 0, past + 80e18);
        uint256 bobGross = registry.claimableRewards(1);
        assertApproxEqAbs(bobGross, past + 20e18 + _taxRewards(past + 80e18) / 5, 1);
        _claim(BOB, 1, bobGross);
        assertEq(registry.allocatedResourceBacking(), 0);
        _assertBacking();
    }

    function testFractionalRewardCreditsSurviveRepeatedClaims() public {
        _buyThree();
        _fundRewards(4);
        _claim(ALICE, 0, 1);
        _claim(BOB, 1, 1);
        _claim(CAROL, 2, 1);
        (,,,, uint256 fractional) = registry.cities(0);
        assertGt(fractional, 0);
        assertLt(fractional, registry.REWARD_SCALE());
        assertEq(registry.rewardsPool(), 1);
        _fundRewards(2);
        _claim(CAROL, 2, 1);
        _claim(ALICE, 0, 1);
        _claim(BOB, 1, 1);
        assertEq(registry.rewardsPool(), 0);
        assertEq(registry.rewardRemainder(), 0);
        _assertBacking();
    }

    function testFractionalCreditsSurviveLevelChange() public {
        _buyThree();
        _fundResources(400e18);
        _fundRewards(2);
        _grant(0, 400);
        (,,, uint256 oldIndex, uint256 oldAccrued) = registry.cities(0);
        uint256 beforeScaled = oldAccrued + registry.accRewardPerWeight() - oldIndex;
        assertGt(beforeScaled % registry.REWARD_SCALE(), 0);
        vm.prank(ALICE);
        registry.levelUp(0);
        (,,, uint256 settledIndex, uint256 settledAccrued) = registry.cities(0);
        assertEq(settledAccrued, beforeScaled, "level change retains all old fractional credit");
        assertEq(settledIndex, registry.accRewardPerWeight());
        _fundRewards(5);
        uint256 expectedScaled = beforeScaled + 4 * (registry.accRewardPerWeight() - settledIndex);
        _claim(ALICE, 0, expectedScaled / registry.REWARD_SCALE());
        (,,,, uint256 retainedFraction) = registry.cities(0);
        assertEq(retainedFraction, expectedScaled % registry.REWARD_SCALE());
        _assertBacking();
    }

    function testRepeatedClaimPaysOnlyNewPayoutTaxRewards() public {
        _buy(ALICE, 0);
        vm.prank(ALICE);
        vm.expectRevert(CityRegistry.NoRewards.selector);
        registry.claimRewards(0);
        _fundRewards(5e18);
        _claim(ALICE, 0, 5e18);
        // The payout generates a new reward share; only that new share can be claimed again.
        uint256 second = _taxRewards(5e18);
        assertEq(registry.claimableRewards(0), second);
        _claim(ALICE, 0, second);
        assertEq(registry.claimableRewards(0), _taxRewards(second));
    }

    function testNonOwnerCannotClaimOrLevelCity() public {
        _buy(ALICE, 0);
        _fundRewards(5e18);
        vm.startPrank(BOB);
        vm.expectRevert(CityRegistry.NotCityOwner.selector);
        registry.claimRewards(0);
        vm.expectRevert(CityRegistry.NotCityOwner.selector);
        registry.levelUp(0);
        vm.expectRevert(CityRegistry.NotCityOwner.selector);
        registry.claimRewards(1);
        vm.stopPrank();
        assertEq(registry.claimableRewards(0), 5e18);
    }

    function testResourcesAllocateWholeGridBackingAndBurnItOnLeveling() public {
        _buy(ALICE, 0);
        _fundResources(500e18 + 7);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ResourcesGranted(0, 400);
        _grant(0, 400);
        assertEq(registry.resourcePot(), 100e18 + 7);
        assertEq(registry.allocatedResourceBacking(), 400e18);
        assertEq(token.balanceOf(address(registry)), 500e18 + 7 + registry.rewardsPool());
        assertEq(registry.levelUpCost(0), 400);
        uint256 supplyBefore = token.totalSupply();
        vm.prank(ALICE);
        vm.expectEmit(true, false, false, true, address(registry));
        emit CityLeveled(0, 2, 400);
        registry.levelUp(0);
        _assertCity(0, ALICE, 2, 0);
        assertEq(registry.resourcePot(), 100e18 + 7);
        assertEq(registry.allocatedResourceBacking(), 0);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(address(registry)), 100e18 + 7 + registry.rewardsPool());
        assertEq(token.totalSupply(), supplyBefore - 400e18);
        _assertBacking();
    }

    function testResourcesCannotBeGrantedForEmptyCityZeroOrOverspent() public {
        _buy(ALICE, 0);
        _fundResources(2e18 - 1);
        vm.startPrank(OPERATOR);
        vm.expectRevert(CityRegistry.CityNotOwned.selector);
        executor.grantResources(address(registry), 1, 1);
        vm.expectRevert(CityRegistry.InvalidAmount.selector);
        executor.grantResources(address(registry), 0, 0);
        vm.expectRevert(CityRegistry.InsufficientResourcePot.selector);
        executor.grantResources(address(registry), 0, 2);
        executor.grantResources(address(registry), 0, 1);
        vm.expectRevert(CityRegistry.InsufficientResourcePot.selector);
        executor.grantResources(address(registry), 0, 1);
        vm.expectRevert(CityRegistry.InsufficientResourcePot.selector);
        executor.grantResources(address(registry), 0, type(uint256).max);
        vm.stopPrank();
        _assertCity(0, ALICE, 1, 1);
        assertEq(registry.resourcePot(), 1e18 - 1);
        assertEq(registry.allocatedResourceBacking(), 1e18);
        _assertBacking();
    }

    function testLevelUpNeedsResourcesAndStopsAtTwenty() public {
        _buy(ALICE, 0);
        vm.prank(ALICE);
        vm.expectRevert(CityRegistry.InsufficientResources.selector);
        registry.levelUp(0);
        vm.expectRevert(CityRegistry.CityNotOwned.selector);
        registry.levelUpCost(1);
        uint256 totalCost;
        for (uint256 next = 2; next <= 20; ++next) {
            totalCost += 100 * next * next;
        }
        _fundResources(totalCost * 1e18);
        _grant(0, totalCost);
        uint256 supplyBefore = token.totalSupply();
        for (uint256 next = 2; next <= 20; ++next) {
            assertEq(registry.levelUpCost(0), 100 * next * next);
            vm.prank(ALICE);
            registry.levelUp(0);
            assertEq(registry.totalWeight(), next * next);
        }
        _assertCity(0, ALICE, 20, 0);
        vm.prank(ALICE);
        vm.expectRevert(CityRegistry.MaximumLevel.selector);
        registry.levelUp(0);
        vm.expectRevert(CityRegistry.MaximumLevel.selector);
        registry.levelUpCost(0);
        assertEq(registry.allocatedResourceBacking(), 0);
        assertEq(token.totalSupply(), supplyBefore - totalCost * 1e18);
        assertEq(registry.resourcePot(), 0);
        _assertBacking();
    }

    function testHeartbeatStoresAwardsAndReplacesLatestWinners() public {
        _buyThree();
        _fundResources(30e18);
        vm.warp(1000);
        uint256[3] memory ids = [uint256(0), 1, 2];
        uint256[3] memory amounts = [uint256(1), 2, 3];
        vm.prank(OPERATOR);
        vm.expectEmit(true, false, false, true, address(registry));
        emit HeartbeatRecorded(1, ids, amounts);
        executor.recordHeartbeat(address(registry), 0, 1, 1, 2, 2, 3);
        assertEq(registry.heartbeatCount(), 1);
        assertEq(registry.lastHeartbeatTimestamp(), 1000);
        for (uint256 i; i < 3; ++i) {
            assertEq(registry.lastHeartbeatCityIds(i), ids[i]);
            assertEq(registry.lastHeartbeatAmounts(i), amounts[i]);
        }
        vm.warp(2000);
        vm.prank(OPERATOR);
        executor.recordHeartbeat(address(registry), 2, 4, 0, 5, 1, 6);
        assertEq(registry.heartbeatCount(), 2);
        assertEq(registry.lastHeartbeatTimestamp(), 2000);
        assertEq(registry.lastHeartbeatCityIds(0), 2);
        assertEq(registry.lastHeartbeatCityIds(1), 0);
        assertEq(registry.lastHeartbeatCityIds(2), 1);
        assertEq(registry.lastHeartbeatAmounts(0), 4);
        assertEq(registry.lastHeartbeatAmounts(1), 5);
        assertEq(registry.lastHeartbeatAmounts(2), 6);
        _assertCity(0, ALICE, 1, 6);
        _assertCity(1, BOB, 1, 8);
        _assertCity(2, CAROL, 1, 7);
        assertEq(registry.resourcePot(), 9e18);
        assertEq(registry.allocatedResourceBacking(), 21e18);
        _assertBacking();
    }

    function testHeartbeatRejectsAllDuplicatePairsAndInvalidWinners() public {
        _buyThree();
        _fundResources(30e18);
        vm.startPrank(OPERATOR);
        vm.expectRevert(CityRegistry.DuplicateWinners.selector);
        executor.recordHeartbeat(address(registry), 0, 1, 0, 1, 2, 1);
        vm.expectRevert(CityRegistry.DuplicateWinners.selector);
        executor.recordHeartbeat(address(registry), 0, 1, 1, 1, 0, 1);
        vm.expectRevert(CityRegistry.DuplicateWinners.selector);
        executor.recordHeartbeat(address(registry), 0, 1, 1, 1, 1, 1);
        vm.expectRevert(CityRegistry.CityNotOwned.selector);
        executor.recordHeartbeat(address(registry), 0, 1, 1, 1, 3, 1);
        vm.expectRevert(CityRegistry.InvalidCityId.selector);
        executor.recordHeartbeat(address(registry), 0, 1, 1, 1, 256, 1);
        vm.expectRevert(CityRegistry.InvalidAmount.selector);
        executor.recordHeartbeat(address(registry), 0, 1, 1, 1, 2, 0);
        vm.stopPrank();
        assertEq(registry.heartbeatCount(), 0);
        assertEq(registry.lastHeartbeatTimestamp(), 0);
        assertEq(registry.resourcePot(), 30e18);
        assertEq(registry.allocatedResourceBacking(), 0);
        _assertCity(0, ALICE, 1, 0);
        _assertCity(1, BOB, 1, 0);
        _assertCity(2, CAROL, 1, 0);
        _assertBacking();
    }

    function testHeartbeatInsufficientPotRollsBackEarlierAwardsAndPreviousRecord() public {
        _buyThree();
        _fundResources(10e18);
        vm.warp(1000);
        vm.prank(OPERATOR);
        executor.recordHeartbeat(address(registry), 0, 1, 1, 1, 2, 1);
        vm.warp(2000);
        vm.prank(OPERATOR);
        vm.expectRevert(CityRegistry.InsufficientResourcePot.selector);
        executor.recordHeartbeat(address(registry), 2, 3, 1, 3, 0, 3);
        assertEq(registry.heartbeatCount(), 1);
        assertEq(registry.lastHeartbeatTimestamp(), 1000);
        assertEq(registry.resourcePot(), 7e18);
        assertEq(registry.allocatedResourceBacking(), 3e18);
        for (uint256 id; id < 3; ++id) {
            assertEq(registry.lastHeartbeatCityIds(id), id);
            assertEq(registry.lastHeartbeatAmounts(id), 1);
        }
        _assertCity(0, ALICE, 1, 1);
        _assertCity(1, BOB, 1, 1);
        _assertCity(2, CAROL, 1, 1);
        _assertBacking();
    }

    function testOnlyExecutorCanGrantEvenOperatorCannotCallRegistryDirectly() public {
        _buyThree();
        _fundResources(10e18);
        vm.startPrank(OPERATOR);
        vm.expectRevert(CityRegistry.UnauthorizedExecutor.selector);
        registry.grantResources(0, 1);
        vm.expectRevert(CityRegistry.UnauthorizedExecutor.selector);
        registry.recordHeartbeat(0, 1, 1, 1, 2, 1);
        vm.stopPrank();
        vm.startPrank(ALICE);
        vm.expectRevert(GrantExecutor.Unauthorized.selector);
        executor.grantResources(address(registry), 0, 1);
        vm.expectRevert(GrantExecutor.Unauthorized.selector);
        executor.recordHeartbeat(address(registry), 0, 1, 1, 1, 2, 1);
        vm.expectRevert(GrantExecutor.Unauthorized.selector);
        executor.pause();
        vm.expectRevert(GrantExecutor.Unauthorized.selector);
        executor.unpause();
        vm.stopPrank();
        assertEq(registry.resourcePot(), 10e18);
    }

    function testPauseStopsOnlyGrantsWhileBuyClaimAndLevelRemainLive() public {
        _buy(ALICE, 0);
        _fundResources(403e18);
        _grant(0, 400);
        _fundRewards(10e18);
        vm.prank(OPERATOR);
        executor.pause();
        assertTrue(executor.paused());
        vm.startPrank(OPERATOR);
        vm.expectRevert(GrantExecutor.GrantsPaused.selector);
        executor.grantResources(address(registry), 0, 1);
        vm.expectRevert(GrantExecutor.GrantsPaused.selector);
        executor.recordHeartbeat(address(registry), 0, 1, 1, 1, 2, 1);
        vm.expectRevert(GrantExecutor.AlreadyPaused.selector);
        executor.pause();
        vm.stopPrank();
        _buy(BOB, 1);
        _buy(CAROL, 2);
        _claim(ALICE, 0, registry.claimableRewards(0));
        vm.prank(ALICE);
        registry.levelUp(0);
        _assertCity(0, ALICE, 2, 0);
        _fundRewards(6e18);
        _claim(ALICE, 0, registry.claimableRewards(0));
        _claim(BOB, 1, registry.claimableRewards(1));
        _claim(CAROL, 2, registry.claimableRewards(2));
        vm.prank(OPERATOR);
        executor.unpause();
        assertFalse(executor.paused());
        vm.prank(OPERATOR);
        executor.recordHeartbeat(address(registry), 0, 1, 1, 1, 2, 1);
        assertEq(registry.heartbeatCount(), 1);
        vm.prank(OPERATOR);
        vm.expectRevert(GrantExecutor.NotPaused.selector);
        executor.unpause();
        _assertBacking();
    }

    function testExecutorRejectsNoCodeTargetsAndZeroOperator() public {
        vm.expectRevert(GrantExecutor.InvalidOperator.selector);
        new GrantExecutor(address(0));
        vm.startPrank(OPERATOR);
        vm.expectRevert(GrantExecutor.InvalidRegistry.selector);
        executor.grantResources(ALICE, 0, 1);
        vm.expectRevert(GrantExecutor.InvalidRegistry.selector);
        executor.recordHeartbeat(address(0), 0, 1, 1, 1, 2, 1);
        vm.stopPrank();
    }

    function testExplicitTaxRouteSplitsAndBurnsExactly() public {
        uint256 supplyBefore = token.totalSupply();
        token.approve(address(registry), 1000e18);
        vm.expectEmit(true, true, false, true, address(token));
        emit TaxTaken(address(this), BOB, 1000e18, 40e18, 20e18, 12e18, 4e18, 4e18);
        registry.transferWithTax(BOB, 1000e18);
        assertEq(token.balanceOf(BOB), 960e18);
        assertEq(token.balanceOf(OPERATOR), 4e18);
        assertEq(token.totalSupply(), supplyBefore - 4e18);
        assertEq(registry.rewardsPool(), 20e18);
        assertEq(registry.queuedRewards(), 20e18);
        assertEq(registry.resourcePot(), 12e18);
        assertEq(token.balanceOf(address(registry)), 32e18);
        _buy(ALICE, 0);
        _claim(ALICE, 0, 20e18);
        _grant(0, 12);
        _assertBacking();
    }

    function testOrdinaryTokenTransfersFundBothPoolsAndBurn() public {
        uint256 supplyBefore = token.totalSupply();
        uint256 balanceBefore = token.balanceOf(address(this));
        token.transfer(ALICE, 1000e18);
        assertEq(token.balanceOf(ALICE), 960e18);
        assertEq(token.balanceOf(address(this)), balanceBefore - 1000e18);
        assertEq(token.totalSupply(), supplyBefore - 4e18);
        assertEq(token.balanceOf(OPERATOR), 4e18);
        assertEq(registry.rewardsPool(), 20e18);
        assertEq(registry.resourcePot(), 12e18);
        assertEq(
            registry.rewardsPool() + registry.resourcePot() + token.balanceOf(OPERATOR) + supplyBefore
                - token.totalSupply(),
            40e18
        );
        _assertBacking();
    }

    function testGrossFundingCreditsNetReceiptAndTaxSharesExactlyOnce() public {
        uint256 supplyBefore = token.totalSupply();
        token.approve(address(registry), 2000e18);
        registry.fundRewards(1000e18);
        assertEq(registry.rewardsPool(), 980e18, "960 net funding plus 20 tax rewards");
        assertEq(registry.resourcePot(), 12e18);
        assertEq(token.balanceOf(address(registry)), 992e18);
        registry.fundResources(1000e18);
        assertEq(registry.rewardsPool(), 1000e18);
        assertEq(registry.resourcePot(), 984e18, "12 earlier tax plus 960 net funding plus 12 new tax");
        assertEq(registry.queuedRewards(), 1000e18);
        assertEq(token.allowance(address(this), address(registry)), 0);
        assertEq(token.balanceOf(OPERATOR), 8e18);
        assertEq(token.totalSupply(), supplyBefore - 8e18);
        _assertBacking();
    }

    function testFundingAndTaxRejectZeroAndInvalidRecipient() public {
        vm.expectRevert(CityRegistry.InvalidAmount.selector);
        registry.fundRewards(0);
        vm.expectRevert(CityRegistry.InvalidAmount.selector);
        registry.fundResources(0);
        vm.expectRevert(CityRegistry.InvalidAmount.selector);
        registry.transferWithTax(BOB, 0);
        vm.expectRevert(CityRegistry.InvalidRecipient.selector);
        registry.transferWithTax(address(0), 100);
        vm.expectRevert(CityRegistry.InvalidRecipient.selector);
        registry.transferWithTax(address(registry), 100);
        _assertBacking();
    }

    function testFundingRequiresAllowanceAndCannotConsumeResourceBackingForRewards() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(registry), 0, 1e18
            )
        );
        registry.fundRewards(1e18);
        _buy(ALICE, 0);
        _fundResources(10e18);
        _grant(0, 10);
        // Resource funding itself yields taxed rewards; claiming them cannot consume grant backing.
        uint256 quote = registry.claimableRewards(0);
        assertGt(quote, 0);
        _claim(ALICE, 0, quote);
        assertEq(registry.allocatedResourceBacking(), 10e18);
        assertGe(token.balanceOf(address(registry)), 10e18);
        _assertBacking();
    }

    function testFuzzTaxRoundingConservesGrossDebit(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 1, token.totalSupply());
        uint256 supplyBefore = token.totalSupply();
        uint256 senderBefore = token.balanceOf(address(this));
        token.approve(address(registry), amount);
        registry.transferWithTax(BOB, amount);
        uint256 fee = amount / 25;
        uint256 burned = fee / 10;
        uint256 recipient = token.balanceOf(BOB);
        uint256 treasuryAmount = token.balanceOf(OPERATOR);
        uint256 retained = token.balanceOf(address(registry));
        assertEq(senderBefore - token.balanceOf(address(this)), amount);
        assertEq(recipient, amount - fee);
        assertLe(fee, amount);
        assertLe(fee * 25, amount);
        assertLt(amount - fee * 25, 25);
        assertGe(registry.rewardsPool(), fee / 2);
        assertLe(registry.rewardsPool() - fee / 2, 3);
        assertEq(registry.resourcePot(), fee * 3 / 10);
        assertEq(token.totalSupply(), supplyBefore - burned);
        assertEq(recipient + treasuryAmount + retained + burned, amount);
        assertEq(treasuryAmount, fee / 10);
        assertEq(registry.rewardsPool() + registry.resourcePot() + burned + treasuryAmount, fee);
        assertEq(token.allowance(address(this), address(registry)), 0);
        _assertBacking();
    }

    function testFuzzWeightedRewardsNeverExceedFunding(uint256 rawFirst, uint256 rawSecond) public {
        uint256 first = bound(rawFirst, 1, 1_000_000e18);
        uint256 second = bound(rawSecond, 1, 1_000_000e18);
        _buy(ALICE, 0);
        _fundRewards(first);
        _buy(BOB, 1);
        _fundResources(400e18);
        uint256 resourceTaxRewards = registry.rewardsPool() - first;
        _grant(0, 400);
        vm.prank(ALICE);
        registry.levelUp(0);
        _fundRewards(second);
        uint256 aliceAmount = registry.claimableRewards(0);
        uint256 bobAmount = registry.claimableRewards(1);
        uint256 funded = first + resourceTaxRewards + second;
        assertApproxEqAbs(aliceAmount, first + resourceTaxRewards / 2 + 4 * second / 5, 1);
        assertApproxEqAbs(bobAmount, resourceTaxRewards / 2 + second / 5, 1);
        assertLe(aliceAmount + bobAmount, funded);
        assertLe(funded - aliceAmount - bobAmount, 1);
        _claim(ALICE, 0, aliceAmount);
        uint256 bobAfterPayoutTax = registry.claimableRewards(1);
        if (bobAfterPayoutTax != 0) _claim(BOB, 1, bobAfterPayoutTax);
        assertEq(
            registry.rewardsPool(),
            funded + _taxRewards(aliceAmount) + _taxRewards(bobAfterPayoutTax) - aliceAmount
                - bobAfterPayoutTax
        );
        assertEq(registry.allocatedResourceBacking(), 0);
        _assertBacking();
    }

    function _buy(address buyer, uint256 cityId) private {
        uint256 price = registry.cityPrice();
        deal(address(token), buyer, price);
        vm.startPrank(buyer);
        token.approve(address(registry), price);
        registry.buyCity(cityId);
        vm.stopPrank();
    }

    function _buyThree() private {
        _buy(ALICE, 0);
        _buy(BOB, 1);
        _buy(CAROL, 2);
    }

    function _fundRewards(uint256 amount) private {
        // Gross-up fixture funding to an exact reward-pool increase, using real taxed transfers.
        uint256 gross = amount * 1000 / 980;
        gross = gross > 16 ? gross - 16 : 1;
        while (gross - gross / 25 + _taxRewards(gross) != amount) ++gross;
        uint256 beforePool = registry.rewardsPool();
        token.approve(address(registry), gross);
        registry.fundRewards(gross);
        assertEq(registry.rewardsPool() - beforePool, amount);
    }

    function _fundResources(uint256 amount) private {
        // Gross-up fixture funding to an exact resource-pot increase; reward tax still accrues.
        uint256 gross = amount * 1000 / 972;
        gross = gross > 16 ? gross - 16 : 1;
        while (gross - gross / 25 + (gross / 25) * 3 / 10 != amount) ++gross;
        uint256 beforePot = registry.resourcePot();
        token.approve(address(registry), gross);
        registry.fundResources(gross);
        assertEq(registry.resourcePot() - beforePot, amount);
    }

    function _grant(uint256 cityId, uint256 amount) private {
        vm.prank(OPERATOR);
        executor.grantResources(address(registry), cityId, amount);
    }

    function _claim(address owner, uint256 cityId, uint256 expected) private {
        uint256 balanceBefore = token.balanceOf(owner);
        uint256 rewardsBefore = registry.rewardsPool();
        uint256 resourcesBefore = registry.resourcePot();
        assertEq(registry.claimableRewards(cityId), expected);
        vm.prank(owner);
        vm.expectEmit(true, true, false, true, address(registry));
        emit RewardsClaimed(cityId, owner, expected);
        assertEq(registry.claimRewards(cityId), expected);
        assertEq(token.balanceOf(owner), balanceBefore + expected - expected / 25);
        assertEq(registry.rewardsPool(), rewardsBefore - expected + _taxRewards(expected));
        assertEq(registry.resourcePot(), resourcesBefore + (expected / 25) * 3 / 10);
        _assertBacking();
    }

    function _taxRewards(uint256 amount) private pure returns (uint256) {
        uint256 fee = amount / 25;
        return fee - fee * 3 / 10 - 2 * (fee / 10);
    }

    function _assertCity(uint256 cityId, address owner, uint256 level, uint256 resources) private view {
        (address actualOwner, uint256 actualLevel, uint256 actualResources,,) = registry.cities(cityId);
        assertEq(actualOwner, owner);
        assertEq(actualLevel, level);
        assertEq(actualResources, resources);
    }

    function _assertBacking() private view {
        assertEq(
            token.balanceOf(address(registry)),
            registry.rewardsPool() + registry.resourcePot() + registry.allocatedResourceBacking()
        );
    }
}
