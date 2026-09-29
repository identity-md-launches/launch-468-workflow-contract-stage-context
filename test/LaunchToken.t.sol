// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    uint256 private constant INITIAL_SUPPLY = 1_000_000_000 ether;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant SPENDER = address(0x5EED);
    address private constant TREASURY = 0x5b95A971B4583A5f011E9DA082acdD679b870D06;
    bytes32 private constant TAX_TOPIC =
        keccak256("TaxTaken(address,address,uint256,uint256,uint256,uint256,uint256,uint256)");
    LaunchToken private token;

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
    }

    function testMetadataAndWholeSupplyMintedToDeployer() public view {
        assertEq(token.name(), "Swarm Cities");
        assertEq(token.symbol(), "GRID");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(address(this)), INITIAL_SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.TAX_BPS(), 400);
        assertEq(token.TREASURY(), TREASURY);
        assertEq(token.deployer(), address(this));
        assertEq(token.cityRegistry(), address(0));
    }

    function testConstructorMintsToCallingFactory() public {
        TokenDeployingFactory factory = new TokenDeployingFactory();
        LaunchToken deployed = factory.deploy();
        assertEq(deployed.balanceOf(address(factory)), INITIAL_SUPPLY);
        assertEq(deployed.balanceOf(address(this)), 0);
        assertEq(deployed.deployer(), address(factory));
    }

    function testTransferTakesFourPercentAndExactFourSplits() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit TaxTaken(
            address(this), ALICE, 25_000 ether, 1000 ether, 500 ether, 300 ether, 100 ether, 100 ether
        );
        assertTrue(token.transfer(ALICE, 25_000 ether));
        assertEq(token.balanceOf(ALICE), 24_000 ether);
        assertEq(token.balanceOf(address(this)), INITIAL_SUPPLY - 25_000 ether);
        assertEq(token.pendingRewards(), 500 ether);
        assertEq(token.pendingResources(), 300 ether);
        assertEq(token.balanceOf(address(token)), 800 ether);
        assertEq(token.balanceOf(TREASURY), 100 ether);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(INITIAL_SUPPLY - token.totalSupply(), 100 ether);
        assertEq(
            token.pendingRewards() + token.pendingResources() + token.balanceOf(TREASURY) + INITIAL_SUPPLY
                - token.totalSupply(),
            1000 ether
        );
        _assertSupplyBacked();
    }

    function testTransferFromTaxesGrossAndConsumesGrossAllowance() public {
        token.transfer(ALICE, 2000 ether);
        vm.prank(ALICE);
        token.approve(SPENDER, 1000 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit TaxTaken(ALICE, BOB, 750 ether, 30 ether, 15 ether, 9 ether, 3 ether, 3 ether);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 750 ether));
        assertEq(token.allowance(ALICE, SPENDER), 250 ether);
        assertEq(token.balanceOf(ALICE), 1170 ether);
        assertEq(token.balanceOf(BOB), 720 ether);
        assertEq(token.pendingRewards(), 55 ether);
        assertEq(token.pendingResources(), 33 ether);
        assertEq(token.balanceOf(TREASURY), 11 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 11 ether);
        _assertSupplyBacked();
    }

    function testTransferFromWithoutApprovalReverts() public {
        token.transfer(ALICE, 1000 ether);
        bytes32 beforeState = _state();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1 ether)
        );
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1 ether);
        assertEq(_state(), beforeState);
    }

    function testNetAmountAllowanceIsInsufficientForGrossTransfer() public {
        token.transfer(ALICE, 1000 ether);
        vm.prank(ALICE);
        token.approve(SPENDER, 96 ether);
        bytes32 beforeState = _state();
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 96 ether, 100 ether
            )
        );
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100 ether);
        assertEq(_state(), beforeState);
    }

    function testTransferToZeroReverts() public {
        bytes32 beforeState = _state();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);
        assertEq(_state(), beforeState);
    }

    function testTransferExceedingBalanceReverts() public {
        bytes32 beforeState = _state();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1 ether)
        );
        vm.prank(ALICE);
        token.transfer(BOB, 1 ether);
        assertEq(_state(), beforeState);
    }

    function testRevertingTransferFromRestoresGrossAllowanceAndEveryTaxBalance() public {
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(SPENDER, 100 ether);
        bytes32 beforeState = _state();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 96 ether, 100 ether)
        );
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100 ether);
        assertEq(_state(), beforeState);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, address(0), 50 ether);
        assertEq(_state(), beforeState);
    }

    function testSelfTransferPaysTax() public {
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        assertTrue(token.transfer(ALICE, 50 ether));
        assertEq(token.balanceOf(ALICE), 94 ether);
        assertEq(token.pendingRewards(), 3 ether);
        assertEq(token.pendingResources(), 1.8 ether);
        assertEq(token.balanceOf(TREASURY), 0.6 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 0.6 ether);
        _assertSupplyBacked();
    }

    function testSelfTransferRequiresGrossBalance() public {
        token.transfer(ALICE, 100 ether);
        bytes32 beforeState = _state();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 96 ether, 100 ether)
        );
        vm.prank(ALICE);
        token.transfer(ALICE, 100 ether);
        assertEq(_state(), beforeState);
    }

    function testZeroTransferEmitsZeroTaxAndPreservesBalances() public {
        bytes32 beforeState = _state();
        vm.expectEmit(true, true, false, true, address(token));
        emit TaxTaken(ALICE, BOB, 0, 0, 0, 0, 0, 0);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(_state(), beforeState);
    }

    function testTinyTransfersAndRoundingAssignAllDustToRewards() public {
        uint256[8] memory amounts = [uint256(1), 24, 25, 49, 75, 225, 250, 275];
        uint256[8] memory fees = [uint256(0), 0, 1, 1, 3, 9, 10, 11];
        uint256[8] memory rewards = [uint256(0), 0, 1, 1, 3, 7, 5, 6];
        uint256[8] memory resources = [uint256(0), 0, 0, 0, 0, 2, 3, 3];
        uint256[8] memory burns = [uint256(0), 0, 0, 0, 0, 0, 1, 1];
        for (uint256 i; i < amounts.length; ++i) {
            uint256 beforeRewards = token.pendingRewards();
            uint256 beforeResources = token.pendingResources();
            uint256 beforeSupply = token.totalSupply();
            uint256 beforeTreasury = token.balanceOf(TREASURY);
            uint256 beforeRecipient = token.balanceOf(ALICE);
            vm.expectEmit(true, true, false, true, address(token));
            emit TaxTaken(
                address(this), ALICE, amounts[i], fees[i], rewards[i], resources[i], burns[i], burns[i]
            );
            token.transfer(ALICE, amounts[i]);
            assertEq(token.balanceOf(ALICE) - beforeRecipient, amounts[i] - fees[i]);
            assertEq(token.pendingRewards() - beforeRewards, rewards[i]);
            assertEq(token.pendingResources() - beforeResources, resources[i]);
            assertEq(beforeSupply - token.totalSupply(), burns[i]);
            assertEq(token.balanceOf(TREASURY) - beforeTreasury, burns[i]);
            assertEq(rewards[i] + resources[i] + 2 * burns[i], fees[i]);
            _assertSupplyBacked();
        }
    }

    function testTreasuryRecipientStillPaysFourPercent() public {
        token.transfer(TREASURY, 1000 ether);
        assertEq(token.balanceOf(TREASURY), 964 ether);
        assertEq(token.pendingRewards(), 20 ether);
        assertEq(token.pendingResources(), 12 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 4 ether);
        _assertSupplyBacked();
    }

    function testTreasurySenderReceivesItsShareWithoutTaxExemption() public {
        token.transfer(TREASURY, 1000 ether);
        vm.prank(TREASURY);
        token.transfer(ALICE, 500 ether);
        assertEq(token.balanceOf(TREASURY), 466 ether);
        assertEq(token.balanceOf(ALICE), 480 ether);
        assertEq(token.pendingRewards(), 30 ether);
        assertEq(token.pendingResources(), 18 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 6 ether);
        _assertSupplyBacked();
    }

    function testTokenRecipientEscrowsOnlyTaxNotDirectDonation() public {
        token.transfer(address(token), 1000 ether);
        assertEq(token.balanceOf(address(token)), 992 ether);
        assertEq(token.pendingRewards(), 20 ether);
        assertEq(token.pendingResources(), 12 ether);
        assertEq(token.balanceOf(TREASURY), 4 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 4 ether);
        _assertSupplyBacked();
    }

    function testTransferEntireSupplyWorksWithoutOverflowOrLeftoverDebit() public {
        token.transfer(ALICE, INITIAL_SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(ALICE), 960_000_000 ether);
        assertEq(token.pendingRewards(), 20_000_000 ether);
        assertEq(token.pendingResources(), 12_000_000 ether);
        assertEq(token.balanceOf(TREASURY), 4_000_000 ether);
        assertEq(token.totalSupply(), 996_000_000 ether);
        _assertSupplyBacked();
    }

    function testUintMaximumTaxQuoteDoesNotOverflowAndTransferFailsForBalance() public {
        assertEq(token.transferTax(type(uint256).max), type(uint256).max / 25);
        bytes32 beforeState = _state();
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                address(this),
                INITIAL_SUPPLY,
                type(uint256).max
            )
        );
        token.transfer(ALICE, type(uint256).max);
        assertEq(_state(), beforeState);
    }

    function testHolderBurnReducesBalanceAndSupplyWithoutTax() public {
        token.transfer(ALICE, 1000 ether);
        vm.recordLogs();
        vm.prank(ALICE);
        token.burn(400 ether);
        _assertNoTaxLogs(vm.getRecordedLogs());
        assertEq(token.balanceOf(ALICE), 560 ether);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 404 ether);
        assertEq(token.pendingRewards(), 20 ether);
        assertEq(token.pendingResources(), 12 ether);
        assertEq(token.balanceOf(TREASURY), 4 ether);
        _assertSupplyBacked();
    }

    function testBurnFromRequiresAndConsumesAllowanceWithoutTax() public {
        token.transfer(ALICE, 1000 ether);
        vm.prank(ALICE);
        token.approve(SPENDER, 500 ether);
        vm.recordLogs();
        vm.prank(SPENDER);
        token.burnFrom(ALICE, 400 ether);
        _assertNoTaxLogs(vm.getRecordedLogs());
        assertEq(token.balanceOf(ALICE), 560 ether);
        assertEq(token.allowance(ALICE, SPENDER), 100 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 404 ether);
        bytes32 beforeState = _state();
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 100 ether, 101 ether
            )
        );
        vm.prank(SPENDER);
        token.burnFrom(ALICE, 101 ether);
        assertEq(_state(), beforeState);
    }

    function testBurnFromWithoutApprovalReverts() public {
        token.transfer(ALICE, 1000 ether);
        bytes32 beforeState = _state();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1 ether)
        );
        vm.prank(SPENDER);
        token.burnFrom(ALICE, 1 ether);
        assertEq(_state(), beforeState);
    }

    function testBurnExceedingBalanceReverts() public {
        token.transfer(ALICE, 100 ether);
        bytes32 beforeState = _state();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 96 ether, 101 ether)
        );
        vm.prank(ALICE);
        token.burn(101 ether);
        assertEq(_state(), beforeState);
    }

    function testRevertingBurnFromRestoresAllowance() public {
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(SPENDER, 101 ether);
        bytes32 beforeState = _state();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 96 ether, 101 ether)
        );
        vm.prank(SPENDER);
        token.burnFrom(ALICE, 101 ether);
        assertEq(_state(), beforeState);
    }

    function testUnlimitedAllowancePreservedByTaxedTransferAndUntaxedBurn() public {
        token.transfer(ALICE, 1000 ether);
        vm.prank(ALICE);
        token.approve(SPENDER, type(uint256).max);
        vm.startPrank(SPENDER);
        token.transferFrom(ALICE, BOB, 200 ether);
        token.burnFrom(ALICE, 300 ether);
        vm.stopPrank();
        assertEq(token.allowance(ALICE, SPENDER), type(uint256).max);
        assertEq(token.balanceOf(ALICE), 460 ether);
        assertEq(token.balanceOf(BOB), 192 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 304.8 ether);
        _assertSupplyBacked();
    }

    function testAdminAndMintSelectorsRevertForDeployerAndStranger() public {
        bytes[5] memory payloads = [
            abi.encodeWithSignature("mint(address,uint256)", ALICE, 1 ether),
            abi.encodeWithSignature("transferOwnership(address)", ALICE),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("upgradeTo(address)", ALICE),
            abi.encodeWithSignature("initialize(address)", ALICE)
        ];
        for (uint256 i; i < payloads.length; ++i) {
            (bool deployerSuccess,) = address(token).call(payloads[i]);
            assertFalse(deployerSuccess);
            vm.prank(ALICE);
            (bool strangerSuccess,) = address(token).call(payloads[i]);
            assertFalse(strangerSuccess);
        }
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function testFuzzTransfersAndBurnsConserveSupply(uint256 transferAmount, uint256 burnAmount) public {
        transferAmount = bound(transferAmount, 0, INITIAL_SUPPLY);
        uint256 fee = transferAmount * 400 / 10_000;
        uint256 resourceShare = fee * 30 / 100;
        uint256 burnShare = fee * 10 / 100;
        uint256 treasuryShare = fee * 10 / 100;
        uint256 rewardShare = fee - resourceShare - burnShare - treasuryShare;
        burnAmount = bound(burnAmount, 0, transferAmount - fee);
        token.transfer(ALICE, transferAmount);
        vm.prank(ALICE);
        token.burn(burnAmount);
        assertEq(token.balanceOf(ALICE), transferAmount - fee - burnAmount);
        assertEq(token.balanceOf(address(this)), INITIAL_SUPPLY - transferAmount);
        assertEq(token.pendingRewards(), rewardShare);
        assertEq(token.pendingResources(), resourceShare);
        assertEq(token.balanceOf(TREASURY), treasuryShare);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - burnShare - burnAmount);
        assertEq(rewardShare + resourceShare + burnShare + treasuryShare, fee);
        _assertSupplyBacked();
    }

    function testFuzzTransferFromFourSplitsMatchTaxAndConserveSupply(uint256 amount) public {
        amount = bound(amount, 0, INITIAL_SUPPLY);
        token.approve(SPENDER, amount);
        vm.prank(SPENDER);
        token.transferFrom(address(this), BOB, amount);
        uint256 fee = amount * 400 / 10_000;
        assertEq(token.balanceOf(BOB), amount - fee);
        assertEq(token.balanceOf(address(this)), INITIAL_SUPPLY - amount);
        assertEq(token.allowance(address(this), SPENDER), 0);
        uint256 burnShare = INITIAL_SUPPLY - token.totalSupply();
        assertEq(token.pendingResources(), fee * 30 / 100);
        assertEq(burnShare, fee * 10 / 100);
        assertEq(token.balanceOf(TREASURY), fee * 10 / 100);
        assertEq(
            token.pendingRewards() + token.pendingResources() + burnShare + token.balanceOf(TREASURY), fee
        );
        _assertSupplyBacked();
    }

    function _assertSupplyBacked() private view {
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(ALICE) + token.balanceOf(BOB)
                + token.balanceOf(TREASURY) + token.balanceOf(address(token)),
            token.totalSupply()
        );
    }

    function _state() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                token.balanceOf(address(this)),
                token.balanceOf(ALICE),
                token.balanceOf(BOB),
                token.balanceOf(TREASURY),
                token.balanceOf(address(token)),
                token.totalSupply(),
                token.pendingRewards(),
                token.pendingResources(),
                token.allowance(ALICE, SPENDER)
            )
        );
    }

    function _assertNoTaxLogs(Vm.Log[] memory logs) private pure {
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != TAX_TOPIC);
        }
    }
}

contract TokenDeployingFactory {
    function deploy() external returns (LaunchToken) {
        return new LaunchToken();
    }
}
