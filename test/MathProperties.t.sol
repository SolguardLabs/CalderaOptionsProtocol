// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { CalderaTypes } from "../src/types/CalderaTypes.sol";
import { OptionMath } from "../src/libraries/OptionMath.sol";
import { FixedPointMath } from "../src/libraries/FixedPointMath.sol";

contract MathPropertiesTest is Test {
    uint256 private constant WAD = 1e18;

    function testFuzzCallPayoutNeverExceedsMaximum(uint192 rawSpot, uint128 rawSize) public pure {
        uint256 spot = bound(uint256(rawSpot), 1, 20_000e18);
        uint256 size = bound(uint256(rawSize), 1e15, 100e18);
        uint256 payout = OptionMath.payoutPerContract(
            CalderaTypes.OptionType.Call, spot, 2000e18, 3000e18, size, 6
        );
        uint256 maximum = OptionMath.maximumPayoutPerContract(
            CalderaTypes.OptionType.Call, 2000e18, 3000e18, size, 6
        );
        assertLe(payout, maximum);
    }

    function testFuzzPutPayoutNeverExceedsMaximum(uint192 rawSpot, uint128 rawSize) public pure {
        uint256 spot = bound(uint256(rawSpot), 1, 20_000e18);
        uint256 size = bound(uint256(rawSize), 1e15, 100e18);
        uint256 payout =
            OptionMath.payoutPerContract(CalderaTypes.OptionType.Put, spot, 2000e18, 0, size, 6);
        uint256 maximum =
            OptionMath.maximumPayoutPerContract(CalderaTypes.OptionType.Put, 2000e18, 0, size, 6);
        assertLe(payout, maximum);
    }

    function testFuzzUtilizationIsBoundedForValidInventory(uint128 written, uint128 sold)
        public
        pure
    {
        written = uint128(bound(written, 1, type(uint128).max));
        sold = uint128(bound(sold, 0, written));
        uint256 utilization = OptionMath.utilizationX18(sold, written);
        assertLe(utilization, WAD);
    }

    function testFuzzScaleRoundTripDoesNotCreateValue(uint128 rawAmount, uint8 rawDecimals)
        public
        pure
    {
        uint8 decimals = uint8(bound(rawDecimals, 0, 18));
        uint256 amountX18 = bound(uint256(rawAmount), 0, type(uint128).max);
        uint256 scaled = FixedPointMath.scaleFromWad(amountX18, decimals);
        uint256 restored = FixedPointMath.scaleToWad(scaled, decimals);
        assertLe(restored, amountX18);
        assertLt(amountX18 - restored, 10 ** (18 - decimals));
    }
}
