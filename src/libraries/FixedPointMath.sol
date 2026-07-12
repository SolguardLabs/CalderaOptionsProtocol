// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { CalderaErrors } from "../errors/CalderaErrors.sol";

library FixedPointMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q128 = 1 << 128;

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a - b : b - a;
    }

    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) revert CalderaErrors.InvalidConfiguration();
        if (a == 0) return 0;
        return ((a - 1) / b) + 1;
    }

    function mulWadDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return mulDiv(a, b, WAD);
    }

    function mulWadUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return mulDivUp(a, b, WAD);
    }

    function divWadDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return mulDiv(a, WAD, b);
    }

    function bpsMulDown(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return mulDiv(amount, bps, BPS);
    }

    function bpsMulUp(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return mulDivUp(amount, bps, BPS);
    }

    function toQ128(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        return mulDiv(numerator, Q128, denominator);
    }

    function fromQ128(uint256 shares, uint256 indexX128) internal pure returns (uint256) {
        return mulDiv(shares, indexX128, Q128);
    }

    function scaleFromWad(uint256 amountX18, uint8 decimals) internal pure returns (uint256) {
        if (decimals > 18) revert CalderaErrors.UnsupportedDecimals(decimals);
        return amountX18 / (10 ** (18 - decimals));
    }

    function scaleFromWadUp(uint256 amountX18, uint8 decimals) internal pure returns (uint256) {
        if (decimals > 18) revert CalderaErrors.UnsupportedDecimals(decimals);
        return ceilDiv(amountX18, 10 ** (18 - decimals));
    }

    function scaleToWad(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals > 18) revert CalderaErrors.UnsupportedDecimals(decimals);
        return amount * (10 ** (18 - decimals));
    }

    /// @notice Full precision floor(x * y / denominator).
    function mulDiv(uint256 x, uint256 y, uint256 denominator)
        internal
        pure
        returns (uint256 result)
    {
        if (denominator == 0) revert CalderaErrors.InvalidConfiguration();

        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly ("memory-safe") {
                let mm := mulmod(x, y, not(0))
                prod0 := mul(x, y)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            if (prod1 == 0) return prod0 / denominator;
            if (denominator <= prod1) revert CalderaErrors.AccountingOverflow();

            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(x, y, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = denominator & (0 - denominator);
            assembly ("memory-safe") {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            result = prod0 * inverse;
        }
    }

    function mulDivUp(uint256 x, uint256 y, uint256 denominator)
        internal
        pure
        returns (uint256 result)
    {
        result = mulDiv(x, y, denominator);
        if (mulmod(x, y, denominator) != 0) {
            if (result == type(uint256).max) revert CalderaErrors.AccountingOverflow();
            result += 1;
        }
    }
}
