// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    uint256 private constant INITIAL_SUPPLY = 1_000_000_000 ether;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant SPENDER = address(0x5EED);
    LaunchToken private token;

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
    }

    function testConstructorMintsToCallingFactory() public {
        TokenDeployingFactory factory = new TokenDeployingFactory();
        LaunchToken deployed = factory.deploy();
        assertEq(deployed.balanceOf(address(factory)), INITIAL_SUPPLY);
        assertEq(deployed.balanceOf(address(this)), 0);
    }

    function testTransferPreservesSupplyAndMovesExactAmount() public {
        uint256 amount = 25_000 ether;
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), INITIAL_SUPPLY - amount);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function testTransferFromConsumesAllowance() public {
        token.transfer(ALICE, 2_000 ether);
        vm.prank(ALICE);
        token.approve(SPENDER, 1_000 ether);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 750 ether));
        assertEq(token.allowance(ALICE, SPENDER), 250 ether);
        assertEq(token.balanceOf(ALICE), 1_250 ether);
        assertEq(token.balanceOf(BOB), 750 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function testTransferFromWithoutApprovalReverts() public {
        token.transfer(ALICE, 1_000 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1 ether)
        );
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1 ether);
        assertEq(token.balanceOf(ALICE), 1_000 ether);
        assertEq(token.balanceOf(BOB), 0);
    }

    function testTransferToZeroReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function testTransferExceedingBalanceReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1 ether)
        );
        vm.prank(ALICE);
        token.transfer(BOB, 1 ether);
    }

    function testSelfTransferAndZeroTransferPreserveBalances() public {
        token.transfer(ALICE, 100 ether);
        vm.startPrank(ALICE);
        assertTrue(token.transfer(ALICE, 100 ether));
        assertTrue(token.transfer(BOB, 0));
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function testHolderBurnReducesBalanceAndSupply() public {
        token.transfer(ALICE, 1_000 ether);
        vm.prank(ALICE);
        token.burn(400 ether);
        assertEq(token.balanceOf(ALICE), 600 ether);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 400 ether);
    }

    function testBurnFromRequiresAndConsumesAllowance() public {
        token.transfer(ALICE, 1_000 ether);
        vm.prank(ALICE);
        token.approve(SPENDER, 500 ether);
        vm.prank(SPENDER);
        token.burnFrom(ALICE, 400 ether);
        assertEq(token.balanceOf(ALICE), 600 ether);
        assertEq(token.allowance(ALICE, SPENDER), 100 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 400 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 100 ether, 101 ether
            )
        );
        vm.prank(SPENDER);
        token.burnFrom(ALICE, 101 ether);
        assertEq(token.balanceOf(ALICE), 600 ether);
        assertEq(token.allowance(ALICE, SPENDER), 100 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 400 ether);
    }

    function testBurnFromWithoutApprovalReverts() public {
        token.transfer(ALICE, 1_000 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1 ether)
        );
        vm.prank(SPENDER);
        token.burnFrom(ALICE, 1 ether);
        assertEq(token.balanceOf(ALICE), 1_000 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function testBurnExceedingBalanceReverts() public {
        token.transfer(ALICE, 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 100 ether, 101 ether
            )
        );
        vm.prank(ALICE);
        token.burn(101 ether);
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function testRevertingBurnFromRestoresAllowance() public {
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(SPENDER, 101 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 100 ether, 101 ether
            )
        );
        vm.prank(SPENDER);
        token.burnFrom(ALICE, 101 ether);
        assertEq(token.allowance(ALICE, SPENDER), 101 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function testUnlimitedAllowancePreservedByTransferAndBurn() public {
        token.transfer(ALICE, 1_000 ether);
        vm.prank(ALICE);
        token.approve(SPENDER, type(uint256).max);
        vm.startPrank(SPENDER);
        token.transferFrom(ALICE, BOB, 200 ether);
        token.burnFrom(ALICE, 300 ether);
        vm.stopPrank();
        assertEq(token.allowance(ALICE, SPENDER), type(uint256).max);
        assertEq(token.balanceOf(ALICE), 500 ether);
        assertEq(token.balanceOf(BOB), 200 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 300 ether);
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
        burnAmount = bound(burnAmount, 0, transferAmount);
        token.transfer(ALICE, transferAmount);
        vm.prank(ALICE);
        token.burn(burnAmount);
        assertEq(token.balanceOf(ALICE), transferAmount - burnAmount);
        assertEq(token.balanceOf(address(this)), INITIAL_SUPPLY - transferAmount);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - burnAmount);
        assertEq(token.balanceOf(ALICE) + token.balanceOf(address(this)), token.totalSupply());
    }
}

contract TokenDeployingFactory {
    function deploy() external returns (LaunchToken) {
        return new LaunchToken();
    }
}
