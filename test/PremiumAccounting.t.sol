// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { CalderaFixture } from "./helpers/CalderaFixture.sol";
import { CalderaTypes } from "../src/types/CalderaTypes.sol";
import { FixedPointMath } from "../src/libraries/FixedPointMath.sol";

contract PremiumAccountingTest is CalderaFixture {
    function testPremiumIsDistributedProRataAndClaimedByTwoWriters() public {
        uint64 seriesId = _createCallSeries();
        uint256 firstPosition = _write(seriesId, writer, 30);
        uint256 secondPosition = _write(seriesId, secondWriter, 70);
        CalderaTypes.PremiumQuote memory quote = protocol.quotePurchase(seriesId, 50);

        assertEq(_buy(seriesId, buyer, 50), quote.totalPremium);
        assertEq(premiumEscrow.premiumBalance(seriesId), quote.writerAmount);
        assertEq(premiumEscrow.feeBalance(address(usdc)), quote.feeAmount);
        _assertDistributionAndClaims(seriesId, firstPosition, secondPosition, quote.writerAmount);
    }

    function testLaterWriterOnlyParticipatesInSubsequentPremiumAccrual() public {
        uint64 seriesId = _createCallSeries();
        uint256 firstPosition = _write(seriesId, writer, 40);
        _buy(seriesId, buyer, 10);
        uint256 firstIndex = seriesController.accountingOf(seriesId).premiumIndexX128;

        uint256 secondPosition = _write(seriesId, secondWriter, 60);
        assertEq(writerPosition.getPosition(secondPosition).premiumIndexEntryX128, firstIndex);

        _buy(seriesId, secondBuyer, 20);
        uint256 finalIndex = seriesController.accountingOf(seriesId).premiumIndexX128;
        uint256 firstClaim = writerPosition.claimablePremium(firstPosition, finalIndex);
        uint256 secondClaim = writerPosition.claimablePremium(secondPosition, finalIndex);

        assertEq(secondClaim, FixedPointMath.fromQ128(60, finalIndex - firstIndex));
        assertGt(firstClaim, 0);
        assertGt(secondClaim, 0);
        _claimAndAssert(firstPosition, writer, firstClaim);
        _claimAndAssert(secondPosition, secondWriter, secondClaim);

        vm.prank(secondWriter);
        vm.expectRevert();
        protocol.claimPremium(secondPosition, secondWriter);
    }

    function _assertDistributionAndClaims(
        uint64 seriesId,
        uint256 firstPosition,
        uint256 secondPosition,
        uint256 writerAmount
    ) private {
        uint256 premiumIndex = seriesController.accountingOf(seriesId).premiumIndexX128;
        uint256 firstClaim = writerPosition.claimablePremium(firstPosition, premiumIndex);
        uint256 secondClaim = writerPosition.claimablePremium(secondPosition, premiumIndex);

        assertApproxEqAbs(firstClaim, FixedPointMath.mulDiv(writerAmount, 30, 100), 1);
        assertApproxEqAbs(secondClaim, FixedPointMath.mulDiv(writerAmount, 70, 100), 1);
        assertLe(writerAmount - firstClaim - secondClaim, 2);

        _claimAndAssert(firstPosition, writer, firstClaim);
        _claimAndAssert(secondPosition, secondWriter, secondClaim);
        assertEq(premiumEscrow.premiumBalance(seriesId), writerAmount - firstClaim - secondClaim);
        assertEq(writerPosition.claimablePremium(firstPosition, premiumIndex), 0);
        assertEq(writerPosition.claimablePremium(secondPosition, premiumIndex), 0);
    }

    function _claimAndAssert(uint256 positionId, address account, uint256 expected) private {
        uint256 balanceBefore = usdc.balanceOf(account);
        vm.prank(account);
        uint256 paid = protocol.claimPremium(positionId, account);
        assertEq(paid, expected);
        assertEq(usdc.balanceOf(account) - balanceBefore, expected);
        assertEq(writerPosition.getPosition(positionId).premiumClaimed, expected);
    }
}
