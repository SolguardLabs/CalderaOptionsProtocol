// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { CalderaFixture } from "./helpers/CalderaFixture.sol";
import { CalderaTypes } from "../src/types/CalderaTypes.sol";
import { CalderaErrors } from "../src/errors/CalderaErrors.sol";

contract ExerciseSettlementTest is CalderaFixture {
    function testRequestBurnsLongAndKeepsQuotedPayout() public {
        uint64 seriesId = _createCallSeries();
        _write(seriesId, writer, 2);
        _buy(seriesId, buyer, 2);
        _moveToExercise(seriesId);

        assertEq(optionToken.balanceOf(buyer, seriesId), 2);
        vm.prank(buyer);
        uint256 requestId = protocol.requestExercise(seriesId, 1, buyer, 500 * USDC);

        CalderaTypes.ExerciseRequest memory request = exerciseQueue.getRequest(requestId);
        assertEq(optionToken.balanceOf(buyer, seriesId), 1);
        assertEq(optionToken.totalSupply(seriesId), 1);
        assertEq(request.requester, buyer);
        assertEq(request.recipient, buyer);
        assertEq(request.contracts, 1);
        assertEq(request.exercisePriceX18, 2500e18);
        assertEq(request.payout, 500 * USDC);
        assertEq(request.executableAt, block.timestamp + 1 days);
        assertEq(uint8(request.status), uint8(CalderaTypes.RequestStatus.Pending));

        _publishPrice(2900e18);
        vm.warp(request.executableAt);
        uint256 balanceBefore = usdc.balanceOf(buyer);
        vm.prank(keeper);
        CalderaTypes.SettlementPreview memory result = protocol.processExercise(requestId);

        assertEq(result.payout, 500 * USDC);
        assertEq(result.reserveDebit, 500 * USDC);
        assertEq(result.liquidityDebit, 0);
        assertEq(usdc.balanceOf(buyer) - balanceBefore, 500 * USDC);
    }

    function testRequestCannotProcessBeforeDelay() public {
        (uint64 seriesId, uint256 requestId) = _requestOneContract(buyer);
        CalderaTypes.ExerciseRequest memory request = exerciseQueue.getRequest(requestId);

        vm.expectRevert(
            abi.encodeWithSelector(
                CalderaErrors.RequestNotExecutable.selector, requestId, request.executableAt
            )
        );
        vm.prank(keeper);
        protocol.processExercise(requestId);

        assertEq(exerciseQueue.pendingCountBySeries(seriesId), 1);
        assertEq(exerciseQueue.pendingPayoutBySeries(seriesId), 500 * USDC);
        assertEq(
            uint8(exerciseQueue.getRequest(requestId).status),
            uint8(CalderaTypes.RequestStatus.Pending)
        );
    }

    function testProcessedRequestCannotReplay() public {
        (, uint256 requestId) = _requestOneContract(buyer);
        CalderaTypes.ExerciseRequest memory request = exerciseQueue.getRequest(requestId);
        vm.warp(request.executableAt);

        vm.prank(keeper);
        protocol.processExercise(requestId);
        assertEq(
            uint8(exerciseQueue.getRequest(requestId).status),
            uint8(CalderaTypes.RequestStatus.Processed)
        );

        vm.expectRevert(abi.encodeWithSelector(CalderaErrors.RequestNotPending.selector, requestId));
        vm.prank(keeper);
        protocol.processExercise(requestId);
    }

    function testProcessesExerciseBatch() public {
        uint64 seriesId = _createCallSeries();
        _write(seriesId, writer, 4);
        _buy(seriesId, buyer, 2);
        _buy(seriesId, secondBuyer, 2);
        _moveToExercise(seriesId);

        vm.prank(buyer);
        uint256 firstRequest = protocol.requestExercise(seriesId, 2, buyer, 0);
        vm.prank(secondBuyer);
        uint256 secondRequest = protocol.requestExercise(seriesId, 2, secondBuyer, 0);

        assertEq(exerciseQueue.pendingCountBySeries(seriesId), 2);
        assertEq(exerciseQueue.pendingPayoutBySeries(seriesId), 2000 * USDC);

        uint256[] memory requestIds = new uint256[](2);
        requestIds[0] = firstRequest;
        requestIds[1] = secondRequest;
        vm.warp(exerciseQueue.getRequest(firstRequest).executableAt);
        uint256 firstBalanceBefore = usdc.balanceOf(buyer);
        uint256 secondBalanceBefore = usdc.balanceOf(secondBuyer);

        vm.prank(keeper);
        CalderaTypes.SettlementPreview[] memory results = protocol.processExerciseBatch(requestIds);

        assertEq(results.length, 2);
        assertEq(results[0].payout, 1000 * USDC);
        assertEq(results[1].payout, 1000 * USDC);
        assertEq(usdc.balanceOf(buyer) - firstBalanceBefore, 1000 * USDC);
        assertEq(usdc.balanceOf(secondBuyer) - secondBalanceBefore, 1000 * USDC);
        assertEq(exerciseQueue.pendingCountBySeries(seriesId), 0);
        assertEq(exerciseQueue.pendingPayoutBySeries(seriesId), 0);
        assertEq(
            uint8(exerciseQueue.getRequest(firstRequest).status),
            uint8(CalderaTypes.RequestStatus.Processed)
        );
        assertEq(
            uint8(exerciseQueue.getRequest(secondRequest).status),
            uint8(CalderaTypes.RequestStatus.Processed)
        );
    }

    function _requestOneContract(address account)
        private
        returns (uint64 seriesId, uint256 requestId)
    {
        seriesId = _createCallSeries();
        _write(seriesId, writer, 1);
        _buy(seriesId, account, 1);
        _moveToExercise(seriesId);
        vm.prank(account);
        requestId = protocol.requestExercise(seriesId, 1, account, 0);
    }
}
