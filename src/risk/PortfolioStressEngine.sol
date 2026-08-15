// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { FixedPointMath } from "../libraries/FixedPointMath.sol";

/// @title PortfolioStressEngine
/// @notice Deterministic liquidity and concentration analysis for an options collateral asset.
contract PortfolioStressEngine {
    uint256 public constant BPS = 10_000;
    uint256 public constant NO_LIABILITY_COVERAGE_BPS = 20_000;
    bytes32 public constant REPORT_DOMAIN = keccak256("CALDERA_PORTFOLIO_STRESS_V1");

    error InvalidStressWindow(uint64 asOf, uint64 horizonEnd);
    error EmptyStressInput();
    error InvalidStressLimit();
    error InvalidBasisPoints(uint256 value);
    error NonCanonicalSource(bytes32 previous, bytes32 current);
    error NonCanonicalSeries(uint64 previous, uint64 current);

    struct LiquiditySource {
        bytes32 id;
        uint256 amount;
        uint64 availableAt;
        uint16 recoveryBps;
        uint16 haircutBps;
    }

    struct SeriesExposure {
        uint64 seriesId;
        uint256 nominalPayout;
        uint64 dueAt;
        uint16 exerciseProbabilityBps;
        uint16 volatilityAddonBps;
    }

    struct StressLimits {
        uint32 minimumCoverageBps;
        uint256 maximumShortfall;
        uint16 maximumSeriesShareBps;
        uint16 maximumHhiBps;
        uint64 maximumWeightedMaturity;
    }

    struct SourceResult {
        bytes32 id;
        uint256 nominal;
        uint256 recovered;
        uint256 haircut;
        uint256 effective;
        bool availableWithinHorizon;
    }

    struct ExposureResult {
        uint64 seriesId;
        uint256 nominal;
        uint256 probable;
        uint256 volatilityAddon;
        uint256 stressed;
        uint256 shareBps;
        uint64 secondsToMaturity;
        bool dueWithinHorizon;
    }

    struct StressReport {
        address asset;
        uint64 asOf;
        uint64 horizonEnd;
        uint256 totalEffectiveLiquidity;
        uint256 totalStressedOutflow;
        uint256 surplus;
        uint256 shortfall;
        uint256 coverageBps;
        uint256 weightedMaturitySeconds;
        uint256 largestSeriesShareBps;
        uint256 seriesHhiBps;
        bool withinLimits;
        bytes32 digest;
        SourceResult[] sources;
        ExposureResult[] exposures;
    }

    function evaluate(
        address asset,
        uint64 asOf,
        uint64 horizonEnd,
        LiquiditySource[] calldata sources,
        SeriesExposure[] calldata exposures,
        StressLimits calldata limits
    ) external pure returns (StressReport memory report) {
        if (asset == address(0) || horizonEnd <= asOf) {
            revert InvalidStressWindow(asOf, horizonEnd);
        }
        if (sources.length == 0 || exposures.length == 0) revert EmptyStressInput();
        _validateLimits(limits);

        report.asset = asset;
        report.asOf = asOf;
        report.horizonEnd = horizonEnd;
        report.sources = new SourceResult[](sources.length);
        report.exposures = new ExposureResult[](exposures.length);

        _evaluateSources(report, horizonEnd, sources);
        uint256 weightedMaturityNumerator = _evaluateExposures(report, asOf, horizonEnd, exposures);
        _aggregate(report, weightedMaturityNumerator, limits);
        report.digest = keccak256(
            abi.encode(
                REPORT_DOMAIN,
                report.asset,
                report.asOf,
                report.horizonEnd,
                report.totalEffectiveLiquidity,
                report.totalStressedOutflow,
                report.shortfall,
                report.coverageBps,
                report.weightedMaturitySeconds,
                report.largestSeriesShareBps,
                report.seriesHhiBps,
                report.withinLimits,
                report.sources,
                report.exposures
            )
        );
    }

    function _evaluateSources(
        StressReport memory report,
        uint64 horizonEnd,
        LiquiditySource[] calldata sources
    ) private pure {
        bytes32 previous;
        for (uint256 i; i < sources.length; ++i) {
            LiquiditySource calldata source = sources[i];
            if (source.id == bytes32(0) || source.id <= previous) {
                revert NonCanonicalSource(previous, source.id);
            }
            _validateBps(source.recoveryBps);
            _validateBps(source.haircutBps);

            bool available = source.availableAt <= horizonEnd;
            uint256 recovered =
                available ? FixedPointMath.mulDiv(source.amount, source.recoveryBps, BPS) : 0;
            uint256 haircut = FixedPointMath.mulDiv(recovered, source.haircutBps, BPS);
            uint256 effective = recovered - haircut;
            report.sources[i] = SourceResult({
                id: source.id,
                nominal: source.amount,
                recovered: recovered,
                haircut: haircut,
                effective: effective,
                availableWithinHorizon: available
            });
            report.totalEffectiveLiquidity += effective;
            previous = source.id;
        }
    }

    function _evaluateExposures(
        StressReport memory report,
        uint64 asOf,
        uint64 horizonEnd,
        SeriesExposure[] calldata exposures
    ) private pure returns (uint256 weightedMaturityNumerator) {
        uint64 previous;
        for (uint256 i; i < exposures.length; ++i) {
            SeriesExposure calldata exposure = exposures[i];
            if (exposure.seriesId == 0 || exposure.seriesId <= previous) {
                revert NonCanonicalSeries(previous, exposure.seriesId);
            }
            _validateBps(exposure.exerciseProbabilityBps);
            _validateBps(exposure.volatilityAddonBps);

            bool due = exposure.dueAt <= horizonEnd;
            uint256 probable = due
                ? FixedPointMath.mulDiv(
                    exposure.nominalPayout, exposure.exerciseProbabilityBps, BPS
                )
                : 0;
            uint256 addon = due
                ? FixedPointMath.mulDiv(exposure.nominalPayout, exposure.volatilityAddonBps, BPS)
                : 0;
            uint256 stressed = probable + addon;
            uint64 maturity = exposure.dueAt <= asOf ? 0 : exposure.dueAt - asOf;
            report.exposures[i] = ExposureResult({
                seriesId: exposure.seriesId,
                nominal: exposure.nominalPayout,
                probable: probable,
                volatilityAddon: addon,
                stressed: stressed,
                shareBps: 0,
                secondsToMaturity: maturity,
                dueWithinHorizon: due
            });
            report.totalStressedOutflow += stressed;
            weightedMaturityNumerator += stressed * maturity;
            previous = exposure.seriesId;
        }
    }

    function _aggregate(
        StressReport memory report,
        uint256 weightedMaturityNumerator,
        StressLimits calldata limits
    ) private pure {
        uint256 source = report.totalEffectiveLiquidity;
        uint256 outflow = report.totalStressedOutflow;
        if (source >= outflow) {
            report.surplus = source - outflow;
        } else {
            report.shortfall = outflow - source;
        }
        report.coverageBps =
            outflow == 0 ? NO_LIABILITY_COVERAGE_BPS : FixedPointMath.mulDiv(source, BPS, outflow);
        report.weightedMaturitySeconds = outflow == 0 ? 0 : weightedMaturityNumerator / outflow;

        for (uint256 i; i < report.exposures.length; ++i) {
            uint256 share = outflow == 0
                ? 0
                : FixedPointMath.mulDiv(report.exposures[i].stressed, BPS, outflow);
            report.exposures[i].shareBps = share;
            report.largestSeriesShareBps = FixedPointMath.max(report.largestSeriesShareBps, share);
            report.seriesHhiBps += FixedPointMath.mulDiv(share, share, BPS);
        }

        report.withinLimits = report.coverageBps >= limits.minimumCoverageBps
            && report.shortfall <= limits.maximumShortfall
            && report.largestSeriesShareBps <= limits.maximumSeriesShareBps
            && report.seriesHhiBps <= limits.maximumHhiBps
            && report.weightedMaturitySeconds <= limits.maximumWeightedMaturity;
    }

    function _validateLimits(StressLimits calldata limits) private pure {
        if (
            limits.minimumCoverageBps == 0 || limits.minimumCoverageBps > 50_000
                || limits.maximumSeriesShareBps == 0 || limits.maximumHhiBps == 0
                || limits.maximumWeightedMaturity == 0
        ) revert InvalidStressLimit();
        _validateBps(limits.maximumSeriesShareBps);
        _validateBps(limits.maximumHhiBps);
    }

    function _validateBps(uint256 value) private pure {
        if (value > BPS) revert InvalidBasisPoints(value);
    }
}
