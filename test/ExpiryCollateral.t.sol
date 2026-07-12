// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { CalderaFixture } from "./helpers/CalderaFixture.sol";
import { CalderaTypes } from "../src/types/CalderaTypes.sol";

contract ExpiryCollateralTest is CalderaFixture {
    function testProcessedExerciseReducesCollateralRefund() public {
        uint64 seriesId = _createCallSeries();
        uint256 positionId = _write(seriesId, writer, 2);
        _buy(seriesId, buyer, 1);
        _moveToExercise(seriesId);

        vm.prank(buyer);
        uint256 requestId = protocol.requestExercise(seriesId, 1, buyer, 0);
        vm.warp(exerciseQueue.getRequest(requestId).executableAt);
        vm.prank(keeper);
        protocol.processExercise(requestId);

        assertEq(collateralVault.reserveBySeries(seriesId), 1500 * USDC);
        _moveToExpiry(seriesId);
        vm.prank(writer);
        (uint256 collateralReturned, uint256 recognizedLoss, uint256 premiumPaid) =
            protocol.settleWriterPosition(positionId, writer);

        assertEq(collateralReturned, 1500 * USDC);
        assertEq(recognizedLoss, 500 * USDC);
        assertGt(premiumPaid, 0);
        assertEq(collateralVault.reserveBySeries(seriesId), 0);

        CalderaTypes.SeriesAccounting memory accounting = seriesController.accountingOf(seriesId);
        assertEq(accounting.processedPayout, 500 * USDC);
        assertEq(accounting.collateralReleased, 1500 * USDC);
        assertEq(accounting.settledPositions, 1);
    }

    function testExpiryWithoutExerciseReturnsAllCollateral() public {
        uint64 seriesId = _createCallSeries();
        uint256 positionId = _write(seriesId, writer, 2);
        _buy(seriesId, buyer, 1);
        _moveToExpiry(seriesId);

        vm.prank(writer);
        (uint256 collateralReturned, uint256 recognizedLoss, uint256 premiumPaid) =
            protocol.settleWriterPosition(positionId, writer);

        assertEq(collateralReturned, 2000 * USDC);
        assertEq(recognizedLoss, 0);
        assertGt(premiumPaid, 0);
        assertEq(collateralVault.reserveBySeries(seriesId), 0);
        CalderaTypes.WriterPositionData memory position = writerPosition.getPosition(positionId);
        assertEq(uint8(position.status), uint8(CalderaTypes.PositionStatus.Settled));
    }

    function testFullExercisePayoutConsumesSeriesCollateral() public {
        uint64 seriesId = _createCallSeries();
        uint256 positionId = _write(seriesId, writer, 1);
        _buy(seriesId, buyer, 1);
        _moveToExercise(seriesId);
        _publishPrice(3500e18);

        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        vm.prank(buyer);
        uint256 requestId = protocol.requestExercise(seriesId, 1, buyer, 1000 * USDC);
        CalderaTypes.ExerciseRequest memory request = exerciseQueue.getRequest(requestId);
        assertEq(request.payout, 1000 * USDC);

        vm.warp(request.executableAt);
        vm.prank(keeper);
        CalderaTypes.SettlementPreview memory result = protocol.processExercise(requestId);

        assertEq(result.payout, 1000 * USDC);
        assertEq(result.reserveDebit, 1000 * USDC);
        assertEq(result.liquidityDebit, 0);
        assertEq(usdc.balanceOf(buyer) - buyerBalanceBefore, 1000 * USDC);
        assertEq(collateralVault.reserveBySeries(seriesId), 0);

        _moveToExpiry(seriesId);
        vm.prank(writer);
        (uint256 collateralReturned, uint256 recognizedLoss,) =
            protocol.settleWriterPosition(positionId, writer);

        assertEq(collateralReturned, 0);
        assertEq(recognizedLoss, 1000 * USDC);
        CalderaTypes.SeriesAccounting memory accounting = seriesController.accountingOf(seriesId);
        assertEq(accounting.collateralReleased, 0);
        assertEq(accounting.settledPositions, 1);
    }
}
