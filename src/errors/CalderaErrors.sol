// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library CalderaErrors {
    error Unauthorized(bytes32 role, address account);
    error ZeroAddress();
    error ZeroAmount();
    error InvalidRecipient(address recipient);
    error InvalidConfiguration();
    error AlreadyInitialized();
    error ProtocolNotBound();
    error ProtocolPaused();
    error ProtocolNotPaused();
    error Reentrancy();

    error AssetNotConfigured(address asset);
    error AssetDisabled(address asset);
    error AssetAlreadyConfigured(address asset);
    error UnsupportedDecimals(uint8 decimals);
    error DepositCapExceeded(address asset, uint256 requested, uint256 cap);
    error UnsupportedTokenBehavior(address asset);
    error TransferFailed(address token, address from, address to, uint256 amount);
    error InsufficientPhysicalBalance(address asset, uint256 available, uint256 required);

    error FeedNotConfigured(bytes32 feedId);
    error FeedDisabled(bytes32 feedId);
    error InvalidOraclePrice(bytes32 feedId, uint256 price);
    error OracleTimestampInFuture(bytes32 feedId, uint256 timestamp);
    error StaleOraclePrice(bytes32 feedId, uint256 updatedAt, uint256 maxAge);
    error OracleSequenceNotIncreasing(bytes32 feedId, uint32 current, uint32 next);

    error SeriesNotFound(uint64 seriesId);
    error InvalidSeriesWindow();
    error InvalidStrike(uint256 strike);
    error InvalidCap(uint256 strike, uint256 cap);
    error InvalidContractSize(uint256 contractSize);
    error InvalidSettlementDelay(uint256 delay);
    error InvalidOracleAge(uint256 maxAge);
    error InvalidFee(uint256 feeBps);
    error InvalidSeriesPhase(uint64 seriesId, uint8 expected, uint8 actual);
    error SaleNotOpen(uint64 seriesId, uint256 timestamp);
    error ExerciseNotOpen(uint64 seriesId, uint256 timestamp);
    error SeriesNotExpired(uint64 seriesId, uint256 expiry);
    error SeriesAlreadyCancelled(uint64 seriesId);
    error InsufficientInventory(uint64 seriesId, uint256 available, uint256 requested);
    error AccountingOverflow();

    error PositionNotFound(uint256 positionId);
    error PositionNotActive(uint256 positionId);
    error NotPositionOwner(uint256 positionId, address account);
    error PositionAlreadySettled(uint256 positionId);
    error PositionTransferRejected(address recipient);
    error TokenTransferRejected(address recipient);
    error TokenBalanceTooLow(address account, uint256 tokenId, uint256 available, uint256 required);
    error TokenNotApproved(address owner, address operator);
    error LengthMismatch();

    error PremiumAboveLimit(uint256 quoted, uint256 maximum);
    error PremiumUnavailable(uint256 positionId);
    error CollateralAboveLimit(uint256 quoted, uint256 maximum);
    error CollateralUnavailable(uint256 positionId);
    error PayoutBelowMinimum(uint256 quoted, uint256 minimum);
    error PayoutIsZero(uint64 seriesId, uint256 priceX18);

    error RequestNotFound(uint256 requestId);
    error RequestNotPending(uint256 requestId);
    error RequestNotProcessing(uint256 requestId);
    error RequestNotExecutable(uint256 requestId, uint256 executableAt);
    error RequestAlreadyProcessed(uint256 requestId);
    error BatchTooLarge(uint256 supplied, uint256 maximum);

    error ReserveTooLow(uint64 seriesId, uint256 available, uint256 required);
    error EscrowBalanceTooLow(address asset, uint256 available, uint256 required);
    error InvalidSettlement(uint256 requestId);
}
