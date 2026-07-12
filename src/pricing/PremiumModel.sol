// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { AccessManaged } from "../utils/AccessManaged.sol";
import { CalderaTypes } from "../types/CalderaTypes.sol";
import { CalderaErrors } from "../errors/CalderaErrors.sol";
import { FixedPointMath } from "../libraries/FixedPointMath.sol";
import { OptionMath } from "../libraries/OptionMath.sol";

/// @title PremiumModel
/// @notice Deterministic premium curve based on intrinsic value, time remaining, and utilization.
contract PremiumModel is AccessManaged {
    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;

    struct PricingParameters {
        uint16 minimumPremiumBps;
        uint16 timeValueBps;
        uint16 utilizationValueBps;
    }

    PricingParameters public pricingParameters;

    event PricingParametersUpdated(
        uint16 minimumPremiumBps, uint16 timeValueBps, uint16 utilizationValueBps
    );

    constructor(address accessController_) AccessManaged(accessController_) {
        pricingParameters = PricingParameters({
            minimumPremiumBps: 25, timeValueBps: 500, utilizationValueBps: 2000
        });
        emit PricingParametersUpdated(25, 500, 2000);
    }

    function setPricingParameters(
        uint16 minimumPremiumBps,
        uint16 timeValueBps,
        uint16 utilizationValueBps
    ) external onlyRole(accessController.GOVERNOR_ROLE()) {
        if (uint256(minimumPremiumBps) + uint256(timeValueBps) + uint256(utilizationValueBps) > BPS)
        {
            revert CalderaErrors.InvalidConfiguration();
        }

        pricingParameters = PricingParameters({
            minimumPremiumBps: minimumPremiumBps,
            timeValueBps: timeValueBps,
            utilizationValueBps: utilizationValueBps
        });
        emit PricingParametersUpdated(minimumPremiumBps, timeValueBps, utilizationValueBps);
    }

    /// @notice Quotes a purchase using the current block timestamp.
    function quote(
        CalderaTypes.SeriesConfig calldata config,
        CalderaTypes.SeriesAccounting calldata accounting,
        uint256 spotPriceX18,
        uint256 contracts
    ) external view returns (CalderaTypes.PremiumQuote memory) {
        return _quote(config, accounting, spotPriceX18, contracts, block.timestamp);
    }

    /// @notice Quotes at an explicit timestamp for deterministic simulation and testing.
    function quoteAtTimestamp(
        CalderaTypes.SeriesConfig calldata config,
        CalderaTypes.SeriesAccounting calldata accounting,
        uint256 spotPriceX18,
        uint256 contracts,
        uint256 timestamp
    ) external view returns (CalderaTypes.PremiumQuote memory) {
        return _quote(config, accounting, spotPriceX18, contracts, timestamp);
    }

    function _quote(
        CalderaTypes.SeriesConfig calldata config,
        CalderaTypes.SeriesAccounting calldata accounting,
        uint256 spotPriceX18,
        uint256 contracts,
        uint256 timestamp
    ) internal view returns (CalderaTypes.PremiumQuote memory result) {
        if (contracts == 0) revert CalderaErrors.ZeroAmount();
        if (spotPriceX18 == 0) {
            revert CalderaErrors.InvalidOraclePrice(config.underlyingId, spotPriceX18);
        }
        if (config.collateralPerContract == 0) revert CalderaErrors.InvalidConfiguration();
        if (config.feeBps > BPS) revert CalderaErrors.InvalidFee(config.feeBps);

        PricingParameters memory parameters = pricingParameters;
        uint256 collateral = config.collateralPerContract;
        result.intrinsicPerContract = OptionMath.payoutPerContract(
            config.optionType,
            spotPriceX18,
            config.strikePriceX18,
            config.capPriceX18,
            config.contractSizeX18,
            config.collateralDecimals
        );
        result.intrinsicPerContract = FixedPointMath.min(result.intrinsicPerContract, collateral);

        uint256 remainingX18 =
            OptionMath.timeRemainingX18(timestamp, config.saleStart, config.expiry);
        uint256 variableTimeBps = FixedPointMath.mulDiv(parameters.timeValueBps, remainingX18, WAD);
        result.timeValuePerContract = FixedPointMath.bpsMulDown(
            collateral, uint256(parameters.minimumPremiumBps) + variableTimeBps
        );

        uint256 utilizationX18 = OptionMath.utilizationX18(
            uint256(accounting.soldContracts) + contracts, accounting.writtenContracts
        );
        utilizationX18 = FixedPointMath.min(utilizationX18, WAD);
        uint256 maximumUtilizationValue =
            FixedPointMath.bpsMulDown(collateral, parameters.utilizationValueBps);
        result.utilizationValuePerContract =
            FixedPointMath.mulWadDown(maximumUtilizationValue, utilizationX18);

        result.premiumPerContract = FixedPointMath.min(
            collateral,
            result.intrinsicPerContract + result.timeValuePerContract
                + result.utilizationValuePerContract
        );
        result.totalPremium = FixedPointMath.mulDiv(result.premiumPerContract, contracts, 1);
        result.feeAmount = FixedPointMath.bpsMulDown(result.totalPremium, config.feeBps);
        result.writerAmount = result.totalPremium - result.feeAmount;
    }
}
