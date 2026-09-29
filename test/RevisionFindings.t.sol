// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {GrantExecutor} from "../src/GrantExecutor.sol";
import {CityRegistry} from "../src/CityRegistry.sol";

contract RevisionFindingsTest is Test {
    address private constant OPERATOR = 0x5b95A971B4583A5f011E9DA082acdD679b870D06;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant CAROL = address(0xCA401);
    address private constant RECIPIENT = address(0xD00D);
    LaunchToken private token;
    GrantExecutor private executor;
    CityRegistry private registry;

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
        deal(address(token), ALICE, 1_000_000e18);
        deal(address(token), BOB, 1_000_000e18);
        deal(address(token), CAROL, 1_000_000e18);
    }

    /// @dev Both standard routes must charge the approved levy and emit the token event.
    function testOrdinaryTransferAndTransferFromCollectTax() public {
        uint256 supply = token.totalSupply();
        vm.recordLogs();
        vm.prank(ALICE);
        token.transfer(RECIPIENT, 1000e18);
        vm.prank(ALICE);
        token.approve(BOB, 1000e18);
        vm.prank(BOB);
        token.transferFrom(ALICE, address(0xD00E), 1000e18);
        assertEq(token.balanceOf(RECIPIENT), 960e18);
        assertEq(token.balanceOf(address(0xD00E)), 960e18);
        assertEq(token.balanceOf(ALICE), 998_000e18);
        assertEq(token.allowance(ALICE, BOB), 0);
        assertEq(registry.rewardsPool(), 40e18);
        assertEq(registry.resourcePot(), 24e18);
        assertEq(token.balanceOf(OPERATOR), 8e18);
        assertEq(token.totalSupply(), supply - 8e18);
        assertEq(
            registry.rewardsPool() + registry.resourcePot() + token.balanceOf(OPERATOR) + supply
                - token.totalSupply(),
            80e18
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 taxTopic =
            keccak256("TaxTaken(address,address,uint256,uint256,uint256,uint256,uint256,uint256)");
        uint256 taxEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(token) && logs[i].topics[0] == taxTopic) ++taxEvents;
        }
        assertEq(taxEvents, 2);
    }

    /// @dev Negative integration example: an oversized allowance is not a quote bound.
    function testOverApprovalAllowsBurnAboveDisplayedQuote() public {
        uint256 quote = registry.cityPrice();
        vm.prank(ALICE);
        token.approve(address(registry), type(uint256).max);
        _buy(BOB, 7);
        uint256 beforeBalance = token.balanceOf(ALICE);
        vm.prank(ALICE);
        registry.buyCity(5);
        assertEq(quote, 10_000e18);
        assertEq(beforeBalance - token.balanceOf(ALICE), 10_078_277_587_890_625_000_000);
    }

    function testExactAllowanceRejectsStaleQuoteAndAllowsExplicitRequote() public {
        token.approve(address(registry), 100e18);
        registry.fundRewards(100e18);
        uint256 quote = registry.cityPrice();
        vm.prank(ALICE);
        token.approve(address(registry), quote);
        _buy(BOB, 7);
        uint256 updatedPrice = registry.cityPrice();
        uint256 balance = token.balanceOf(ALICE);
        uint256 supply = token.totalSupply();
        uint256 index = registry.accRewardPerWeight();
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(registry), quote, updatedPrice
            )
        );
        vm.prank(ALICE);
        registry.buyCity(5);
        assertEq(token.balanceOf(ALICE), balance);
        assertEq(token.totalSupply(), supply);
        assertEq(token.allowance(ALICE, address(registry)), quote);
        assertEq(registry.cityOf(ALICE), 0);
        assertEq(registry.soldPlots(), 1);
        assertEq(registry.totalWeight(), 1);
        assertEq(registry.accRewardPerWeight(), index);
        assertEq(registry.claimableRewards(7), 98e18);
        (address owner, uint256 level, uint256 resources,,) = registry.cities(5);
        assertEq(owner, address(0));
        assertEq(level, 0);
        assertEq(resources, 0);

        // Model acceptance of a new displayed quote; never silently raise the allowance.
        vm.startPrank(ALICE);
        token.approve(address(registry), updatedPrice);
        registry.buyCity(5);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), balance - updatedPrice);
        assertEq(token.totalSupply(), supply - updatedPrice);
        assertEq(token.allowance(ALICE, address(registry)), 0);
        assertEq(registry.cityOf(ALICE), 6);
        assertEq(registry.claimableRewards(5), 0);
    }

    function testUniversalFeeBoundariesAllocateDustToRewards() public {
        _assertTax(1, 0, 0, 0, 0, 0);
        _assertTax(24, 0, 0, 0, 0, 0);
        _assertTax(25, 1, 1, 0, 0, 0);
        _assertTax(26, 1, 1, 0, 0, 0);
        _assertTax(225, 9, 7, 2, 0, 0);
        _assertTax(226, 9, 7, 2, 0, 0);
        _assertTax(249, 9, 7, 2, 0, 0);
        _assertTax(250, 10, 5, 3, 1, 1);
        _assertTax(625, 25, 14, 7, 2, 2);
        _assertTax(1000e18, 40e18, 20e18, 12e18, 4e18, 4e18);
    }

    function testTinyFeeDustBecomesClaimableRewards() public {
        _assertTax(25, 1, 1, 0, 0, 0);
        _buy(ALICE, 0);
        assertEq(registry.claimableRewards(0), 1);
        uint256 balance = token.balanceOf(ALICE);
        vm.prank(ALICE);
        assertEq(registry.claimRewards(0), 1);
        assertEq(token.balanceOf(ALICE), balance + 1);
        assertEq(registry.rewardsPool(), 0);
        assertEq(token.balanceOf(address(registry)), 0);
    }

    function testGrantBackingBurnsOnlyAsResourcesAreConsumed() public {
        _buy(ALICE, 0);
        token.approve(address(registry), 1500e18);
        registry.fundResources(1500e18);
        uint256 supply = token.totalSupply();
        vm.prank(OPERATOR);
        executor.grantResources(address(registry), 0, 1300);
        assertEq(token.totalSupply(), supply);
        assertEq(registry.resourcePot(), 158e18);
        assertEq(registry.allocatedResourceBacking(), 1300e18);
        vm.prank(ALICE);
        registry.levelUp(0);
        (, uint256 level, uint256 resources,,) = registry.cities(0);
        assertEq(level, 2);
        assertEq(resources, 900);
        assertEq(registry.allocatedResourceBacking(), 900e18);
        assertEq(token.balanceOf(address(registry)), 1088e18);
        assertEq(token.totalSupply(), supply - 400e18);
        vm.prank(ALICE);
        registry.levelUp(0);
        (, level, resources,,) = registry.cities(0);
        assertEq(level, 3);
        assertEq(resources, 0);
        assertEq(registry.allocatedResourceBacking(), 0);
        assertEq(registry.resourcePot(), 158e18);
        assertEq(token.balanceOf(address(registry)), 188e18);
        assertEq(token.totalSupply(), supply - 1300e18);
        assertEq(token.balanceOf(OPERATOR), 6e18);
    }

    function testHeartbeatBackingIsBurnedOnConsumptionForEachWinner() public {
        _buy(ALICE, 0);
        _buy(BOB, 1);
        _buy(CAROL, 2);
        token.approve(address(registry), 1250e18);
        registry.fundResources(1250e18);
        uint256 supply = token.totalSupply();
        vm.prank(OPERATOR);
        executor.recordHeartbeat(address(registry), 0, 400, 1, 400, 2, 400);
        assertEq(token.totalSupply(), supply);
        vm.prank(ALICE);
        registry.levelUp(0);
        assertEq(registry.allocatedResourceBacking(), 800e18);
        vm.prank(BOB);
        registry.levelUp(1);
        vm.prank(CAROL);
        registry.levelUp(2);
        assertEq(registry.resourcePot(), 15e18);
        assertEq(registry.rewardsPool(), 25e18);
        assertEq(registry.allocatedResourceBacking(), 0);
        assertEq(token.balanceOf(address(registry)), 40e18);
        assertEq(token.totalSupply(), supply - 1200e18);
        assertEq(registry.heartbeatCount(), 1);
        for (uint256 i; i < 3; ++i) {
            assertEq(registry.lastHeartbeatCityIds(i), i);
            assertEq(registry.lastHeartbeatAmounts(i), 400);
            (, uint256 level, uint256 resources,,) = registry.cities(i);
            assertEq(level, 2);
            assertEq(resources, 0);
        }
    }

    function _buy(address buyer, uint256 cityId) private {
        uint256 quote = registry.cityPrice();
        vm.startPrank(buyer);
        token.approve(address(registry), quote);
        registry.buyCity(cityId);
        vm.stopPrank();
    }

    function _assertTax(
        uint256 gross,
        uint256 fee,
        uint256 rewards,
        uint256 resources,
        uint256 burned,
        uint256 treasuryAmount
    ) private {
        uint256 supply = token.totalSupply();
        uint256 senderBalance = token.balanceOf(address(this));
        uint256 netBefore = token.balanceOf(RECIPIENT);
        uint256 rewardsBefore = registry.rewardsPool();
        uint256 resourcesBefore = registry.resourcePot();
        uint256 treasuryBefore = token.balanceOf(OPERATOR);
        token.approve(address(registry), gross);
        vm.expectEmit(true, true, false, true, address(token));
        emit TaxTaken(address(this), RECIPIENT, gross, fee, rewards, resources, burned, treasuryAmount);
        registry.transferWithTax(RECIPIENT, gross);
        assertEq(token.balanceOf(RECIPIENT) - netBefore, gross - fee);
        assertEq(registry.rewardsPool() - rewardsBefore, rewards);
        assertEq(registry.resourcePot() - resourcesBefore, resources);
        assertEq(supply - token.totalSupply(), burned);
        assertEq(token.balanceOf(OPERATOR) - treasuryBefore, treasuryAmount);
        assertEq(senderBalance - token.balanceOf(address(this)), gross);
        assertEq(rewards + resources + burned + treasuryAmount, fee);
        assertEq(token.allowance(address(this), address(registry)), 0);
        assertEq(token.balanceOf(address(registry)), registry.rewardsPool() + registry.resourcePot());
    }
}
