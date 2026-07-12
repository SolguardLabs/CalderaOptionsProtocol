// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { AccessManaged } from "../utils/AccessManaged.sol";
import { CalderaTypes } from "../types/CalderaTypes.sol";
import { CalderaErrors } from "../errors/CalderaErrors.sol";
import { FixedPointMath } from "../libraries/FixedPointMath.sol";
import { OptionMath } from "../libraries/OptionMath.sol";

/// @title SettlementEngine
/// @notice Stateless settlement calculations shared by the protocol and read clients.
contract SettlementEngine is AccessManaged {
    uint256 private constant Q128 = 1 << 128;

    constructor(address accessController_) AccessManaged(accessController_) { }

    function preview(
        uint256 requestId,
        CalderaTypes.ExerciseRequest calldata request,
        CalderaTypes.SeriesConfig calldata config,
        CalderaTypes.SeriesAccounting calldata accounting,
        uint256 reserveBefore
    ) external pure returns (CalderaTypes.SettlementPreview memory result) {
        if (
            requestId == 0 || request.seriesId == 0
                || request.status != CalderaTypes.RequestStatus.Processing || request.contracts == 0
                || request.payout == 0 || request.exercisePriceX18 == 0
                || request.recipient == address(0) || config.collateralAsset == address(0)
        ) revert CalderaErrors.InvalidSettlement(requestId);

        uint256 payoutPerContract = OptionMath.payoutPerContract(
            config.optionType,
            request.exercisePriceX18,
            config.strikePriceX18,
            config.capPriceX18,
            config.contractSizeX18,
            config.collateralDecimals
        );
        payoutPerContract = FixedPointMath.min(payoutPerContract, config.collateralPerContract);
        uint256 expectedPayout = payoutPerContract * request.contracts;
        if (request.payout != expectedPayout) {
            revert CalderaErrors.InvalidSettlement(requestId);
        }
        if (
            accounting.writtenContracts == 0
                || uint256(accounting.settledContracts) + request.contracts
                    > accounting.soldContracts
        ) revert CalderaErrors.InvalidSettlement(requestId);

        (uint256 reserveDebit, uint256 liquidityDebit) = splitReserve(request.payout, reserveBefore);
        (uint256 indexDelta,) = lossIndexDelta(
            request.payout, accounting.writtenContracts, accounting.lossRemainderX128
        );

        result = CalderaTypes.SettlementPreview({
            requestId: requestId,
            seriesId: request.seriesId,
            collateralAsset: config.collateralAsset,
            recipient: request.recipient,
            contracts: request.contracts,
            payout: request.payout,
            reserveBefore: reserveBefore,
            reserveDebit: reserveDebit,
            liquidityDebit: liquidityDebit,
            lossIndexDeltaX128: indexDelta
        });
    }

    function lossIndexDelta(uint256 payout, uint128 shares, uint256 carriedRemainder)
        public
        pure
        returns (uint256 indexDeltaX128, uint256 nextRemainderX128)
    {
        if (shares == 0) revert CalderaErrors.InvalidConfiguration();
        uint256 denominator = uint256(shares);
        if (carriedRemainder >= denominator) revert CalderaErrors.InvalidConfiguration();

        indexDeltaX128 = FixedPointMath.mulDiv(payout, Q128, denominator);
        uint256 remainder = mulmod(payout, Q128, denominator) + carriedRemainder;
        if (remainder >= denominator) {
            if (indexDeltaX128 == type(uint256).max) {
                revert CalderaErrors.AccountingOverflow();
            }
            indexDeltaX128 += 1;
            remainder -= denominator;
        }
        nextRemainderX128 = remainder;
    }

    function splitReserve(uint256 payout, uint256 reserveBefore)
        public
        pure
        returns (uint256 reserveDebit, uint256 liquidityDebit)
    {
        reserveDebit = FixedPointMath.min(payout, reserveBefore);
        liquidityDebit = payout - reserveDebit;
    }
}
