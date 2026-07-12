// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { CalderaTypes } from "../types/CalderaTypes.sol";
import { CalderaErrors } from "../errors/CalderaErrors.sol";
import { FixedPointMath } from "./FixedPointMath.sol";

library OptionMath {
    using FixedPointMath for uint256;

    uint256 internal constant WAD = 1e18;

    function intrinsicPriceX18(
        CalderaTypes.OptionType optionType,
        uint256 spotPriceX18,
        uint256 strikePriceX18,
        uint256 capPriceX18
    ) internal pure returns (uint256) {
        if (optionType == CalderaTypes.OptionType.Call) {
            uint256 effectiveSpot = FixedPointMath.min(spotPriceX18, capPriceX18);
            return effectiveSpot > strikePriceX18 ? effectiveSpot - strikePriceX18 : 0;
        }

        return strikePriceX18 > spotPriceX18 ? strikePriceX18 - spotPriceX18 : 0;
    }

    function maximumPriceX18(
        CalderaTypes.OptionType optionType,
        uint256 strikePriceX18,
        uint256 capPriceX18
    ) internal pure returns (uint256) {
        if (optionType == CalderaTypes.OptionType.Call) {
            if (capPriceX18 <= strikePriceX18) {
                revert CalderaErrors.InvalidCap(strikePriceX18, capPriceX18);
            }
            return capPriceX18 - strikePriceX18;
        }
        return strikePriceX18;
    }

    function payoutPerContract(
        CalderaTypes.OptionType optionType,
        uint256 spotPriceX18,
        uint256 strikePriceX18,
        uint256 capPriceX18,
        uint256 contractSizeX18,
        uint8 collateralDecimals
    ) internal pure returns (uint256) {
        uint256 intrinsicX18 = intrinsicPriceX18(
            optionType, spotPriceX18, strikePriceX18, capPriceX18
        );
        uint256 quoteAmountX18 = FixedPointMath.mulDiv(intrinsicX18, contractSizeX18, WAD);
        return FixedPointMath.scaleFromWad(quoteAmountX18, collateralDecimals);
    }

    function maximumPayoutPerContract(
        CalderaTypes.OptionType optionType,
        uint256 strikePriceX18,
        uint256 capPriceX18,
        uint256 contractSizeX18,
        uint8 collateralDecimals
    ) internal pure returns (uint256) {
        uint256 maximumX18 = maximumPriceX18(optionType, strikePriceX18, capPriceX18);
        uint256 quoteAmountX18 = FixedPointMath.mulDivUp(maximumX18, contractSizeX18, WAD);
        return FixedPointMath.scaleFromWadUp(quoteAmountX18, collateralDecimals);
    }

    function totalPayout(uint256 payoutPerOption, uint256 contracts)
        internal
        pure
        returns (uint256)
    {
        if (contracts == 0) revert CalderaErrors.ZeroAmount();
        return payoutPerOption * contracts;
    }

    function utilizationX18(uint256 soldContracts, uint256 writtenContracts)
        internal
        pure
        returns (uint256)
    {
        if (writtenContracts == 0) return 0;
        return FixedPointMath.mulDiv(soldContracts, WAD, writtenContracts);
    }

    function timeRemainingX18(uint256 nowTimestamp, uint256 saleStart, uint256 expiry)
        internal
        pure
        returns (uint256)
    {
        if (nowTimestamp >= expiry) return 0;
        if (expiry <= saleStart) revert CalderaErrors.InvalidSeriesWindow();
        uint256 totalWindow = expiry - saleStart;
        uint256 remaining = expiry - FixedPointMath.max(nowTimestamp, saleStart);
        return FixedPointMath.mulDiv(remaining, WAD, totalWindow);
    }

    function boundedPayout(uint256 payout, uint256 contracts, uint256 collateralPerContract)
        internal
        pure
        returns (uint256)
    {
        uint256 maximum = collateralPerContract * contracts;
        return FixedPointMath.min(payout, maximum);
    }
}
