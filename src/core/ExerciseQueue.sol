// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { AccessManaged } from "../utils/AccessManaged.sol";
import { CalderaTypes } from "../types/CalderaTypes.sol";
import { CalderaErrors } from "../errors/CalderaErrors.sol";
import { FixedPointMath } from "../libraries/FixedPointMath.sol";

/// @title ExerciseQueue
/// @notice Delayed processing queue for option exercise requests.
contract ExerciseQueue is AccessManaged {
    uint256 public constant MAX_BATCH_SIZE = 128;

    uint256 public nextRequestId = 1;
    uint256 public totalPendingCount;
    uint256 public totalPendingPayout;

    mapping(uint256 requestId => CalderaTypes.ExerciseRequest request) private _requests;
    mapping(uint64 seriesId => uint256[] requestIds) private _requestIdsBySeries;

    mapping(uint64 seriesId => uint256 count) public pendingCountBySeries;
    mapping(uint64 seriesId => uint256 payout) public pendingPayoutBySeries;

    event ExerciseEnqueued(
        uint256 indexed requestId,
        uint64 indexed seriesId,
        address indexed requester,
        address recipient,
        uint128 contracts,
        uint192 exercisePriceX18,
        uint256 payout,
        uint64 executableAt
    );
    event ExerciseProcessingStarted(
        uint256 indexed requestId, uint64 indexed seriesId, address indexed processor
    );
    event ExerciseCompleted(
        uint256 indexed requestId,
        uint64 indexed seriesId,
        address indexed recipient,
        uint256 payout,
        uint64 processedAt
    );

    constructor(address accessController_) AccessManaged(accessController_) { }

    /// @notice Adds a priced exercise request to the delayed queue.
    function enqueue(
        uint64 seriesId,
        uint128 contracts,
        address requester,
        address recipient,
        uint192 exercisePriceX18,
        uint256 payout,
        uint32 executableDelay
    ) external onlyProtocol whenNotPaused returns (uint256 requestId) {
        if (seriesId == 0) revert CalderaErrors.SeriesNotFound(seriesId);
        if (contracts == 0 || payout == 0) revert CalderaErrors.ZeroAmount();
        if (requester == address(0)) revert CalderaErrors.ZeroAddress();
        if (recipient == address(0)) revert CalderaErrors.InvalidRecipient(recipient);
        if (exercisePriceX18 == 0) {
            revert CalderaErrors.InvalidOraclePrice(bytes32(0), exercisePriceX18);
        }
        if (executableDelay == 0) {
            revert CalderaErrors.InvalidSettlementDelay(executableDelay);
        }
        if (block.timestamp > type(uint64).max - executableDelay) {
            revert CalderaErrors.AccountingOverflow();
        }

        requestId = nextRequestId;
        if (requestId == type(uint256).max) revert CalderaErrors.AccountingOverflow();
        unchecked {
            nextRequestId = requestId + 1;
        }

        uint64 requestedAt = uint64(block.timestamp);
        uint64 executableAt = requestedAt + executableDelay;
        _requests[requestId] = CalderaTypes.ExerciseRequest({
            seriesId: seriesId,
            contracts: contracts,
            requester: requester,
            recipient: recipient,
            requestedAt: requestedAt,
            executableAt: executableAt,
            exercisePriceX18: exercisePriceX18,
            payout: payout,
            status: CalderaTypes.RequestStatus.Pending,
            processedAt: 0
        });
        _requestIdsBySeries[seriesId].push(requestId);

        pendingCountBySeries[seriesId] = _add(pendingCountBySeries[seriesId], 1);
        pendingPayoutBySeries[seriesId] = _add(pendingPayoutBySeries[seriesId], payout);
        totalPendingCount = _add(totalPendingCount, 1);
        totalPendingPayout = _add(totalPendingPayout, payout);

        emit ExerciseEnqueued(
            requestId,
            seriesId,
            requester,
            recipient,
            contracts,
            exercisePriceX18,
            payout,
            executableAt
        );
    }

    /// @notice Moves an executable request into processing.
    function start(uint256 requestId)
        external
        onlyProtocol
        whenNotPaused
        returns (CalderaTypes.ExerciseRequest memory request)
    {
        CalderaTypes.ExerciseRequest storage stored = _requireRequest(requestId);
        if (stored.status != CalderaTypes.RequestStatus.Pending) {
            revert CalderaErrors.RequestNotPending(requestId);
        }
        if (block.timestamp < stored.executableAt) {
            revert CalderaErrors.RequestNotExecutable(requestId, stored.executableAt);
        }

        stored.status = CalderaTypes.RequestStatus.Processing;
        request = stored;

        emit ExerciseProcessingStarted(requestId, stored.seriesId, msg.sender);
    }

    /// @notice Marks a processing request as completed and clears its pending totals.
    function complete(uint256 requestId)
        external
        onlyProtocol
        whenNotPaused
        returns (CalderaTypes.ExerciseRequest memory request)
    {
        CalderaTypes.ExerciseRequest storage stored = _requireRequest(requestId);
        if (stored.status != CalderaTypes.RequestStatus.Processing) {
            revert CalderaErrors.RequestNotProcessing(requestId);
        }
        if (block.timestamp > type(uint64).max) revert CalderaErrors.AccountingOverflow();

        stored.status = CalderaTypes.RequestStatus.Processed;
        stored.processedAt = uint64(block.timestamp);

        pendingCountBySeries[stored.seriesId] -= 1;
        pendingPayoutBySeries[stored.seriesId] -= stored.payout;
        totalPendingCount -= 1;
        totalPendingPayout -= stored.payout;
        request = stored;

        emit ExerciseCompleted(
            requestId, stored.seriesId, stored.recipient, stored.payout, stored.processedAt
        );
    }

    function getRequest(uint256 requestId)
        public
        view
        returns (CalderaTypes.ExerciseRequest memory)
    {
        CalderaTypes.ExerciseRequest storage request = _requireRequest(requestId);
        return request;
    }

    function getRequests(uint256[] calldata requestIds)
        external
        view
        returns (CalderaTypes.ExerciseRequest[] memory requests)
    {
        uint256 length = requestIds.length;
        if (length > MAX_BATCH_SIZE) {
            revert CalderaErrors.BatchTooLarge(length, MAX_BATCH_SIZE);
        }

        requests = new CalderaTypes.ExerciseRequest[](length);
        for (uint256 i; i < length; ++i) {
            requests[i] = getRequest(requestIds[i]);
        }
    }

    function isExecutable(uint256 requestId) external view returns (bool) {
        CalderaTypes.ExerciseRequest storage request = _requests[requestId];
        return request.status == CalderaTypes.RequestStatus.Pending
            && block.timestamp >= request.executableAt;
    }

    function requestCount() external view returns (uint256) {
        return nextRequestId - 1;
    }

    function requestCountBySeries(uint64 seriesId) external view returns (uint256) {
        return _requestIdsBySeries[seriesId].length;
    }

    function pendingStats(uint64 seriesId) external view returns (uint256 count, uint256 payout) {
        count = pendingCountBySeries[seriesId];
        payout = pendingPayoutBySeries[seriesId];
    }

    function requestIdsBySeries(uint64 seriesId, uint256 cursor, uint256 size)
        external
        view
        returns (uint256[] memory requestIds, uint256 nextCursor)
    {
        uint256[] storage storedIds = _requestIdsBySeries[seriesId];
        uint256 length = storedIds.length;
        if (cursor >= length || size == 0) return (new uint256[](0), cursor);

        uint256 resultLength = FixedPointMath.min(size, length - cursor);
        if (resultLength > MAX_BATCH_SIZE) {
            revert CalderaErrors.BatchTooLarge(resultLength, MAX_BATCH_SIZE);
        }

        requestIds = new uint256[](resultLength);
        for (uint256 i; i < resultLength; ++i) {
            requestIds[i] = storedIds[cursor + i];
        }
        nextCursor = cursor + resultLength;
    }

    function requestPageBySeries(uint64 seriesId, uint256 cursor, uint256 size)
        external
        view
        returns (CalderaTypes.ExerciseRequest[] memory requests, uint256 nextCursor)
    {
        uint256[] storage storedIds = _requestIdsBySeries[seriesId];
        uint256 length = storedIds.length;
        if (cursor >= length || size == 0) {
            return (new CalderaTypes.ExerciseRequest[](0), cursor);
        }

        uint256 resultLength = FixedPointMath.min(size, length - cursor);
        if (resultLength > MAX_BATCH_SIZE) {
            revert CalderaErrors.BatchTooLarge(resultLength, MAX_BATCH_SIZE);
        }

        requests = new CalderaTypes.ExerciseRequest[](resultLength);
        for (uint256 i; i < resultLength; ++i) {
            requests[i] = _requests[storedIds[cursor + i]];
        }
        nextCursor = cursor + resultLength;
    }

    function _requireRequest(uint256 requestId)
        private
        view
        returns (CalderaTypes.ExerciseRequest storage request)
    {
        request = _requests[requestId];
        if (request.status == CalderaTypes.RequestStatus.None) {
            revert CalderaErrors.RequestNotFound(requestId);
        }
    }

    function _add(uint256 a, uint256 b) private pure returns (uint256 result) {
        unchecked {
            result = a + b;
        }
        if (result < a) revert CalderaErrors.AccountingOverflow();
    }
}
