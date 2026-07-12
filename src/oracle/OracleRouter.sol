// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { AccessManaged } from "../utils/AccessManaged.sol";
import { CalderaTypes } from "../types/CalderaTypes.sol";
import { CalderaErrors } from "../errors/CalderaErrors.sol";

/// @title OracleRouter
/// @notice Stores sequenced settlement prices submitted by authorized oracle operators.
/// @dev Consumers select a maximum acceptable age on every read so each option series can use its
///      own freshness policy. Sequences prevent replay even when timestamps are equal.
contract OracleRouter is AccessManaged {
    uint256 public constant MAX_BATCH_SIZE = 64;

    struct PriceUpdate {
        bytes32 feedId;
        uint192 priceX18;
        uint64 updatedAt;
        uint32 sequence;
    }

    mapping(bytes32 feedId => CalderaTypes.OracleFeed feed) private _feeds;
    mapping(bytes32 feedId => bool configured) private _configured;
    bytes32[] private _configuredFeedIds;

    event FeedConfigured(bytes32 indexed feedId, bool enabled);
    event FeedEnabled(bytes32 indexed feedId, bool enabled);
    event PriceSubmitted(
        bytes32 indexed feedId,
        uint192 priceX18,
        uint64 updatedAt,
        uint32 indexed sequence,
        address indexed submitter
    );

    constructor(address accessController_) AccessManaged(accessController_) { }

    /// @notice Creates a feed entry without publishing an initial value.
    function configureFeed(bytes32 feedId, bool enabled)
        external
        onlyRole(accessController.GOVERNOR_ROLE())
    {
        _configureFeed(feedId, enabled);
    }

    /// @notice Enables or disables reads and new submissions for a configured feed.
    function setFeedEnabled(bytes32 feedId, bool enabled)
        external
        onlyRole(accessController.GOVERNOR_ROLE())
    {
        _requireConfigured(feedId);

        CalderaTypes.OracleFeed storage feed = _feeds[feedId];
        if (feed.enabled == enabled) return;
        feed.enabled = enabled;

        emit FeedEnabled(feedId, enabled);
    }

    /// @notice Publishes a new strictly sequenced price observation.
    function submitPrice(bytes32 feedId, uint192 priceX18, uint64 updatedAt, uint32 sequence)
        external
        onlyRole(accessController.ORACLE_MANAGER_ROLE())
        whenNotPaused
    {
        _submitPrice(feedId, priceX18, updatedAt, sequence);
    }

    /// @notice Publishes several price observations atomically.
    function submitPrices(PriceUpdate[] calldata updates)
        external
        onlyRole(accessController.ORACLE_MANAGER_ROLE())
        whenNotPaused
    {
        uint256 length = updates.length;
        if (length == 0) revert CalderaErrors.ZeroAmount();
        if (length > MAX_BATCH_SIZE) revert CalderaErrors.BatchTooLarge(length, MAX_BATCH_SIZE);

        for (uint256 i; i < length;) {
            PriceUpdate calldata update = updates[i];
            _submitPrice(update.feedId, update.priceX18, update.updatedAt, update.sequence);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Reads a valid price subject to the caller-selected freshness bound.
    function getPrice(bytes32 feedId, uint32 maxAge) public view returns (uint256 priceX18) {
        CalderaTypes.OracleFeed memory feed = _validatedFeed(feedId, maxAge);
        return uint256(feed.priceX18);
    }

    /// @notice Reads a complete valid observation subject to a freshness bound.
    function readPrice(bytes32 feedId, uint32 maxAge)
        external
        view
        returns (uint256 priceX18, uint64 updatedAt, uint32 sequence)
    {
        CalderaTypes.OracleFeed memory feed = _validatedFeed(feedId, maxAge);
        return (uint256(feed.priceX18), feed.updatedAt, feed.sequence);
    }

    /// @notice Returns the latest stored observation without applying a freshness bound.
    /// @dev The feed must be configured, but it may be disabled. Intended for monitoring tools.
    function getFeed(bytes32 feedId) public view returns (CalderaTypes.OracleFeed memory) {
        _requireConfigured(feedId);
        return _feeds[feedId];
    }

    function isFeedConfigured(bytes32 feedId) external view returns (bool) {
        return _configured[feedId];
    }

    function configuredFeedCount() external view returns (uint256) {
        return _configuredFeedIds.length;
    }

    function configuredFeedAt(uint256 index) external view returns (bytes32) {
        return _configuredFeedIds[index];
    }

    function _configureFeed(bytes32 feedId, bool enabled) internal {
        if (feedId == bytes32(0)) revert CalderaErrors.InvalidConfiguration();
        if (_configured[feedId]) revert CalderaErrors.InvalidConfiguration();

        _configured[feedId] = true;
        _feeds[feedId].enabled = enabled;
        _configuredFeedIds.push(feedId);

        emit FeedConfigured(feedId, enabled);
    }

    function _submitPrice(bytes32 feedId, uint192 priceX18, uint64 updatedAt, uint32 sequence)
        internal
    {
        _requireConfigured(feedId);
        CalderaTypes.OracleFeed storage feed = _feeds[feedId];
        if (!feed.enabled) revert CalderaErrors.FeedDisabled(feedId);
        if (priceX18 == 0) revert CalderaErrors.InvalidOraclePrice(feedId, priceX18);
        if (updatedAt == 0) revert CalderaErrors.InvalidConfiguration();
        if (uint256(updatedAt) > block.timestamp) {
            revert CalderaErrors.OracleTimestampInFuture(feedId, updatedAt);
        }
        if (sequence <= feed.sequence) {
            revert CalderaErrors.OracleSequenceNotIncreasing(feedId, feed.sequence, sequence);
        }
        // A newer sequence cannot rewrite history with an older observation timestamp.
        if (updatedAt < feed.updatedAt) revert CalderaErrors.InvalidConfiguration();

        feed.priceX18 = priceX18;
        feed.updatedAt = updatedAt;
        feed.sequence = sequence;

        emit PriceSubmitted(feedId, priceX18, updatedAt, sequence, msg.sender);
    }

    function _validatedFeed(bytes32 feedId, uint32 maxAge)
        internal
        view
        returns (CalderaTypes.OracleFeed memory feed)
    {
        if (maxAge == 0) revert CalderaErrors.InvalidOracleAge(maxAge);
        _requireConfigured(feedId);

        feed = _feeds[feedId];
        if (!feed.enabled) revert CalderaErrors.FeedDisabled(feedId);
        if (feed.priceX18 == 0 || feed.updatedAt == 0) {
            revert CalderaErrors.InvalidOraclePrice(feedId, feed.priceX18);
        }

        if (block.timestamp > uint256(feed.updatedAt) + uint256(maxAge)) {
            revert CalderaErrors.StaleOraclePrice(feedId, feed.updatedAt, maxAge);
        }
    }

    function _requireConfigured(bytes32 feedId) internal view {
        if (!_configured[feedId]) revert CalderaErrors.FeedNotConfigured(feedId);
    }
}
