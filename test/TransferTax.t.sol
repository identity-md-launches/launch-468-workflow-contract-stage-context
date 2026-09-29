// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {CityRegistry} from "../src/CityRegistry.sol";
import {GrantExecutor} from "../src/GrantExecutor.sol";

/// @notice Integration coverage uses the actual taxed token and actual pool accounting.
contract TransferTaxIntegrationTest is Test {
    address private constant TREASURY = 0x5b95A971B4583A5f011E9DA082acdD679b870D06;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant SPENDER = address(0x5EED);
    uint256 private constant INITIAL_SUPPLY = 1_000_000_000 ether;
    bytes32 private constant TAX_TOPIC =
        keccak256("TaxTaken(address,address,uint256,uint256,uint256,uint256,uint256,uint256)");
    LaunchToken private token;
    GrantExecutor private executor;
    CityRegistry private registry;

    event CityRegistrySet(address indexed registry);
    event RewardsClaimed(uint256 indexed cityId, address indexed owner, uint256 amount);

    function setUp() public {
        token = new LaunchToken();
        executor = new GrantExecutor(TREASURY);
        registry = new CityRegistry(address(token), address(executor));
    }

    function testOnlyDeployerCanBindRegistry() public {
        vm.expectRevert(LaunchToken.Unauthorized.selector);
        vm.prank(ALICE);
        token.setCityRegistry(address(registry));
        assertEq(token.cityRegistry(), address(0));
        vm.expectEmit(true, false, false, true, address(token));
        emit CityRegistrySet(address(registry));
        token.setCityRegistry(address(registry));
        assertEq(token.cityRegistry(), address(registry));
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(address(this)), INITIAL_SUPPLY);
    }

    function testRegistryBindingIsPermanentEvenForDeployer() public {
        token.setCityRegistry(address(registry));
        CityRegistry another = new CityRegistry(address(token), address(executor));
        vm.expectRevert(LaunchToken.RegistryAlreadySet.selector);
        token.setCityRegistry(address(another));
        vm.expectRevert(LaunchToken.RegistryAlreadySet.selector);
        token.setCityRegistry(address(registry));
        assertEq(token.cityRegistry(), address(registry));
    }

    function testBindingRejectsZeroEoaTokenAndMissingInterface() public {
        address[3] memory badAddresses = [address(0), ALICE, address(token)];
        for (uint256 i; i < badAddresses.length; ++i) {
            vm.expectRevert(LaunchToken.InvalidRegistry.selector);
            token.setCityRegistry(badAddresses[i]);
            assertEq(token.cityRegistry(), address(0));
        }
        MissingTaxReceiverInterface empty = new MissingTaxReceiverInterface();
        vm.expectRevert();
        token.setCityRegistry(address(empty));
        assertEq(token.cityRegistry(), address(0));
    }

    function testBindingRejectsDifferentTokenOrTreasuryWithoutLosingEscrow() public {
        token.transfer(ALICE, 1000 ether);
        LaunchToken otherToken = new LaunchToken();
        CityRegistry wrongToken = new CityRegistry(address(otherToken), address(executor));
        GrantExecutor wrongExecutor = new GrantExecutor(ALICE);
        CityRegistry wrongTreasury = new CityRegistry(address(token), address(wrongExecutor));
        vm.expectRevert(LaunchToken.InvalidRegistry.selector);
        token.setCityRegistry(address(wrongToken));
        vm.expectRevert(LaunchToken.InvalidRegistry.selector);
        token.setCityRegistry(address(wrongTreasury));
        assertEq(token.cityRegistry(), address(0));
        assertEq(token.pendingRewards(), 20 ether);
        assertEq(token.pendingResources(), 12 ether);
        assertEq(token.balanceOf(address(token)), 32 ether);
        assertEq(token.balanceOf(address(registry)), 0);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 4 ether);
    }

    function testPrebindingTaxesAccumulateAndFlushExactlyOnceWithoutAnotherTax() public {
        token.transfer(ALICE, 1000 ether);
        token.transfer(BOB, 250 ether);
        assertEq(token.pendingRewards(), 25 ether);
        assertEq(token.pendingResources(), 15 ether);
        assertEq(token.balanceOf(address(token)), 40 ether);
        assertEq(token.balanceOf(TREASURY), 5 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 5 ether);
        vm.recordLogs();
        token.setCityRegistry(address(registry));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != TAX_TOPIC, "escrow settlement must not levy a second tax");
        }
        assertEq(token.cityRegistry(), address(registry));
        assertEq(token.pendingRewards(), 0);
        assertEq(token.pendingResources(), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(registry)), 40 ether);
        assertEq(registry.rewardsPool(), 25 ether);
        assertEq(registry.queuedRewards(), 25 ether);
        assertEq(registry.resourcePot(), 15 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 5 ether);
        assertEq(token.balanceOf(TREASURY), 5 ether);
        _assertBacking();
    }

    function testDirectDonationToTokenDoesNotBecomePendingPoolLiability() public {
        token.transfer(address(token), 1000 ether);
        token.setCityRegistry(address(registry));
        assertEq(token.balanceOf(address(token)), 960 ether);
        assertEq(token.balanceOf(address(registry)), 32 ether);
        assertEq(registry.rewardsPool(), 20 ether);
        assertEq(registry.resourcePot(), 12 ether);
        _assertBacking();
    }

    function testBoundTransferCreditsFourExactSplitsAndSingleTaxEvent() public {
        token.setCityRegistry(address(registry));
        vm.recordLogs();
        token.transfer(ALICE, 1000 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 taxEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(token) && logs[i].topics[0] == TAX_TOPIC) {
                ++taxEvents;
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(this)))));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(ALICE))));
                assertEq(logs[i].data, abi.encode(1000 ether, 40 ether, 20 ether, 12 ether, 4 ether, 4 ether));
            }
        }
        assertEq(taxEvents, 1);
        assertEq(token.balanceOf(ALICE), 960 ether);
        assertEq(registry.rewardsPool(), 20 ether);
        assertEq(registry.resourcePot(), 12 ether);
        assertEq(token.balanceOf(TREASURY), 4 ether);
        assertEq(INITIAL_SUPPLY - token.totalSupply(), 4 ether);
        assertEq(
            registry.rewardsPool() + registry.resourcePot() + token.balanceOf(TREASURY) + INITIAL_SUPPLY
                - token.totalSupply(),
            40 ether
        );
        assertEq(token.pendingRewards(), 0);
        assertEq(token.pendingResources(), 0);
        _assertBacking();
    }

    function testBoundTransferFromCreditsFourSplitsAndConsumesGrossAllowance() public {
        token.setCityRegistry(address(registry));
        token.approve(SPENDER, 1000 ether);
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1000 ether);
        assertEq(token.allowance(address(this), SPENDER), 0);
        assertEq(token.balanceOf(ALICE), 960 ether);
        assertEq(registry.rewardsPool(), 20 ether);
        assertEq(registry.resourcePot(), 12 ether);
        assertEq(token.balanceOf(TREASURY), 4 ether);
        assertEq(INITIAL_SUPPLY - token.totalSupply(), 4 ether);
        assertEq(
            registry.rewardsPool() + registry.resourcePot() + token.balanceOf(TREASURY) + INITIAL_SUPPLY
                - token.totalSupply(),
            40 ether
        );
        _assertBacking();
    }

    function testOrdinarySenderCannotForgeTaxCredits() public {
        token.setCityRegistry(address(registry));
        address[4] memory callers = [address(this), ALICE, TREASURY, address(executor)];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(CityRegistry.UnauthorizedToken.selector);
            vm.prank(callers[i]);
            registry.onTaxReceived(1000 ether, 1000 ether);
        }
        assertEq(registry.rewardsPool(), 0);
        assertEq(registry.resourcePot(), 0);
        assertEq(registry.queuedRewards(), 0);
        assertEq(registry.accRewardPerWeight(), 0);
        _assertBacking();
    }

    function testFundRewardsAccountsNetReceiptPlusTaxOnlyOnce() public {
        token.setCityRegistry(address(registry));
        token.approve(address(registry), 1000 ether);
        registry.fundRewards(1000 ether);
        assertEq(token.allowance(address(this), address(registry)), 0);
        assertEq(registry.rewardsPool(), 980 ether);
        assertEq(registry.queuedRewards(), 980 ether);
        assertEq(registry.resourcePot(), 12 ether);
        assertEq(token.balanceOf(address(registry)), 992 ether);
        assertEq(token.balanceOf(TREASURY), 4 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 4 ether);
        _assertBacking();
    }

    function testFundResourcesAccountsNetReceiptPlusTaxOnlyOnce() public {
        token.setCityRegistry(address(registry));
        token.approve(address(registry), 1000 ether);
        registry.fundResources(1000 ether);
        assertEq(token.allowance(address(this), address(registry)), 0);
        assertEq(registry.rewardsPool(), 20 ether);
        assertEq(registry.queuedRewards(), 20 ether);
        assertEq(registry.resourcePot(), 972 ether);
        assertEq(token.balanceOf(address(registry)), 992 ether);
        _assertBacking();
    }

    function testSequentialRewardAndResourceFundingRemainFullyBacked() public {
        token.setCityRegistry(address(registry));
        token.approve(address(registry), 1500 ether);
        registry.fundRewards(1000 ether);
        registry.fundResources(500 ether);
        assertEq(registry.rewardsPool(), 990 ether);
        assertEq(registry.resourcePot(), 498 ether);
        assertEq(token.balanceOf(address(registry)), 1488 ether);
        assertEq(token.balanceOf(TREASURY), 6 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 6 ether);
        _assertBacking();
    }

    function testFundingBeforeBindingCreditsNetAndFlushAddsOnlyEscrowedTax() public {
        token.approve(address(registry), 1000 ether);
        registry.fundRewards(1000 ether);
        assertEq(registry.rewardsPool(), 960 ether);
        assertEq(registry.resourcePot(), 0);
        assertEq(token.balanceOf(address(registry)), 960 ether);
        assertEq(token.pendingRewards(), 20 ether);
        assertEq(token.pendingResources(), 12 ether);
        _assertBacking();
        token.setCityRegistry(address(registry));
        assertEq(registry.rewardsPool(), 980 ether);
        assertEq(registry.resourcePot(), 12 ether);
        _assertBacking();
    }

    function testFundingRevertRollsBackPoolsAllowanceAndTax() public {
        token.setCityRegistry(address(registry));
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(address(registry), 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 96 ether, 100 ether)
        );
        vm.prank(ALICE);
        registry.fundRewards(100 ether);
        assertEq(token.allowance(ALICE, address(registry)), 100 ether);
        assertEq(token.balanceOf(ALICE), 96 ether);
        assertEq(registry.rewardsPool(), 2 ether);
        assertEq(registry.resourcePot(), 1.2 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 0.4 ether);
        assertEq(token.balanceOf(TREASURY), 0.4 ether);
        _assertBacking();
    }

    function testCompatibilityWrapperChargesOnlyOneFourPercentTax() public {
        token.setCityRegistry(address(registry));
        token.approve(address(registry), 1000 ether);
        registry.transferWithTax(ALICE, 1000 ether);
        assertEq(token.allowance(address(this), address(registry)), 0);
        assertEq(token.balanceOf(ALICE), 960 ether);
        assertEq(registry.rewardsPool(), 20 ether);
        assertEq(registry.resourcePot(), 12 ether);
        assertEq(token.balanceOf(TREASURY), 4 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 4 ether);
        _assertBacking();
    }

    function testRegistryRecipientIsTaxedAndDirectDonationIsNotCountedTwice() public {
        token.setCityRegistry(address(registry));
        token.transfer(address(registry), 1000 ether);
        assertEq(token.balanceOf(address(registry)), 992 ether);
        assertEq(registry.rewardsPool(), 20 ether);
        assertEq(registry.resourcePot(), 12 ether);
        assertEq(
            token.balanceOf(address(registry)) - registry.rewardsPool() - registry.resourcePot(), 960 ether
        );
        assertEq(token.balanceOf(TREASURY), 4 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 4 ether);
    }

    function testClaimSendsNetRewardsAndReplenishesPoolsWithoutLosingNewEntitlement() public {
        token.setCityRegistry(address(registry));
        token.transfer(ALICE, 25_000 ether);
        vm.startPrank(ALICE);
        token.approve(address(registry), 10_000 ether);
        registry.buyCity(0);
        vm.stopPrank();
        token.approve(address(registry), 1000 ether);
        registry.fundRewards(1000 ether);
        assertEq(registry.claimableRewards(0), 1480 ether);
        uint256 supplyBefore = token.totalSupply();
        uint256 holderBefore = token.balanceOf(ALICE);
        uint256 treasuryBefore = token.balanceOf(TREASURY);
        vm.expectEmit(true, true, false, true, address(registry));
        emit RewardsClaimed(0, ALICE, 1480 ether);
        vm.prank(ALICE);
        uint256 gross = registry.claimRewards(0);
        assertEq(gross, 1480 ether);
        assertEq(token.balanceOf(ALICE) - holderBefore, 1420.8 ether);
        assertEq(registry.rewardsPool(), 29.6 ether);
        assertEq(registry.resourcePot(), 329.76 ether);
        assertEq(registry.claimableRewards(0), 29.6 ether);
        assertEq(supplyBefore - token.totalSupply(), 5.92 ether);
        assertEq(token.balanceOf(TREASURY) - treasuryBefore, 5.92 ether);
        _assertBacking();
        vm.prank(ALICE);
        assertEq(registry.claimRewards(0), 29.6 ether);
        assertEq(registry.claimableRewards(0), 0.592 ether);
        assertEq(registry.rewardsPool(), 0.592 ether);
        _assertBacking();
    }

    function testTreasuryCityOwnerReceivesNetClaimAndTreasuryShare() public {
        token.setCityRegistry(address(registry));
        token.transfer(TREASURY, 25_000 ether);
        vm.startPrank(TREASURY);
        token.approve(address(registry), 10_000 ether);
        registry.buyCity(0);
        vm.stopPrank();
        assertEq(registry.claimableRewards(0), 500 ether);
        uint256 beforeBalance = token.balanceOf(TREASURY);
        vm.prank(TREASURY);
        assertEq(registry.claimRewards(0), 500 ether);
        assertEq(token.balanceOf(TREASURY) - beforeBalance, 482 ether);
        assertEq(registry.rewardsPool(), 10 ether);
        assertEq(registry.resourcePot(), 306 ether);
        _assertBacking();
    }

    function testRevertingEscrowCallbackRestoresBindingAndAllPendingBalances() public {
        token.transfer(ALICE, 1000 ether);
        RevertingTaxReceiver receiver = new RevertingTaxReceiver(address(token), TREASURY);
        receiver.setReject(true);
        vm.expectRevert(RevertingTaxReceiver.TaxRejected.selector);
        token.setCityRegistry(address(receiver));
        assertEq(token.cityRegistry(), address(0));
        assertEq(token.pendingRewards(), 20 ether);
        assertEq(token.pendingResources(), 12 ether);
        assertEq(token.balanceOf(address(token)), 32 ether);
        assertEq(token.balanceOf(address(receiver)), 0);
        assertEq(token.balanceOf(ALICE), 960 ether);
        assertEq(token.balanceOf(TREASURY), 4 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 4 ether);
        assertEq(receiver.callbacks(), 0);
        assertEq(receiver.rewards(), 0);
        assertEq(receiver.resources(), 0);
        receiver.setReject(false);
        token.setCityRegistry(address(receiver));
        assertEq(token.cityRegistry(), address(receiver));
        assertEq(token.pendingRewards(), 0);
        assertEq(token.pendingResources(), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(receiver)), 32 ether);
        assertEq(receiver.callbacks(), 1);
        assertEq(receiver.rewards(), 20 ether);
        assertEq(receiver.resources(), 12 ether);
    }

    function testRevertingTransferCallbackRestoresRecipientTreasurySupplyAndAllowance() public {
        RevertingTaxReceiver receiver = new RevertingTaxReceiver(address(token), TREASURY);
        token.setCityRegistry(address(receiver));
        receiver.setReject(true);
        token.approve(SPENDER, 1000 ether);
        vm.expectRevert(RevertingTaxReceiver.TaxRejected.selector);
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1000 ether);
        assertEq(token.allowance(address(this), SPENDER), 1000 ether);
        vm.expectRevert(RevertingTaxReceiver.TaxRejected.selector);
        token.transfer(ALICE, 1000 ether);
        assertEq(token.balanceOf(address(this)), INITIAL_SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(TREASURY), 0);
        assertEq(token.balanceOf(address(receiver)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.pendingRewards(), 0);
        assertEq(token.pendingResources(), 0);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(receiver.callbacks(), 0);
        assertEq(receiver.rewards(), 0);
        assertEq(receiver.resources(), 0);
        receiver.setReject(false);
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1000 ether);
        assertEq(token.allowance(address(this), SPENDER), 0);
        assertEq(token.balanceOf(ALICE), 960 ether);
        assertEq(token.balanceOf(address(receiver)), 32 ether);
        assertEq(receiver.callbacks(), 1);
        assertEq(receiver.rewards(), 20 ether);
        assertEq(receiver.resources(), 12 ether);
    }

    function testFuzzBoundTransfersSplitAndBackPools(uint256 amount) public {
        token.setCityRegistry(address(registry));
        amount = bound(amount, 0, INITIAL_SUPPLY);
        token.transfer(ALICE, amount);
        uint256 fee = amount * 400 / 10_000;
        uint256 burned = INITIAL_SUPPLY - token.totalSupply();
        assertEq(token.balanceOf(ALICE), amount - fee);
        assertEq(registry.resourcePot(), fee * 30 / 100);
        assertEq(burned, fee * 10 / 100);
        assertEq(token.balanceOf(TREASURY), fee * 10 / 100);
        assertEq(registry.rewardsPool() + registry.resourcePot() + burned + token.balanceOf(TREASURY), fee);
        assertEq(registry.queuedRewards(), registry.rewardsPool());
        _assertBacking();
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(ALICE) + token.balanceOf(TREASURY)
                + token.balanceOf(address(registry)),
            token.totalSupply()
        );
    }

    function _assertBacking() private view {
        assertEq(
            token.balanceOf(address(registry)),
            registry.rewardsPool() + registry.resourcePot() + registry.allocatedResourceBacking()
        );
    }
}

contract MissingTaxReceiverInterface {}

/// @dev Binding getters cannot prove receiver behavior; deployment must validate the implementation.
contract RevertingTaxReceiver {
    address public immutable token;
    address public immutable treasury;
    bool public reject;
    uint256 public callbacks;
    uint256 public rewards;
    uint256 public resources;

    error TaxRejected();

    constructor(address token_, address treasury_) {
        token = token_;
        treasury = treasury_;
    }

    function setReject(bool reject_) external {
        reject = reject_;
    }

    function onTaxReceived(uint256 rewards_, uint256 resources_) external {
        require(msg.sender == token);
        ++callbacks;
        rewards += rewards_;
        resources += resources_;
        if (reject) revert TaxRejected();
    }
}
