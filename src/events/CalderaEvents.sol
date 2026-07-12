// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { CalderaTypes } from "../types/CalderaTypes.sol";

abstract contract CalderaEvents {
    event ProtocolPaused(address indexed account);
    event ProtocolResumed(address indexed account);

    event SeriesCreated(
        uint64 indexed seriesId,
        bytes32 indexed underlyingId,
        address indexed collateralAsset,
        CalderaTypes.OptionType optionType,
        uint256 strikePriceX18,
        uint256 capPriceX18,
        uint256 collateralPerContract,
        uint256 expiry
    );

    event OptionsWritten(
        uint64 indexed seriesId,
        uint256 indexed positionId,
        address indexed writer,
        address receiver,
        uint256 contracts,
        uint256 collateral
    );

    event OptionsPurchased(
        uint64 indexed seriesId,
        address indexed buyer,
        address indexed receiver,
        uint256 contracts,
        uint256 premium,
        uint256 fee
    );

    event PremiumClaimed(
        uint64 indexed seriesId,
        uint256 indexed positionId,
        address indexed owner,
        address recipient,
        uint256 amount
    );

    event ExerciseRequested(
        uint256 indexed requestId,
        uint64 indexed seriesId,
        address indexed requester,
        address recipient,
        uint256 contracts,
        uint256 priceX18,
        uint256 payout,
        uint256 executableAt
    );

    event ExerciseProcessed(
        uint256 indexed requestId,
        uint64 indexed seriesId,
        address indexed processor,
        address recipient,
        uint256 contracts,
        uint256 payout,
        uint256 reserveDebit,
        uint256 liquidityDebit
    );

    event WriterPositionSettled(
        uint64 indexed seriesId,
        uint256 indexed positionId,
        address indexed owner,
        address recipient,
        uint256 recognizedLoss,
        uint256 collateralReturned,
        uint256 premiumPaid
    );

    event ProtocolFeesWithdrawn(address indexed asset, address indexed recipient, uint256 amount);
}
