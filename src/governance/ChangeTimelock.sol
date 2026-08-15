// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { CalderaAccessController } from "../access/CalderaAccessController.sol";
import { CalderaErrors } from "../errors/CalderaErrors.sol";
import { ReentrancyGuard } from "../utils/ReentrancyGuard.sol";

/// @title ChangeTimelock
/// @notice Quorum, delay, expiry, and predecessor enforcement for sensitive protocol calls.
contract ChangeTimelock is ReentrancyGuard {
    enum OperationState {
        None,
        Waiting,
        Ready,
        Executed,
        Cancelled,
        Expired
    }

    struct Operation {
        address target;
        uint256 value;
        bytes32 callDigest;
        bytes32 predecessor;
        uint64 scheduledAt;
        uint64 readyAt;
        uint64 expiresAt;
        bool executed;
        bool cancelled;
    }

    CalderaAccessController public immutable accessController;
    uint64 public immutable minimumDelay;
    uint64 public immutable maximumDelay;
    uint64 public immutable gracePeriod;
    uint16 public immutable approvalQuorum;

    mapping(bytes32 operationId => Operation operation) private _operations;
    mapping(bytes32 operationId => mapping(address approver => bool approved)) public approvedBy;
    mapping(bytes32 operationId => address[] approvers) private _approvers;

    event OperationScheduled(
        bytes32 indexed operationId,
        address indexed proposer,
        address indexed target,
        uint256 value,
        bytes32 callDigest,
        bytes32 predecessor,
        uint64 readyAt,
        uint64 expiresAt
    );
    event OperationApproved(bytes32 indexed operationId, address indexed approver);
    event OperationCancelled(bytes32 indexed operationId, address indexed canceller);
    event OperationExecuted(
        bytes32 indexed operationId, address indexed executor, bytes32 returnDataDigest
    );

    error InvalidTimelockConfiguration();
    error InvalidOperationWindow(uint64 delay);
    error OperationAlreadyKnown(bytes32 operationId);
    error OperationNotFound(bytes32 operationId);
    error OperationFinal(bytes32 operationId);
    error OperationNotReady(bytes32 operationId, uint64 readyAt);
    error OperationExpired(bytes32 operationId, uint64 expiresAt);
    error ApprovalAlreadyRecorded(bytes32 operationId, address approver);
    error ApprovalQuorumNotMet(bytes32 operationId, uint256 approvals, uint256 required);
    error PredecessorNotExecuted(bytes32 operationId, bytes32 predecessor);
    error CallExecutionFailed(bytes32 operationId, bytes returnData);

    constructor(
        address accessController_,
        uint64 minimumDelay_,
        uint64 maximumDelay_,
        uint64 gracePeriod_,
        uint16 approvalQuorum_
    ) {
        if (
            accessController_ == address(0) || minimumDelay_ == 0 || maximumDelay_ < minimumDelay_
                || gracePeriod_ == 0 || approvalQuorum_ == 0
        ) revert InvalidTimelockConfiguration();
        accessController = CalderaAccessController(accessController_);
        minimumDelay = minimumDelay_;
        maximumDelay = maximumDelay_;
        gracePeriod = gracePeriod_;
        approvalQuorum = approvalQuorum_;
    }

    receive() external payable { }

    function hashOperation(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint64 readyAt,
        uint64 expiresAt
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("CALDERA_CHANGE_TIMELOCK_V1"),
                block.chainid,
                address(this),
                target,
                value,
                keccak256(data),
                predecessor,
                salt,
                readyAt,
                expiresAt
            )
        );
    }

    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint64 delay
    ) external returns (bytes32 operationId) {
        _requireRole(accessController.GOVERNOR_ROLE(), msg.sender);
        if (target == address(0)) revert CalderaErrors.ZeroAddress();
        if (delay < minimumDelay || delay > maximumDelay) revert InvalidOperationWindow(delay);
        if (block.timestamp > type(uint64).max - delay - gracePeriod) {
            revert CalderaErrors.AccountingOverflow();
        }
        uint64 scheduledAt = uint64(block.timestamp);
        uint64 readyAt = scheduledAt + delay;
        uint64 expiresAt = readyAt + gracePeriod;
        operationId = hashOperation(target, value, data, predecessor, salt, readyAt, expiresAt);
        if (_operations[operationId].target != address(0)) {
            revert OperationAlreadyKnown(operationId);
        }
        _operations[operationId] = Operation({
            target: target,
            value: value,
            callDigest: keccak256(data),
            predecessor: predecessor,
            scheduledAt: scheduledAt,
            readyAt: readyAt,
            expiresAt: expiresAt,
            executed: false,
            cancelled: false
        });
        emit OperationScheduled(
            operationId, msg.sender, target, value, keccak256(data), predecessor, readyAt, expiresAt
        );
    }

    function approve(bytes32 operationId) external {
        _requireRole(accessController.GOVERNOR_ROLE(), msg.sender);
        Operation storage current = _requirePending(operationId);
        if (block.timestamp > current.expiresAt) {
            revert OperationExpired(operationId, current.expiresAt);
        }
        if (approvedBy[operationId][msg.sender]) {
            revert ApprovalAlreadyRecorded(operationId, msg.sender);
        }
        approvedBy[operationId][msg.sender] = true;
        _approvers[operationId].push(msg.sender);
        emit OperationApproved(operationId, msg.sender);
    }

    function cancel(bytes32 operationId) external {
        bool guardian = accessController.hasRole(accessController.GUARDIAN_ROLE(), msg.sender);
        bool governor = accessController.hasRole(accessController.GOVERNOR_ROLE(), msg.sender);
        if (!guardian && !governor) {
            revert CalderaErrors.Unauthorized(accessController.GUARDIAN_ROLE(), msg.sender);
        }
        Operation storage current = _requirePending(operationId);
        current.cancelled = true;
        emit OperationCancelled(operationId, msg.sender);
    }

    function execute(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint64 readyAt,
        uint64 expiresAt
    ) external nonReentrant returns (bytes memory returnData) {
        _requireRole(accessController.GOVERNOR_ROLE(), msg.sender);
        bytes32 operationId =
            hashOperation(target, value, data, predecessor, salt, readyAt, expiresAt);
        Operation storage current = _requirePending(operationId);
        if (
            current.target != target || current.value != value
                || current.callDigest != keccak256(data) || current.predecessor != predecessor
                || current.readyAt != readyAt || current.expiresAt != expiresAt
        ) revert OperationNotFound(operationId);
        if (block.timestamp < readyAt) revert OperationNotReady(operationId, readyAt);
        if (block.timestamp > expiresAt) revert OperationExpired(operationId, expiresAt);

        uint256 approvals = activeApprovalCount(operationId);
        if (approvals < approvalQuorum) {
            revert ApprovalQuorumNotMet(operationId, approvals, approvalQuorum);
        }
        if (predecessor != bytes32(0) && !_operations[predecessor].executed) {
            revert PredecessorNotExecuted(operationId, predecessor);
        }

        current.executed = true;
        (bool success, bytes memory result) = target.call{ value: value }(data);
        if (!success) revert CallExecutionFailed(operationId, result);
        emit OperationExecuted(operationId, msg.sender, keccak256(result));
        return result;
    }

    function operationOf(bytes32 operationId) external view returns (Operation memory) {
        Operation memory result = _operations[operationId];
        if (result.target == address(0)) revert OperationNotFound(operationId);
        return result;
    }

    function state(bytes32 operationId) public view returns (OperationState) {
        Operation memory current = _operations[operationId];
        if (current.target == address(0)) return OperationState.None;
        if (current.executed) return OperationState.Executed;
        if (current.cancelled) return OperationState.Cancelled;
        if (block.timestamp > current.expiresAt) return OperationState.Expired;
        if (
            block.timestamp >= current.readyAt && activeApprovalCount(operationId) >= approvalQuorum
        ) {
            return OperationState.Ready;
        }
        return OperationState.Waiting;
    }

    function activeApprovalCount(bytes32 operationId) public view returns (uint256 count) {
        address[] storage voters = _approvers[operationId];
        bytes32 role = accessController.GOVERNOR_ROLE();
        for (uint256 i; i < voters.length; ++i) {
            if (accessController.hasRole(role, voters[i])) ++count;
        }
    }

    function approversOf(bytes32 operationId) external view returns (address[] memory) {
        return _approvers[operationId];
    }

    function _requirePending(bytes32 operationId) private view returns (Operation storage current) {
        current = _operations[operationId];
        if (current.target == address(0)) revert OperationNotFound(operationId);
        if (current.executed || current.cancelled) revert OperationFinal(operationId);
    }

    function _requireRole(bytes32 role, address account) private view {
        if (!accessController.hasRole(role, account)) {
            revert CalderaErrors.Unauthorized(role, account);
        }
    }
}
