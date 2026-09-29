// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GrantExecutor, ICityGrants} from "../src/GrantExecutor.sol";

contract GrantTargetMock is ICityGrants {
    error ForwardFailure();

    bool public revertCalls;
    uint256 public grantCalls;
    uint256 public heartbeatCalls;
    address public lastCaller;
    uint256 public grantedCity;
    uint256 public grantedAmount;
    uint256[6] public lastHeartbeat;

    function setRevertCalls(bool value) external {
        revertCalls = value;
    }

    function grantResources(uint256 cityId, uint256 amount) external {
        ++grantCalls;
        lastCaller = msg.sender;
        grantedCity = cityId;
        grantedAmount = amount;
        if (revertCalls) revert ForwardFailure();
    }

    function recordHeartbeat(
        uint256 cityId1,
        uint256 amount1,
        uint256 cityId2,
        uint256 amount2,
        uint256 cityId3,
        uint256 amount3
    ) external {
        ++heartbeatCalls;
        lastCaller = msg.sender;
        lastHeartbeat = [cityId1, amount1, cityId2, amount2, cityId3, amount3];
        if (revertCalls) revert ForwardFailure();
    }
}

contract GrantExecutorTest is Test {
    address private constant OPERATOR = address(0xA11CE);
    address private constant STRANGER = address(0xB0B);
    GrantExecutor private executor;
    GrantTargetMock private registry;

    function setUp() public {
        executor = new GrantExecutor(OPERATOR);
        registry = new GrantTargetMock();
    }

    function testConstructorConfiguresOperatorWithoutTrustingDeployer() public view {
        assertEq(executor.operator(), OPERATOR);
        assertFalse(executor.paused());
    }

    function testConstructorRejectsZeroOperator() public {
        vm.expectRevert(GrantExecutor.InvalidOperator.selector);
        new GrantExecutor(address(0));
    }

    function testFuzzGrantForwardsExactArguments(uint256 cityId, uint256 amount) public {
        vm.prank(OPERATOR);
        executor.grantResources(address(registry), cityId, amount);

        assertEq(registry.grantCalls(), 1);
        assertEq(registry.grantedCity(), cityId);
        assertEq(registry.grantedAmount(), amount);
        assertEq(registry.lastCaller(), address(executor));
    }

    function testHeartbeatForwardsAllWinnersAndAmounts() public {
        vm.prank(OPERATOR);
        executor.recordHeartbeat(address(registry), 1, 100, 17, 200, 255, 300);

        assertEq(registry.heartbeatCalls(), 1);
        assertEq(registry.lastCaller(), address(executor));
        assertEq(registry.lastHeartbeat(0), 1);
        assertEq(registry.lastHeartbeat(1), 100);
        assertEq(registry.lastHeartbeat(2), 17);
        assertEq(registry.lastHeartbeat(3), 200);
        assertEq(registry.lastHeartbeat(4), 255);
        assertEq(registry.lastHeartbeat(5), 300);
    }

    function testEveryOperationRejectsUnauthorizedCaller() public {
        vm.startPrank(STRANGER);
        vm.expectRevert(GrantExecutor.Unauthorized.selector);
        executor.grantResources(address(registry), 1, 100);
        vm.expectRevert(GrantExecutor.Unauthorized.selector);
        executor.recordHeartbeat(address(registry), 1, 100, 2, 200, 3, 300);
        vm.expectRevert(GrantExecutor.Unauthorized.selector);
        executor.pause();
        vm.expectRevert(GrantExecutor.Unauthorized.selector);
        executor.unpause();
        vm.stopPrank();
        assertEq(registry.grantCalls(), 0);
        assertEq(registry.heartbeatCalls(), 0);

        // Deployment by the test contract confers no authority.
        vm.expectRevert(GrantExecutor.Unauthorized.selector);
        executor.pause();
    }

    function testPauseBlocksBothGrantPathsAndUnpauseRestoresThem() public {
        vm.startPrank(OPERATOR);
        executor.pause();
        assertTrue(executor.paused());
        vm.expectRevert(GrantExecutor.GrantsPaused.selector);
        executor.grantResources(address(registry), 1, 100);
        vm.expectRevert(GrantExecutor.GrantsPaused.selector);
        executor.recordHeartbeat(address(registry), 1, 100, 2, 200, 3, 300);

        executor.unpause();
        assertFalse(executor.paused());
        executor.grantResources(address(registry), 1, 100);
        executor.recordHeartbeat(address(registry), 1, 100, 2, 200, 3, 300);
        vm.stopPrank();
        assertEq(registry.grantCalls(), 1);
        assertEq(registry.heartbeatCalls(), 1);
    }

    function testRepeatedPauseTransitionsRevert() public {
        vm.startPrank(OPERATOR);
        vm.expectRevert(GrantExecutor.NotPaused.selector);
        executor.unpause();
        executor.pause();
        vm.expectRevert(GrantExecutor.AlreadyPaused.selector);
        executor.pause();
        executor.unpause();
        vm.expectRevert(GrantExecutor.NotPaused.selector);
        executor.unpause();
        vm.stopPrank();
    }

    function testRejectsTargetsWithoutCode() public {
        vm.startPrank(OPERATOR);
        vm.expectRevert(GrantExecutor.InvalidRegistry.selector);
        executor.grantResources(address(0), 1, 100);
        vm.expectRevert(GrantExecutor.InvalidRegistry.selector);
        executor.grantResources(STRANGER, 1, 100);
        vm.expectRevert(GrantExecutor.InvalidRegistry.selector);
        executor.recordHeartbeat(STRANGER, 1, 100, 2, 200, 3, 300);
        vm.stopPrank();
    }

    function testTargetGrantFailureBubblesAndRollsBackWrites() public {
        registry.setRevertCalls(true);
        vm.prank(OPERATOR);
        vm.expectRevert(GrantTargetMock.ForwardFailure.selector);
        executor.grantResources(address(registry), 1, 100);
        assertEq(registry.grantCalls(), 0);
        assertEq(registry.grantedAmount(), 0);
        assertEq(registry.lastCaller(), address(0));
    }

    function testTargetHeartbeatFailureBubblesAndRollsBackWrites() public {
        registry.setRevertCalls(true);
        vm.prank(OPERATOR);
        vm.expectRevert(GrantTargetMock.ForwardFailure.selector);
        executor.recordHeartbeat(address(registry), 1, 100, 2, 200, 3, 300);
        assertEq(registry.heartbeatCalls(), 0);
        for (uint256 i; i < 6; ++i) {
            assertEq(registry.lastHeartbeat(i), 0);
        }
    }

    function testOneExecutorCanTargetRegistriesDeployedAfterIt() public {
        GrantTargetMock secondRegistry = new GrantTargetMock();
        vm.startPrank(OPERATOR);
        executor.grantResources(address(registry), 1, 100);
        executor.grantResources(address(secondRegistry), 2, 200);
        vm.stopPrank();
        assertEq(registry.grantedCity(), 1);
        assertEq(secondRegistry.grantedCity(), 2);
    }
}
