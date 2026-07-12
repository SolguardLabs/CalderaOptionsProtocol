// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { CalderaFixture } from "./helpers/CalderaFixture.sol";
import { CalderaTypes } from "../src/types/CalderaTypes.sol";
import { CalderaErrors } from "../src/errors/CalderaErrors.sol";

contract SeriesLifecycleTest is CalderaFixture {
    function testCreateCallSeriesStoresValidatedTerms() public {
        CalderaTypes.SeriesInput memory input = defaultCallInput();

        uint64 seriesId = protocol.createSeries(input);
        CalderaTypes.SeriesConfig memory config = seriesController.configOf(seriesId);

        assertEq(seriesId, 1);
        assertEq(seriesController.seriesCount(), 1);
        assertEq(config.collateralAsset, address(usdc));
        assertEq(config.underlyingId, ETH_USD);
        assertEq(uint8(config.optionType), uint8(CalderaTypes.OptionType.Call));
        assertEq(config.saleStart, input.saleStart);
        assertEq(config.saleEnd, input.saleEnd);
        assertEq(config.exerciseStart, input.exerciseStart);
        assertEq(config.expiry, input.expiry);
        assertEq(config.strikePriceX18, 2000e18);
        assertEq(config.capPriceX18, 3000e18);
        assertEq(config.contractSizeX18, WAD);
        assertEq(config.collateralPerContract, 1000 * USDC);
        assertEq(config.collateralDecimals, 6);
        assertEq(config.feeBps, 100);
    }

    function testPutSeriesUsesStrikeAsMaximumCashPayout() public {
        CalderaTypes.SeriesInput memory input = defaultCallInput();
        input.optionType = CalderaTypes.OptionType.Put;
        input.capPriceX18 = 0;

        uint64 seriesId = protocol.createSeries(input);
        CalderaTypes.SeriesConfig memory config = seriesController.configOf(seriesId);

        assertEq(uint8(config.optionType), uint8(CalderaTypes.OptionType.Put));
        assertEq(config.capPriceX18, 0);
        assertEq(config.collateralPerContract, 2000 * USDC);

        uint256 payoutAtZero = riskEngine.exercisePayout(config, 1, 1);
        assertEq(payoutAtZero, 1999 * USDC + 999_999);
        assertLe(payoutAtZero, config.collateralPerContract);
    }

    function testCallSeriesRejectsCapAtOrBelowStrike() public {
        CalderaTypes.SeriesInput memory input = defaultCallInput();
        input.capPriceX18 = input.strikePriceX18;

        vm.expectRevert(
            abi.encodeWithSelector(
                CalderaErrors.InvalidCap.selector,
                uint256(input.strikePriceX18),
                uint256(input.capPriceX18)
            )
        );
        protocol.createSeries(input);
    }

    function testSeriesTransitionsAcrossScheduledFundingExerciseAndExpiredPhases() public {
        CalderaTypes.SeriesInput memory input = defaultCallInput();
        input.saleStart = uint64(block.timestamp + 1 days);
        input.saleEnd = uint64(block.timestamp + 4 days);
        input.exerciseStart = input.saleEnd;
        input.expiry = uint64(block.timestamp + 8 days);

        uint64 seriesId = protocol.createSeries(input);
        assertEq(uint8(seriesController.phase(seriesId)), uint8(CalderaTypes.SeriesPhase.Scheduled));

        vm.warp(input.saleStart);
        assertEq(uint8(seriesController.phase(seriesId)), uint8(CalderaTypes.SeriesPhase.Funding));

        vm.warp(input.exerciseStart);
        assertEq(uint8(seriesController.phase(seriesId)), uint8(CalderaTypes.SeriesPhase.Exercise));

        vm.warp(input.expiry);
        assertEq(uint8(seriesController.phase(seriesId)), uint8(CalderaTypes.SeriesPhase.Expired));
    }

    function testWritingCreatesInventoryAndPurchasingConsumesIt() public {
        uint64 seriesId = _createCallSeries();

        uint256 positionId = _write(seriesId, writer, 10);
        assertEq(writerPosition.ownerOf(positionId), writer);
        assertEq(seriesController.availableInventory(seriesId), 10);
        assertEq(collateralVault.reserveBySeries(seriesId), 10_000 * USDC);

        uint256 premiumPaid = _buy(seriesId, buyer, 4);
        CalderaTypes.SeriesAccounting memory accounting = seriesController.accountingOf(seriesId);

        assertGt(premiumPaid, 0);
        assertEq(optionToken.balanceOf(buyer, seriesId), 4);
        assertEq(optionToken.totalSupply(seriesId), 4);
        assertEq(seriesController.availableInventory(seriesId), 6);
        assertEq(accounting.writtenContracts, 10);
        assertEq(accounting.soldContracts, 4);
        assertEq(accounting.grossPremium, premiumPaid);
        assertEq(
            premiumEscrow.escrowedPremiumBySeries(seriesId)
                + premiumEscrow.feesByAsset(address(usdc)),
            premiumPaid
        );
    }

    function testPurchaseCannotExceedWrittenInventory() public {
        uint64 seriesId = _createCallSeries();
        _write(seriesId, writer, 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                CalderaErrors.InsufficientInventory.selector, seriesId, uint256(2), uint256(3)
            )
        );
        vm.prank(buyer);
        protocol.buyOptions(seriesId, 3, buyer, type(uint256).max);

        assertEq(seriesController.availableInventory(seriesId), 2);
        assertEq(optionToken.balanceOf(buyer, seriesId), 0);
    }

    function testSaleWindowIncludesStartAndExcludesEnd() public {
        CalderaTypes.SeriesInput memory input = defaultCallInput();
        input.saleStart = uint64(block.timestamp + 1 days);
        input.saleEnd = uint64(block.timestamp + 3 days);
        input.exerciseStart = input.saleEnd;
        input.expiry = uint64(block.timestamp + 7 days);
        uint64 seriesId = protocol.createSeries(input);

        vm.expectRevert(
            abi.encodeWithSelector(CalderaErrors.SaleNotOpen.selector, seriesId, block.timestamp)
        );
        vm.prank(writer);
        protocol.writeOptions(seriesId, 2, writer, type(uint256).max);

        vm.warp(input.saleStart);
        _write(seriesId, writer, 2);

        vm.warp(uint256(input.saleEnd) - 1);
        _buy(seriesId, buyer, 1);

        vm.warp(input.saleEnd);
        vm.expectRevert(
            abi.encodeWithSelector(CalderaErrors.SaleNotOpen.selector, seriesId, block.timestamp)
        );
        vm.prank(buyer);
        protocol.buyOptions(seriesId, 1, buyer, type(uint256).max);
    }

    function testOnlyGovernorCanCreateSeries() public {
        bytes32 governorRole = accessController.GOVERNOR_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(CalderaErrors.Unauthorized.selector, governorRole, buyer)
        );
        vm.prank(buyer);
        protocol.createSeries(defaultCallInput());
    }

    function testGuardianPauseStopsCreationUntilGovernorUnpauses() public {
        accessController.pause();
        assertTrue(accessController.paused());

        vm.expectRevert(CalderaErrors.ProtocolPaused.selector);
        protocol.createSeries(defaultCallInput());

        accessController.unpause();
        assertFalse(accessController.paused());
        assertEq(protocol.createSeries(defaultCallInput()), 1);
    }

    function testOracleManagerRoleIsRequiredForPriceSubmission() public {
        bytes32 oracleRole = accessController.ORACLE_MANAGER_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(CalderaErrors.Unauthorized.selector, oracleRole, buyer)
        );
        vm.prank(buyer);
        oracleRouter.submitPrice(ETH_USD, 2300e18, uint64(block.timestamp), oracleSequence + 1);
    }

    function testOracleRejectsNonIncreasingSequence() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CalderaErrors.OracleSequenceNotIncreasing.selector,
                ETH_USD,
                oracleSequence,
                oracleSequence
            )
        );
        oracleRouter.submitPrice(ETH_USD, 2300e18, uint64(block.timestamp), oracleSequence);
    }

    function testSeriesCreationRejectsStaleOraclePrice() public {
        CalderaTypes.SeriesInput memory input = defaultCallInput();
        input.maxOracleAge = uint32(1 days);
        vm.warp(block.timestamp + 1 days + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                CalderaErrors.StaleOraclePrice.selector, ETH_USD, START_TIME, uint256(1 days)
            )
        );
        protocol.createSeries(input);
    }
}
