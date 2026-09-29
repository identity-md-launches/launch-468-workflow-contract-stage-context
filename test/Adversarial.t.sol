// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {CityRegistry} from "../src/CityRegistry.sol";
import {GrantExecutor} from "../src/GrantExecutor.sol";

/// @dev Deliberately hostile dependency used to test defensive custody behavior.
contract HostileGrid is ERC20, ERC20Burnable {
    CityRegistry public target;
    bytes private callback;
    uint256 public callbackOn;
    bool public callbackSucceeded;
    bytes4 public callbackError;
    bool public failPayout;
    bool public shortReceipt;

    constructor() ERC20("Hostile", "BAD") {
        _mint(msg.sender, 1e27);
    }

    function configure(CityRegistry target_, bytes calldata callback_, uint256 callbackOn_) external {
        target = target_;
        callback = callback_;
        callbackOn = callbackOn_;
    }

    function setFailure(bool payout, bool receipt) external {
        failPayout = payout;
        shortReceipt = receipt;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failPayout) return false;
        if (callbackOn == 1) _attempt();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (callbackOn == 2) _attempt();
        return super.transferFrom(from, to, shortReceipt ? amount - 1 : amount);
    }

    function burnFrom(address from, uint256 amount) public override {
        if (callbackOn == 3) _attempt();
        super.burnFrom(from, amount);
    }

    function burn(uint256 amount) public override {
        if (callbackOn == 4) _attempt();
        super.burn(amount);
    }

    function _attempt() private {
        bytes memory result;
        (callbackSucceeded, result) = address(target).call(callback);
        if (result.length >= 4) callbackError = bytes4(result);
    }
}

contract WrongDecimalsGrid is ERC20 {
    constructor() ERC20("Six", "SIX") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract AdversarialTest is Test {
    HostileGrid private token;
    CityRegistry private registry;
    GrantExecutor private executor;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    function setUp() public {
        token = new HostileGrid();
        executor = new GrantExecutor(address(this));
        registry = new CityRegistry(address(token), address(executor));
        token.transfer(ALICE, 100_000e18);
        token.approve(address(registry), type(uint256).max);
        vm.prank(ALICE);
        token.approve(address(registry), type(uint256).max);
        vm.prank(ALICE);
        registry.buyCity(0);
    }

    function testRejectedPayoutRestoresClaimAndReserves() public {
        registry.fundRewards(1000e18);
        token.setFailure(true, false);
        uint256 aliceBefore = token.balanceOf(ALICE);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vm.prank(ALICE);
        registry.claimRewards(0);
        assertEq(registry.claimableRewards(0), 1000e18);
        assertEq(registry.rewardsPool(), 1000e18);
        assertEq(token.balanceOf(ALICE), aliceBefore);
        token.setFailure(false, false);
        vm.prank(ALICE);
        registry.claimRewards(0);
        assertEq(token.balanceOf(ALICE), aliceBefore + 1000e18);
        assertEq(registry.rewardsPool(), 0);
    }

    function testReentrantClaimCannotWithdrawTwice() public {
        registry.fundRewards(1000e18);
        token.configure(registry, abi.encodeCall(registry.claimRewards, (0)), 1);
        uint256 beforeBalance = token.balanceOf(ALICE);
        vm.prank(ALICE);
        registry.claimRewards(0);
        _assertGuard();
        assertEq(token.balanceOf(ALICE), beforeBalance + 1000e18);
        assertEq(registry.rewardsPool(), 0);
    }

    function testReentrantFundingCannotCreateUnbackedCredit() public {
        token.configure(registry, abi.encodeCall(registry.fundRewards, (100e18)), 2);
        registry.fundRewards(100e18);
        _assertGuard();
        assertEq(registry.rewardsPool(), 100e18);
        assertEq(registry.claimableRewards(0), 100e18);
        assertEq(token.balanceOf(address(registry)), 100e18);
    }

    function testReentrantBurnCannotAcquireAdditionalCity() public {
        token.configure(registry, abi.encodeCall(registry.buyCity, (99)), 3);
        token.transfer(BOB, 100_000e18);
        vm.startPrank(BOB);
        token.approve(address(registry), type(uint256).max);
        registry.buyCity(1);
        vm.stopPrank();
        _assertGuard();
        assertEq(registry.soldPlots(), 2);
        (address owner,,,,) = registry.cities(99);
        assertEq(owner, address(0));
    }

    function testReentrantTaxBurnCannotRefillPools() public {
        token.configure(registry, abi.encodeCall(registry.fundResources, (100e18)), 4);
        registry.transferWithTax(BOB, 1000e18);
        _assertGuard();
        assertEq(registry.rewardsPool(), 20e18);
        assertEq(registry.resourcePot(), 12e18);
        assertEq(token.balanceOf(address(registry)), 32e18);
    }

    function testShortReceiptCannotCreateUnbackedRewards() public {
        token.setFailure(false, true);
        uint256 beforeBalance = token.balanceOf(address(this));
        vm.expectRevert(CityRegistry.UnexpectedTokenAmount.selector);
        registry.fundRewards(100e18);
        assertEq(registry.rewardsPool(), 0);
        assertEq(token.balanceOf(address(registry)), 0);
        assertEq(token.balanceOf(address(this)), beforeBalance);
    }

    function testShortReceiptCannotCreateResourcesOrTaxRevenue() public {
        token.setFailure(false, true);
        vm.expectRevert(CityRegistry.UnexpectedTokenAmount.selector);
        registry.fundResources(100e18);
        vm.expectRevert(CityRegistry.UnexpectedTokenAmount.selector);
        registry.transferWithTax(BOB, 100e18);
        assertEq(registry.resourcePot(), 0);
        assertEq(registry.rewardsPool(), 0);
        assertEq(token.balanceOf(address(registry)), 0);
    }

    function testTaxPayoutFailureRollsBackAllDebitsAndAllocations() public {
        uint256 beforeBalance = token.balanceOf(address(this));
        uint256 supply = token.totalSupply();
        token.setFailure(true, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        registry.transferWithTax(BOB, 1000e18);
        assertEq(token.balanceOf(address(this)), beforeBalance);
        assertEq(token.totalSupply(), supply);
        assertEq(registry.rewardsPool(), 0);
        assertEq(registry.resourcePot(), 0);
        assertEq(registry.claimableRewards(0), 0);
    }

    function testConstructorRejectsInvalidDependencies() public {
        vm.expectRevert(CityRegistry.InvalidToken.selector);
        new CityRegistry(address(0), address(executor));
        vm.expectRevert(CityRegistry.InvalidToken.selector);
        new CityRegistry(ALICE, address(executor));
        WrongDecimalsGrid wrong = new WrongDecimalsGrid();
        vm.expectRevert(CityRegistry.InvalidToken.selector);
        new CityRegistry(address(wrong), address(executor));
        vm.expectRevert(CityRegistry.InvalidExecutor.selector);
        new CityRegistry(address(token), address(0));
        vm.expectRevert(CityRegistry.InvalidExecutor.selector);
        new CityRegistry(address(token), ALICE);
    }

    function _assertGuard() private view {
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }
}

/// @dev Local CREATE2 harness. Never broadcasts and does not require environment variables.
contract ConstructorFactory {
    function deploy(bytes memory creationCode, bytes32 salt) external returns (address result) {
        assembly ("memory-safe") {
            result := create2(0, add(creationCode, 32), mload(creationCode), salt)
        }
        require(result.code.length != 0, "constructor failed");
    }
}

contract DeploymentTest is Test {
    address private constant OPERATOR = 0x5b95A971B4583A5f011E9DA082acdD679b870D06;

    function testFactoryDeploymentUsesOnlyBackwardReferencesAndPreservesSupply() public {
        ConstructorFactory factory = new ConstructorFactory();
        LaunchToken token = LaunchToken(factory.deploy(type(LaunchToken).creationCode, bytes32(uint256(1))));
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(factory)), 1e27);
        GrantExecutor executor = GrantExecutor(
            factory.deploy(
                abi.encodePacked(type(GrantExecutor).creationCode, abi.encode(OPERATOR)), bytes32(uint256(2))
            )
        );
        assertEq(token.balanceOf(address(factory)), 1e27);
        CityRegistry registry = CityRegistry(
            factory.deploy(
                abi.encodePacked(
                    type(CityRegistry).creationCode, abi.encode(address(token), address(executor))
                ),
                bytes32(uint256(3))
            )
        );
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(factory)), 1e27);
        assertEq(executor.operator(), OPERATOR);
        assertEq(registry.treasury(), OPERATOR);
        assertEq(address(registry.grantExecutor()), address(executor));
        assertEq(address(registry.token()), address(token));
        vm.prank(address(factory));
        vm.expectRevert(GrantExecutor.Unauthorized.selector);
        executor.pause();
        vm.prank(OPERATOR);
        executor.pause();
        assertTrue(executor.paused());
        _checkRuntime(address(token));
        _checkRuntime(address(executor));
        _checkRuntime(address(registry));
    }

    function testConstructorsAreNonpayable() public {
        vm.deal(address(this), 3 ether);
        LaunchToken token = new LaunchToken();
        GrantExecutor executor = new GrantExecutor(OPERATOR);
        bytes memory tokenCode = type(LaunchToken).creationCode;
        bytes memory executorCode = abi.encodePacked(type(GrantExecutor).creationCode, abi.encode(OPERATOR));
        bytes memory registryCode =
            abi.encodePacked(type(CityRegistry).creationCode, abi.encode(address(token), address(executor)));
        assertEq(_createWithValue(tokenCode), address(0));
        assertEq(_createWithValue(executorCode), address(0));
        assertEq(_createWithValue(registryCode), address(0));
    }

    function _createWithValue(bytes memory code) private returns (address result) {
        assembly ("memory-safe") {
            result := create(1000000000000000000, add(code, 32), mload(code))
        }
    }

    function _checkRuntime(address target) private view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
        }
    }
}
