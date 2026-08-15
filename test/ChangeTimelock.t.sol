// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { CalderaAccessController } from "../src/access/CalderaAccessController.sol";
import { ChangeTimelock } from "../src/governance/ChangeTimelock.sol";

contract TimelockTarget {
    uint256 public value;

    function setValue(uint256 next) external returns (uint256) {
        value = next;
        return next;
    }
}

contract ChangeTimelockTest is Test {
    CalderaAccessController private accessController;
    ChangeTimelock private timelock;
    TimelockTarget private target;
    address private governorTwo = makeAddr("governorTwo");

    uint64 private constant MINIMUM_DELAY = 2 days;
    uint64 private constant MAXIMUM_DELAY = 30 days;
    uint64 private constant GRACE_PERIOD = 7 days;

    function setUp() public {
        vm.warp(1_800_000_000);
        accessController = new CalderaAccessController(address(this));
        accessController.grantRole(accessController.GOVERNOR_ROLE(), governorTwo);
        timelock = new ChangeTimelock(
            address(accessController), MINIMUM_DELAY, MAXIMUM_DELAY, GRACE_PERIOD, 2
        );
        target = new TimelockTarget();
    }

    function testExecutesOnlyAfterCurrentGovernorQuorumAndDelay() public {
        bytes memory data = abi.encodeCall(TimelockTarget.setValue, (42));
        (bytes32 operationId, ChangeTimelock.Operation memory operation) =
            _schedule(data, bytes32(0), keccak256("set-42"));

        timelock.approve(operationId);
        vm.prank(governorTwo);
        timelock.approve(operationId);
        assertEq(timelock.activeApprovalCount(operationId), 2);
        assertEq(uint8(timelock.state(operationId)), uint8(ChangeTimelock.OperationState.Waiting));

        vm.warp(operation.readyAt);
        assertEq(uint8(timelock.state(operationId)), uint8(ChangeTimelock.OperationState.Ready));
        bytes memory result = timelock.execute(
            address(target),
            0,
            data,
            bytes32(0),
            keccak256("set-42"),
            operation.readyAt,
            operation.expiresAt
        );

        assertEq(abi.decode(result, (uint256)), 42);
        assertEq(target.value(), 42);
        assertEq(uint8(timelock.state(operationId)), uint8(ChangeTimelock.OperationState.Executed));
    }

    function testRevokedGovernorNoLongerCountsTowardExecution() public {
        bytes memory data = abi.encodeCall(TimelockTarget.setValue, (7));
        (bytes32 operationId, ChangeTimelock.Operation memory operation) =
            _schedule(data, bytes32(0), keccak256("set-7"));
        timelock.approve(operationId);
        vm.prank(governorTwo);
        timelock.approve(operationId);

        accessController.revokeRole(accessController.GOVERNOR_ROLE(), governorTwo);
        assertEq(timelock.activeApprovalCount(operationId), 1);
        vm.warp(operation.readyAt);
        vm.expectRevert(
            abi.encodeWithSelector(ChangeTimelock.ApprovalQuorumNotMet.selector, operationId, 1, 2)
        );
        timelock.execute(
            address(target),
            0,
            data,
            bytes32(0),
            keccak256("set-7"),
            operation.readyAt,
            operation.expiresAt
        );
    }

    function testGuardianCancellationIsFinal() public {
        bytes memory data = abi.encodeCall(TimelockTarget.setValue, (9));
        (bytes32 operationId,) = _schedule(data, bytes32(0), keccak256("set-9"));

        timelock.cancel(operationId);
        assertEq(uint8(timelock.state(operationId)), uint8(ChangeTimelock.OperationState.Cancelled));
        vm.expectRevert(abi.encodeWithSelector(ChangeTimelock.OperationFinal.selector, operationId));
        timelock.approve(operationId);
    }

    function testPredecessorMustExecuteBeforeDependentOperation() public {
        bytes memory firstData = abi.encodeCall(TimelockTarget.setValue, (1));
        bytes memory secondData = abi.encodeCall(TimelockTarget.setValue, (2));
        (bytes32 firstId, ChangeTimelock.Operation memory first) =
            _schedule(firstData, bytes32(0), keccak256("first"));
        (bytes32 secondId, ChangeTimelock.Operation memory second) =
            _schedule(secondData, firstId, keccak256("second"));
        _approveWithQuorum(firstId);
        _approveWithQuorum(secondId);
        vm.warp(second.readyAt);

        vm.expectRevert(
            abi.encodeWithSelector(
                ChangeTimelock.PredecessorNotExecuted.selector, secondId, firstId
            )
        );
        timelock.execute(
            address(target),
            0,
            secondData,
            firstId,
            keccak256("second"),
            second.readyAt,
            second.expiresAt
        );

        timelock.execute(
            address(target),
            0,
            firstData,
            bytes32(0),
            keccak256("first"),
            first.readyAt,
            first.expiresAt
        );
        timelock.execute(
            address(target),
            0,
            secondData,
            firstId,
            keccak256("second"),
            second.readyAt,
            second.expiresAt
        );
        assertEq(target.value(), 2);
    }

    function _schedule(bytes memory data, bytes32 predecessor, bytes32 salt)
        private
        returns (bytes32 operationId, ChangeTimelock.Operation memory operation)
    {
        operationId = timelock.schedule(address(target), 0, data, predecessor, salt, MINIMUM_DELAY);
        operation = timelock.operationOf(operationId);
    }

    function _approveWithQuorum(bytes32 operationId) private {
        timelock.approve(operationId);
        vm.prank(governorTwo);
        timelock.approve(operationId);
    }
}
