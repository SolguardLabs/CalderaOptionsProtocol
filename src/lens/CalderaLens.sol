// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { CalderaOptionsProtocol } from "../CalderaOptionsProtocol.sol";
import { CalderaTypes } from "../types/CalderaTypes.sol";

/// @title CalderaLens
/// @notice Read-only aggregation for interfaces, keepers, and risk monitoring.
contract CalderaLens {
    struct WriterSnapshot {
        uint256 positionId;
        address owner;
        CalderaTypes.WriterPositionData position;
        uint256 claimablePremium;
        uint256 recognizedLoss;
        uint256 collateralRefund;
    }

    struct AssetSnapshot {
        CalderaTypes.AssetConfig config;
        CalderaTypes.AssetSolvency collateral;
        uint256 premiumEscrow;
        uint256 feeEscrow;
        uint256 escrowPhysicalBalance;
    }

    CalderaOptionsProtocol public immutable protocol;

    constructor(address protocol_) {
        protocol = CalderaOptionsProtocol(protocol_);
    }

    function seriesSnapshot(uint64 seriesId)
        external
        view
        returns (CalderaTypes.SeriesSnapshot memory result)
    {
        (
            CalderaTypes.SeriesConfig memory config,
            CalderaTypes.SeriesAccounting memory accounting,
            CalderaTypes.SeriesPhase phase
        ) = protocol.seriesController().getSeries(seriesId);
        (uint256 pendingCount, uint256 pendingPayout) =
            protocol.exerciseQueue().pendingStats(seriesId);

        result = CalderaTypes.SeriesSnapshot({
            seriesId: seriesId,
            phase: phase,
            config: config,
            accounting: accounting,
            liveLongSupply: protocol.optionToken().totalSupply(seriesId),
            availableInventory: uint256(accounting.writtenContracts) - accounting.soldContracts,
            vaultReserve: protocol.collateralVault().reserveBySeries(seriesId),
            pendingRequests: pendingCount,
            pendingPayout: pendingPayout
        });
    }

    function writerSnapshot(uint256 positionId)
        external
        view
        returns (WriterSnapshot memory result)
    {
        CalderaTypes.WriterPositionData memory position =
            protocol.writerPosition().getPosition(positionId);
        CalderaTypes.SeriesAccounting memory accounting =
            protocol.seriesController().accountingOf(position.seriesId);
        uint256 premium =
            protocol.writerPosition().claimablePremium(positionId, accounting.premiumIndexX128);
        uint256 loss;
        uint256 refund;
        if (position.status == CalderaTypes.PositionStatus.Active) {
            (refund, loss) =
                protocol.writerPosition().settlementPreview(positionId, accounting.lossIndexX128);
        } else {
            loss = position.lossRecognized;
            refund = position.collateral - loss;
        }
        result = WriterSnapshot({
            positionId: positionId,
            owner: protocol.writerPosition().ownerOf(positionId),
            position: position,
            claimablePremium: premium,
            recognizedLoss: loss,
            collateralRefund: refund
        });
    }

    function assetSnapshot(address asset) external view returns (AssetSnapshot memory result) {
        result = AssetSnapshot({
            config: protocol.assetRegistry().getAssetConfig(asset),
            collateral: protocol.collateralVault().solvency(asset),
            premiumEscrow: protocol.premiumEscrow().escrowedPremiumByAsset(asset),
            feeEscrow: protocol.premiumEscrow().feesByAsset(asset),
            escrowPhysicalBalance: protocol.premiumEscrow().physicalBalance(asset)
        });
    }

    function exercisePage(uint64 seriesId, uint256 cursor, uint256 size)
        external
        view
        returns (CalderaTypes.ExerciseRequest[] memory requests, uint256 nextCursor)
    {
        return protocol.exerciseQueue().requestPageBySeries(seriesId, cursor, size);
    }

    function protocolCounts()
        external
        view
        returns (
            uint256 seriesCount,
            uint256 writerPositionCount,
            uint256 exerciseRequestCount,
            uint256 pendingRequestCount,
            uint256 pendingPayout
        )
    {
        seriesCount = protocol.seriesController().seriesCount();
        writerPositionCount = protocol.writerPosition().totalSupply();
        exerciseRequestCount = protocol.exerciseQueue().requestCount();
        pendingRequestCount = protocol.exerciseQueue().totalPendingCount();
        pendingPayout = protocol.exerciseQueue().totalPendingPayout();
    }
}
