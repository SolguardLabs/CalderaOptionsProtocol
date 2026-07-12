// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { AccessManaged } from "../utils/AccessManaged.sol";
import { CalderaTypes } from "../types/CalderaTypes.sol";
import { CalderaErrors } from "../errors/CalderaErrors.sol";
import { FixedPointMath } from "../libraries/FixedPointMath.sol";

/// @title SeriesController
/// @notice Canonical registry and accounting ledger for covered option series.
contract SeriesController is AccessManaged {
    uint256 private constant Q128 = 1 << 128;

    uint64 public nextSeriesId = 1;

    mapping(uint64 seriesId => CalderaTypes.SeriesConfig config) private _configs;
    mapping(uint64 seriesId => CalderaTypes.SeriesAccounting accounting) private _accounting;
    mapping(uint64 seriesId => bool exists) private _exists;

    event SeriesCreated(
        uint64 indexed seriesId,
        address indexed collateralAsset,
        bytes32 indexed underlyingId,
        CalderaTypes.OptionType optionType,
        uint64 saleStart,
        uint64 expiry
    );
    event ContractsWritten(
        uint64 indexed seriesId,
        uint128 contracts,
        uint256 collateral,
        uint128 totalWrittenContracts
    );
    event ContractsSold(uint64 indexed seriesId, uint128 contracts, uint128 totalSoldContracts);
    event PremiumAccrued(
        uint64 indexed seriesId,
        uint256 grossPremium,
        uint256 netPremium,
        uint256 premiumIndexDeltaX128,
        uint256 premiumIndexX128
    );
    event SettlementRecorded(
        uint64 indexed seriesId,
        uint128 contracts,
        uint256 payout,
        uint256 lossIndexDeltaX128,
        uint256 lossIndexX128
    );
    event CollateralReleaseRecorded(
        uint64 indexed seriesId,
        uint256 collateral,
        uint128 settledPositions,
        uint256 totalCollateralReleased
    );

    constructor(address accessController_) AccessManaged(accessController_) { }

    /// @notice Registers a validated series configuration.
    function createSeries(CalderaTypes.SeriesConfig calldata config)
        external
        onlyProtocol
        whenNotPaused
        returns (uint64 seriesId)
    {
        _validateConfig(config);

        seriesId = nextSeriesId;
        if (seriesId == type(uint64).max) revert CalderaErrors.AccountingOverflow();
        unchecked {
            nextSeriesId = seriesId + 1;
        }

        _configs[seriesId] = config;
        _exists[seriesId] = true;

        emit SeriesCreated(
            seriesId,
            config.collateralAsset,
            config.underlyingId,
            config.optionType,
            config.saleStart,
            config.expiry
        );
    }

    /// @notice Records a newly collateralized writer position.
    function recordWritten(uint64 seriesId, uint128 contracts, uint256 collateral)
        external
        onlyProtocol
        whenNotPaused
    {
        _requireSeries(seriesId);
        if (contracts == 0 || collateral == 0) revert CalderaErrors.ZeroAmount();
        if (!isSaleOpen(seriesId)) {
            revert CalderaErrors.SaleNotOpen(seriesId, block.timestamp);
        }

        uint256 requiredCollateral = uint256(_configs[seriesId].collateralPerContract) * contracts;
        if (collateral != requiredCollateral) {
            revert CalderaErrors.InvalidConfiguration();
        }

        CalderaTypes.SeriesAccounting storage accounting = _accounting[seriesId];
        accounting.writtenContracts = _add128(accounting.writtenContracts, contracts);
        accounting.writerPositions = _add128(accounting.writerPositions, 1);
        accounting.collateralDeposited = _add256(accounting.collateralDeposited, collateral);

        emit ContractsWritten(seriesId, contracts, collateral, accounting.writtenContracts);
    }

    /// @notice Records contracts transferred from protocol inventory to buyers.
    function recordSale(uint64 seriesId, uint128 contracts) external onlyProtocol whenNotPaused {
        _requireSeries(seriesId);
        if (contracts == 0) revert CalderaErrors.ZeroAmount();
        if (!isSaleOpen(seriesId)) {
            revert CalderaErrors.SaleNotOpen(seriesId, block.timestamp);
        }

        CalderaTypes.SeriesAccounting storage accounting = _accounting[seriesId];
        uint128 soldAfter = _add128(accounting.soldContracts, contracts);
        if (soldAfter > accounting.writtenContracts) {
            revert CalderaErrors.InsufficientInventory(
                seriesId, uint256(accounting.writtenContracts) - accounting.soldContracts, contracts
            );
        }
        accounting.soldContracts = soldAfter;

        emit ContractsSold(seriesId, contracts, soldAfter);
    }

    /// @notice Adds collected premium and advances the per-contract premium index.
    /// @dev The index is allocated across all written contracts. A scaled remainder is
    ///      carried into the next accrual so repeated small premiums are not discarded.
    function accruePremium(uint64 seriesId, uint256 grossPremium, uint256 netPremium)
        external
        onlyProtocol
        whenNotPaused
        returns (uint256 premiumIndexDeltaX128)
    {
        _requireSeries(seriesId);
        if (grossPremium == 0) revert CalderaErrors.ZeroAmount();
        if (netPremium > grossPremium) revert CalderaErrors.InvalidConfiguration();

        CalderaTypes.SeriesAccounting storage accounting = _accounting[seriesId];
        uint128 shares = accounting.writtenContracts;
        if (shares == 0) revert CalderaErrors.InvalidConfiguration();

        (premiumIndexDeltaX128, accounting.premiumRemainderX128) =
            _indexDelta(netPremium, shares, accounting.premiumRemainderX128);

        accounting.grossPremium = _add256(accounting.grossPremium, grossPremium);
        accounting.netPremium = _add256(accounting.netPremium, netPremium);
        accounting.premiumIndexX128 = _add256(accounting.premiumIndexX128, premiumIndexDeltaX128);

        emit PremiumAccrued(
            seriesId, grossPremium, netPremium, premiumIndexDeltaX128, accounting.premiumIndexX128
        );
    }

    /// @notice Records a processed exercise and advances the per-contract loss index.
    function recordSettlement(uint64 seriesId, uint128 contracts, uint256 payout)
        external
        onlyProtocol
        whenNotPaused
        returns (uint256 lossIndexDeltaX128)
    {
        _requireSeries(seriesId);
        if (contracts == 0 || payout == 0) revert CalderaErrors.ZeroAmount();

        CalderaTypes.SeriesAccounting storage accounting = _accounting[seriesId];
        uint128 settledAfter = _add128(accounting.settledContracts, contracts);
        if (settledAfter > accounting.soldContracts) {
            revert CalderaErrors.InvalidSettlement(0);
        }

        (lossIndexDeltaX128, accounting.lossRemainderX128) =
            _indexDelta(payout, accounting.writtenContracts, accounting.lossRemainderX128);

        accounting.settledContracts = settledAfter;
        accounting.processedPayout = _add256(accounting.processedPayout, payout);
        accounting.lossIndexX128 = _add256(accounting.lossIndexX128, lossIndexDeltaX128);

        emit SettlementRecorded(
            seriesId, contracts, payout, lossIndexDeltaX128, accounting.lossIndexX128
        );
    }

    /// @notice Records collateral returned when a writer position is settled.
    function recordRelease(uint64 seriesId, uint256 collateral)
        external
        onlyProtocol
        whenNotPaused
    {
        _requireSeries(seriesId);

        CalderaTypes.SeriesConfig storage config = _configs[seriesId];
        if (block.timestamp < config.expiry) {
            revert CalderaErrors.SeriesNotExpired(seriesId, config.expiry);
        }

        CalderaTypes.SeriesAccounting storage accounting = _accounting[seriesId];
        uint256 releasedAfter = _add256(accounting.collateralReleased, collateral);
        if (releasedAfter > accounting.collateralDeposited) {
            revert CalderaErrors.CollateralUnavailable(0);
        }
        uint128 positionsAfter = _add128(accounting.settledPositions, 1);
        if (positionsAfter > accounting.writerPositions) {
            revert CalderaErrors.AccountingOverflow();
        }

        accounting.collateralReleased = releasedAfter;
        accounting.settledPositions = positionsAfter;

        emit CollateralReleaseRecorded(seriesId, collateral, positionsAfter, releasedAfter);
    }

    function getSeries(uint64 seriesId)
        external
        view
        returns (
            CalderaTypes.SeriesConfig memory config,
            CalderaTypes.SeriesAccounting memory accounting,
            CalderaTypes.SeriesPhase currentPhase
        )
    {
        _requireSeries(seriesId);
        config = _configs[seriesId];
        accounting = _accounting[seriesId];
        currentPhase = phaseAt(seriesId, block.timestamp);
    }

    function configOf(uint64 seriesId) external view returns (CalderaTypes.SeriesConfig memory) {
        _requireSeries(seriesId);
        return _configs[seriesId];
    }

    function accountingOf(uint64 seriesId)
        external
        view
        returns (CalderaTypes.SeriesAccounting memory)
    {
        _requireSeries(seriesId);
        return _accounting[seriesId];
    }

    function phase(uint64 seriesId) external view returns (CalderaTypes.SeriesPhase) {
        return phaseAt(seriesId, block.timestamp);
    }

    function phaseAt(uint64 seriesId, uint256 timestamp)
        public
        view
        returns (CalderaTypes.SeriesPhase)
    {
        if (!_exists[seriesId]) return CalderaTypes.SeriesPhase.Uninitialized;

        CalderaTypes.SeriesConfig storage config = _configs[seriesId];
        if (timestamp < config.saleStart) return CalderaTypes.SeriesPhase.Scheduled;
        if (timestamp < config.exerciseStart) return CalderaTypes.SeriesPhase.Funding;
        if (timestamp < config.expiry) return CalderaTypes.SeriesPhase.Exercise;
        return CalderaTypes.SeriesPhase.Expired;
    }

    function exists(uint64 seriesId) external view returns (bool) {
        return _exists[seriesId];
    }

    function seriesCount() external view returns (uint256) {
        return uint256(nextSeriesId) - 1;
    }

    function isSaleOpen(uint64 seriesId) public view returns (bool) {
        if (!_exists[seriesId]) return false;
        CalderaTypes.SeriesConfig storage config = _configs[seriesId];
        return block.timestamp >= config.saleStart && block.timestamp < config.saleEnd;
    }

    function isExerciseOpen(uint64 seriesId) external view returns (bool) {
        if (!_exists[seriesId]) return false;
        CalderaTypes.SeriesConfig storage config = _configs[seriesId];
        return block.timestamp >= config.exerciseStart && block.timestamp < config.expiry;
    }

    function availableInventory(uint64 seriesId) external view returns (uint256) {
        _requireSeries(seriesId);
        CalderaTypes.SeriesAccounting storage accounting = _accounting[seriesId];
        return uint256(accounting.writtenContracts) - accounting.soldContracts;
    }

    function unprocessedSoldContracts(uint64 seriesId) external view returns (uint256) {
        _requireSeries(seriesId);
        CalderaTypes.SeriesAccounting storage accounting = _accounting[seriesId];
        return uint256(accounting.soldContracts) - accounting.settledContracts;
    }

    function previewPremiumIndexDelta(uint64 seriesId, uint256 netPremium)
        external
        view
        returns (uint256 indexDeltaX128, uint256 nextRemainderX128)
    {
        _requireSeries(seriesId);
        CalderaTypes.SeriesAccounting storage accounting = _accounting[seriesId];
        return _indexDelta(netPremium, accounting.writtenContracts, accounting.premiumRemainderX128);
    }

    function previewLossIndexDelta(uint64 seriesId, uint256 payout)
        external
        view
        returns (uint256 indexDeltaX128, uint256 nextRemainderX128)
    {
        _requireSeries(seriesId);
        CalderaTypes.SeriesAccounting storage accounting = _accounting[seriesId];
        return _indexDelta(payout, accounting.writtenContracts, accounting.lossRemainderX128);
    }

    function _validateConfig(CalderaTypes.SeriesConfig calldata config) private pure {
        if (config.collateralAsset == address(0)) revert CalderaErrors.ZeroAddress();
        if (config.underlyingId == bytes32(0)) revert CalderaErrors.InvalidConfiguration();
        if (
            config.saleStart >= config.saleEnd || config.saleEnd > config.exerciseStart
                || config.exerciseStart >= config.expiry
        ) {
            revert CalderaErrors.InvalidSeriesWindow();
        }
        if (config.settlementDelay == 0) {
            revert CalderaErrors.InvalidSettlementDelay(config.settlementDelay);
        }
        if (config.maxOracleAge == 0) {
            revert CalderaErrors.InvalidOracleAge(config.maxOracleAge);
        }
        if (config.strikePriceX18 == 0) {
            revert CalderaErrors.InvalidStrike(config.strikePriceX18);
        }
        if (
            config.optionType == CalderaTypes.OptionType.Call
                && config.capPriceX18 <= config.strikePriceX18
        ) {
            revert CalderaErrors.InvalidCap(config.strikePriceX18, config.capPriceX18);
        }
        if (config.contractSizeX18 == 0) {
            revert CalderaErrors.InvalidContractSize(config.contractSizeX18);
        }
        if (config.collateralPerContract == 0) revert CalderaErrors.InvalidConfiguration();
        if (config.feeBps > 10_000) revert CalderaErrors.InvalidFee(config.feeBps);
        if (config.collateralDecimals > 18) {
            revert CalderaErrors.UnsupportedDecimals(config.collateralDecimals);
        }
    }

    function _indexDelta(uint256 amount, uint128 shares, uint256 carriedRemainder)
        private
        pure
        returns (uint256 indexDeltaX128, uint256 nextRemainderX128)
    {
        if (shares == 0) revert CalderaErrors.InvalidConfiguration();

        uint256 denominator = uint256(shares);
        indexDeltaX128 = FixedPointMath.mulDiv(amount, Q128, denominator);
        uint256 remainder = mulmod(amount, Q128, denominator) + carriedRemainder;
        if (remainder >= denominator) {
            indexDeltaX128 = _add256(indexDeltaX128, remainder / denominator);
            remainder %= denominator;
        }
        nextRemainderX128 = remainder;
    }

    function _requireSeries(uint64 seriesId) private view {
        if (!_exists[seriesId]) revert CalderaErrors.SeriesNotFound(seriesId);
    }

    function _add128(uint128 a, uint128 b) private pure returns (uint128 result) {
        unchecked {
            result = a + b;
        }
        if (result < a) revert CalderaErrors.AccountingOverflow();
    }

    function _add256(uint256 a, uint256 b) private pure returns (uint256 result) {
        unchecked {
            result = a + b;
        }
        if (result < a) revert CalderaErrors.AccountingOverflow();
    }
}
