// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { PortfolioStressEngine } from "../src/risk/PortfolioStressEngine.sol";

contract PortfolioStressEngineTest is Test {
    PortfolioStressEngine private engine;
    address private constant USDC_ASSET = address(0xA11CE);
    uint64 private constant AS_OF = 1_800_000_000;
    uint64 private constant HORIZON = AS_OF + 14 days;

    function setUp() public {
        engine = new PortfolioStressEngine();
    }

    function testEvaluatesHaircutsCoverageMaturityAndConcentration() public view {
        PortfolioStressEngine.StressReport memory report =
            engine.evaluate(USDC_ASSET, AS_OF, HORIZON, _sources(), _exposures(), _limits());

        assertEq(report.totalEffectiveLiquidity, 1_124_000e6);
        assertEq(report.totalStressedOutflow, 1_020_000e6);
        assertEq(report.surplus, 104_000e6);
        assertEq(report.shortfall, 0);
        assertEq(report.coverageBps, 11_019);
        assertEq(report.weightedMaturitySeconds, 686_117);
        assertEq(report.exposures[0].shareBps, 2941);
        assertEq(report.exposures[1].shareBps, 7058);
        assertEq(report.exposures[2].shareBps, 0);
        assertEq(report.largestSeriesShareBps, 7058);
        assertEq(report.seriesHhiBps, 5845);
        assertTrue(report.withinLimits);
        assertNotEq(report.digest, bytes32(0));
    }

    function testExcludesSourcesAndExposuresBeyondHorizon() public view {
        PortfolioStressEngine.StressReport memory report =
            engine.evaluate(USDC_ASSET, AS_OF, HORIZON, _sources(), _exposures(), _limits());

        assertFalse(report.sources[1].availableWithinHorizon);
        assertEq(report.sources[1].effective, 0);
        assertFalse(report.exposures[2].dueWithinHorizon);
        assertEq(report.exposures[2].stressed, 0);
    }

    function testReportDigestBindsEconomicInputs() public view {
        PortfolioStressEngine.SeriesExposure[] memory changed = _exposures();
        changed[1].nominalPayout += 1;
        PortfolioStressEngine.StressReport memory baseline =
            engine.evaluate(USDC_ASSET, AS_OF, HORIZON, _sources(), _exposures(), _limits());
        PortfolioStressEngine.StressReport memory modified =
            engine.evaluate(USDC_ASSET, AS_OF, HORIZON, _sources(), changed, _limits());

        assertNotEq(baseline.digest, modified.digest);
    }

    function testRejectsNonCanonicalSeriesOrder() public {
        PortfolioStressEngine.SeriesExposure[] memory exposures = _exposures();
        (exposures[0], exposures[1]) = (exposures[1], exposures[0]);

        vm.expectRevert(
            abi.encodeWithSelector(PortfolioStressEngine.NonCanonicalSeries.selector, 2, 1)
        );
        engine.evaluate(USDC_ASSET, AS_OF, HORIZON, _sources(), exposures, _limits());
    }

    function _sources()
        private
        pure
        returns (PortfolioStressEngine.LiquiditySource[] memory sources)
    {
        sources = new PortfolioStressEngine.LiquiditySource[](3);
        sources[0] = PortfolioStressEngine.LiquiditySource({
            id: bytes32("cash"),
            amount: 800_000e6,
            availableAt: AS_OF,
            recoveryBps: 10_000,
            haircutBps: 0
        });
        sources[1] = PortfolioStressEngine.LiquiditySource({
            id: bytes32("receivable"),
            amount: 300_000e6,
            availableAt: HORIZON + 1,
            recoveryBps: 10_000,
            haircutBps: 0
        });
        sources[2] = PortfolioStressEngine.LiquiditySource({
            id: bytes32("reserve"),
            amount: 400_000e6,
            availableAt: AS_OF + 1 days,
            recoveryBps: 9000,
            haircutBps: 1000
        });
    }

    function _exposures()
        private
        pure
        returns (PortfolioStressEngine.SeriesExposure[] memory exposures)
    {
        exposures = new PortfolioStressEngine.SeriesExposure[](3);
        exposures[0] = PortfolioStressEngine.SeriesExposure({
            seriesId: 1,
            nominalPayout: 300_000e6,
            dueAt: AS_OF + 3 days,
            exerciseProbabilityBps: 10_000,
            volatilityAddonBps: 0
        });
        exposures[1] = PortfolioStressEngine.SeriesExposure({
            seriesId: 2,
            nominalPayout: 600_000e6,
            dueAt: AS_OF + 10 days,
            exerciseProbabilityBps: 10_000,
            volatilityAddonBps: 2000
        });
        exposures[2] = PortfolioStressEngine.SeriesExposure({
            seriesId: 3,
            nominalPayout: 500_000e6,
            dueAt: HORIZON + 1 days,
            exerciseProbabilityBps: 10_000,
            volatilityAddonBps: 5000
        });
    }

    function _limits() private pure returns (PortfolioStressEngine.StressLimits memory limits) {
        limits = PortfolioStressEngine.StressLimits({
            minimumCoverageBps: 11_000,
            maximumShortfall: 0,
            maximumSeriesShareBps: 7500,
            maximumHhiBps: 6000,
            maximumWeightedMaturity: 700_000
        });
    }
}
