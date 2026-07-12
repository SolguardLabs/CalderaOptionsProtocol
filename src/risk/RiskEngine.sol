// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { AccessManaged } from "../utils/AccessManaged.sol";
import { CalderaTypes } from "../types/CalderaTypes.sol";
import { CalderaErrors } from "../errors/CalderaErrors.sol";
import { FixedPointMath } from "../libraries/FixedPointMath.sol";
import { OptionMath } from "../libraries/OptionMath.sol";

/// @title RiskEngine
/// @notice Validates option-series parameters and derives fully collateralized cash-settlement
/// risk. @dev Every supported option has a finite payout. Calls are capped at `capPriceX18`; puts
/// are
///      naturally capped by their strike because the underlying price cannot settle below zero.
contract RiskEngine is AccessManaged {
    uint256 private constant BPS = 10_000;

    constructor(address accessController_) AccessManaged(accessController_) { }

    /// @notice Validates input and converts it into the immutable configuration stored for a
    /// series.
    function validateAndBuild(
        CalderaTypes.SeriesInput calldata input,
        CalderaTypes.AssetConfig calldata assetConfig
    ) external pure returns (CalderaTypes.SeriesConfig memory config) {
        _validateInput(input);
        _validateAsset(input.collateralAsset, assetConfig);

        uint256 requiredCollateral = _collateralPerContract(input, assetConfig.decimals);
        uint256 assetDepositCap =
            uint256(assetConfig.depositCap) * (10 ** uint256(assetConfig.decimals));

        if (requiredCollateral > assetDepositCap) {
            revert CalderaErrors.CollateralAboveLimit(requiredCollateral, assetDepositCap);
        }
        if (requiredCollateral > type(uint128).max) revert CalderaErrors.AccountingOverflow();

        config = CalderaTypes.SeriesConfig({
            collateralAsset: input.collateralAsset,
            underlyingId: input.underlyingId,
            optionType: input.optionType,
            saleStart: input.saleStart,
            saleEnd: input.saleEnd,
            exerciseStart: input.exerciseStart,
            expiry: input.expiry,
            settlementDelay: input.settlementDelay,
            maxOracleAge: input.maxOracleAge,
            strikePriceX18: input.strikePriceX18,
            capPriceX18: input.capPriceX18,
            contractSizeX18: input.contractSizeX18,
            collateralPerContract: uint128(requiredCollateral),
            feeBps: input.feeBps,
            collateralDecimals: assetConfig.decimals
        });
    }

    /// @notice Validates the structural rules for an input independently of an asset registry.
    function validateSeriesInput(CalderaTypes.SeriesInput calldata input) external pure {
        _validateInput(input);
    }

    /// @notice Returns the maximum collateral required to write one contract.
    function collateralPerContract(
        CalderaTypes.SeriesInput calldata input,
        uint8 collateralDecimals
    ) external pure returns (uint256) {
        _validateInput(input);
        if (collateralDecimals > 18) {
            revert CalderaErrors.UnsupportedDecimals(collateralDecimals);
        }
        return _collateralPerContract(input, collateralDecimals);
    }

    /// @notice Returns the maximum collateral required to write `contracts` contracts.
    function collateralForContracts(CalderaTypes.SeriesConfig calldata config, uint256 contracts)
        external
        pure
        returns (uint256)
    {
        if (contracts == 0) revert CalderaErrors.ZeroAmount();
        if (config.collateralPerContract == 0) revert CalderaErrors.InvalidConfiguration();
        return FixedPointMath.mulDiv(config.collateralPerContract, contracts, 1);
    }

    /// @notice Calculates the cash payout per contract at a settlement price.
    function exercisePayoutPerContract(
        CalderaTypes.SeriesConfig calldata config,
        uint256 spotPriceX18
    ) public pure returns (uint256) {
        if (spotPriceX18 == 0) {
            revert CalderaErrors.InvalidOraclePrice(config.underlyingId, spotPriceX18);
        }
        if (config.collateralPerContract == 0) revert CalderaErrors.InvalidConfiguration();

        uint256 payout = OptionMath.payoutPerContract(
            config.optionType,
            spotPriceX18,
            config.strikePriceX18,
            config.capPriceX18,
            config.contractSizeX18,
            config.collateralDecimals
        );

        // The stored collateral is the final authority even if a malformed legacy configuration
        // is passed into this view function.
        return FixedPointMath.min(payout, config.collateralPerContract);
    }

    /// @notice Calculates the capped cash payout for an exercised quantity.
    function exercisePayout(
        CalderaTypes.SeriesConfig calldata config,
        uint256 spotPriceX18,
        uint256 contracts
    ) external pure returns (uint256) {
        if (contracts == 0) revert CalderaErrors.ZeroAmount();

        uint256 perContract = exercisePayoutPerContract(config, spotPriceX18);
        return FixedPointMath.mulDiv(perContract, contracts, 1);
    }

    /// @notice Returns the intrinsic settlement price before contract-size and decimal conversion.
    function intrinsicPriceX18(CalderaTypes.SeriesConfig calldata config, uint256 spotPriceX18)
        external
        pure
        returns (uint256)
    {
        if (spotPriceX18 == 0) {
            revert CalderaErrors.InvalidOraclePrice(config.underlyingId, spotPriceX18);
        }
        return OptionMath.intrinsicPriceX18(
            config.optionType, spotPriceX18, config.strikePriceX18, config.capPriceX18
        );
    }

    function _validateInput(CalderaTypes.SeriesInput calldata input) internal pure {
        if (input.collateralAsset == address(0)) revert CalderaErrors.ZeroAddress();
        if (input.underlyingId == bytes32(0)) revert CalderaErrors.InvalidConfiguration();

        if (
            input.saleStart >= input.saleEnd || input.saleEnd > input.exerciseStart
                || input.exerciseStart >= input.expiry
        ) {
            revert CalderaErrors.InvalidSeriesWindow();
        }

        if (input.strikePriceX18 == 0) {
            revert CalderaErrors.InvalidStrike(input.strikePriceX18);
        }
        if (
            input.optionType == CalderaTypes.OptionType.Call
                && input.capPriceX18 <= input.strikePriceX18
        ) {
            revert CalderaErrors.InvalidCap(input.strikePriceX18, input.capPriceX18);
        }
        if (input.contractSizeX18 == 0) {
            revert CalderaErrors.InvalidContractSize(input.contractSizeX18);
        }
        if (
            input.settlementDelay == 0
                || uint256(input.settlementDelay) > input.expiry - input.exerciseStart
        ) {
            revert CalderaErrors.InvalidSettlementDelay(input.settlementDelay);
        }
        if (input.maxOracleAge == 0) {
            revert CalderaErrors.InvalidOracleAge(input.maxOracleAge);
        }
        if (input.feeBps > BPS) revert CalderaErrors.InvalidFee(input.feeBps);
    }

    function _validateAsset(address collateralAsset, CalderaTypes.AssetConfig calldata assetConfig)
        internal
        pure
    {
        if (!assetConfig.enabled) revert CalderaErrors.AssetDisabled(collateralAsset);
        if (assetConfig.decimals > 18) {
            revert CalderaErrors.UnsupportedDecimals(assetConfig.decimals);
        }
        if (assetConfig.symbol == bytes32(0) || assetConfig.depositCap == 0) {
            revert CalderaErrors.InvalidConfiguration();
        }
    }

    function _collateralPerContract(
        CalderaTypes.SeriesInput calldata input,
        uint8 collateralDecimals
    ) internal pure returns (uint256) {
        uint256 collateral = OptionMath.maximumPayoutPerContract(
            input.optionType,
            input.strikePriceX18,
            input.capPriceX18,
            input.contractSizeX18,
            collateralDecimals
        );
        if (collateral == 0) revert CalderaErrors.InvalidContractSize(input.contractSizeX18);
        return collateral;
    }
}
