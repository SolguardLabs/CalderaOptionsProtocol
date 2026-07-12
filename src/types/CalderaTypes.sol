// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Shared domain types used by the Caldera options clearing system.
library CalderaTypes {
    enum OptionType {
        Call,
        Put
    }

    enum SeriesPhase {
        Uninitialized,
        Scheduled,
        Funding,
        Exercise,
        Expired
    }

    enum RequestStatus {
        None,
        Pending,
        Processing,
        Processed
    }

    enum PositionStatus {
        None,
        Active,
        Settled
    }

    struct AssetConfig {
        bool enabled;
        uint8 decimals;
        uint32 depositCap;
        bytes32 symbol;
    }

    struct OracleFeed {
        uint192 priceX18;
        uint64 updatedAt;
        uint32 sequence;
        bool enabled;
    }

    struct SeriesInput {
        address collateralAsset;
        bytes32 underlyingId;
        OptionType optionType;
        uint64 saleStart;
        uint64 saleEnd;
        uint64 exerciseStart;
        uint64 expiry;
        uint32 settlementDelay;
        uint32 maxOracleAge;
        uint96 strikePriceX18;
        uint96 capPriceX18;
        uint128 contractSizeX18;
        uint16 feeBps;
    }

    struct SeriesConfig {
        address collateralAsset;
        bytes32 underlyingId;
        OptionType optionType;
        uint64 saleStart;
        uint64 saleEnd;
        uint64 exerciseStart;
        uint64 expiry;
        uint32 settlementDelay;
        uint32 maxOracleAge;
        uint96 strikePriceX18;
        uint96 capPriceX18;
        uint128 contractSizeX18;
        uint128 collateralPerContract;
        uint16 feeBps;
        uint8 collateralDecimals;
    }

    struct SeriesAccounting {
        uint128 writtenContracts;
        uint128 soldContracts;
        uint128 settledContracts;
        uint128 writerPositions;
        uint128 settledPositions;
        uint256 grossPremium;
        uint256 netPremium;
        uint256 processedPayout;
        uint256 collateralDeposited;
        uint256 collateralReleased;
        uint256 premiumIndexX128;
        uint256 lossIndexX128;
        uint256 premiumRemainderX128;
        uint256 lossRemainderX128;
    }

    struct WriterPositionData {
        uint64 seriesId;
        uint128 contracts;
        uint256 collateral;
        uint256 premiumIndexEntryX128;
        uint256 premiumClaimed;
        uint256 lossIndexEntryX128;
        uint256 lossRecognized;
        uint64 createdAt;
        uint64 settledAt;
        PositionStatus status;
    }

    struct ExerciseRequest {
        uint64 seriesId;
        uint128 contracts;
        address requester;
        address recipient;
        uint64 requestedAt;
        uint64 executableAt;
        uint192 exercisePriceX18;
        uint256 payout;
        RequestStatus status;
        uint64 processedAt;
    }

    struct PremiumQuote {
        uint256 intrinsicPerContract;
        uint256 timeValuePerContract;
        uint256 utilizationValuePerContract;
        uint256 premiumPerContract;
        uint256 totalPremium;
        uint256 feeAmount;
        uint256 writerAmount;
    }

    struct SettlementPreview {
        uint256 requestId;
        uint64 seriesId;
        address collateralAsset;
        address recipient;
        uint128 contracts;
        uint256 payout;
        uint256 reserveBefore;
        uint256 reserveDebit;
        uint256 liquidityDebit;
        uint256 lossIndexDeltaX128;
    }

    struct AssetSolvency {
        address asset;
        uint256 physicalBalance;
        uint256 accountedCollateral;
        uint256 protocolBuffer;
        uint256 cumulativeLiquidityDebit;
        uint256 surplus;
        uint256 deficit;
    }

    struct SeriesSnapshot {
        uint64 seriesId;
        SeriesPhase phase;
        SeriesConfig config;
        SeriesAccounting accounting;
        uint256 liveLongSupply;
        uint256 availableInventory;
        uint256 vaultReserve;
        uint256 pendingRequests;
        uint256 pendingPayout;
    }
}
