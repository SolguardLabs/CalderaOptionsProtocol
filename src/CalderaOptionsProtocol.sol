// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { CalderaTypes } from "./types/CalderaTypes.sol";
import { CalderaErrors } from "./errors/CalderaErrors.sol";
import { CalderaEvents } from "./events/CalderaEvents.sol";
import { ReentrancyGuard } from "./utils/ReentrancyGuard.sol";
import { CalderaAccessController } from "./access/CalderaAccessController.sol";
import { AssetRegistry } from "./assets/AssetRegistry.sol";
import { OracleRouter } from "./oracle/OracleRouter.sol";
import { RiskEngine } from "./risk/RiskEngine.sol";
import { PremiumModel } from "./pricing/PremiumModel.sol";
import { SeriesController } from "./core/SeriesController.sol";
import { CollateralVault } from "./core/CollateralVault.sol";
import { PremiumEscrow } from "./core/PremiumEscrow.sol";
import { ExerciseQueue } from "./core/ExerciseQueue.sol";
import { SettlementEngine } from "./core/SettlementEngine.sol";
import { OptionToken } from "./token/OptionToken.sol";
import { WriterPosition } from "./token/WriterPosition.sol";

/// @title CalderaOptionsProtocol
/// @notice Entry point for collateralized option issuance, trading, and cash settlement.
contract CalderaOptionsProtocol is CalderaEvents, ReentrancyGuard {
    struct Components {
        address accessController;
        address assetRegistry;
        address oracleRouter;
        address riskEngine;
        address premiumModel;
        address seriesController;
        address collateralVault;
        address premiumEscrow;
        address exerciseQueue;
        address settlementEngine;
        address optionToken;
        address writerPosition;
    }

    CalderaAccessController public immutable accessController;
    AssetRegistry public immutable assetRegistry;
    OracleRouter public immutable oracleRouter;
    RiskEngine public immutable riskEngine;
    PremiumModel public immutable premiumModel;
    SeriesController public immutable seriesController;
    CollateralVault public immutable collateralVault;
    PremiumEscrow public immutable premiumEscrow;
    ExerciseQueue public immutable exerciseQueue;
    SettlementEngine public immutable settlementEngine;
    OptionToken public immutable optionToken;
    WriterPosition public immutable writerPosition;

    constructor(Components memory components) {
        if (
            components.accessController == address(0) || components.assetRegistry == address(0)
                || components.oracleRouter == address(0) || components.riskEngine == address(0)
                || components.premiumModel == address(0)
                || components.seriesController == address(0)
                || components.collateralVault == address(0)
                || components.premiumEscrow == address(0) || components.exerciseQueue == address(0)
                || components.settlementEngine == address(0) || components.optionToken == address(0)
                || components.writerPosition == address(0)
        ) revert CalderaErrors.ZeroAddress();

        accessController = CalderaAccessController(components.accessController);
        assetRegistry = AssetRegistry(components.assetRegistry);
        oracleRouter = OracleRouter(components.oracleRouter);
        riskEngine = RiskEngine(components.riskEngine);
        premiumModel = PremiumModel(components.premiumModel);
        seriesController = SeriesController(components.seriesController);
        collateralVault = CollateralVault(components.collateralVault);
        premiumEscrow = PremiumEscrow(components.premiumEscrow);
        exerciseQueue = ExerciseQueue(components.exerciseQueue);
        settlementEngine = SettlementEngine(components.settlementEngine);
        optionToken = OptionToken(components.optionToken);
        writerPosition = WriterPosition(components.writerPosition);
    }

    modifier onlyGovernor() {
        if (!accessController.hasRole(accessController.GOVERNOR_ROLE(), msg.sender)) {
            revert CalderaErrors.Unauthorized(accessController.GOVERNOR_ROLE(), msg.sender);
        }
        _;
    }

    modifier whenNotPaused() {
        if (accessController.paused()) revert CalderaErrors.ProtocolPaused();
        _;
    }

    /// @notice Creates a series after validating its collateral and oracle configuration.
    function createSeries(CalderaTypes.SeriesInput calldata input)
        external
        onlyGovernor
        whenNotPaused
        returns (uint64 seriesId)
    {
        CalderaTypes.AssetConfig memory asset =
            assetRegistry.requireEnabledAsset(input.collateralAsset);
        oracleRouter.getPrice(input.underlyingId, input.maxOracleAge);
        CalderaTypes.SeriesConfig memory config = riskEngine.validateAndBuild(input, asset);
        seriesId = seriesController.createSeries(config);
        emit SeriesCreated(
            seriesId,
            config.underlyingId,
            config.collateralAsset,
            config.optionType,
            config.strikePriceX18,
            config.capPriceX18,
            config.collateralPerContract,
            config.expiry
        );
    }

    /// @notice Locks maximum payout collateral and mints a transferable writer position.
    function writeOptions(
        uint64 seriesId,
        uint128 contracts,
        address receiver,
        uint256 maximumCollateral
    ) external nonReentrant whenNotPaused returns (uint256 positionId) {
        if (receiver == address(0)) revert CalderaErrors.InvalidRecipient(receiver);
        if (contracts == 0) revert CalderaErrors.ZeroAmount();

        CalderaTypes.SeriesConfig memory config = seriesController.configOf(seriesId);
        CalderaTypes.SeriesAccounting memory accounting = seriesController.accountingOf(seriesId);
        uint256 collateral = uint256(config.collateralPerContract) * contracts;
        if (collateral > maximumCollateral) {
            revert CalderaErrors.CollateralAboveLimit(collateral, maximumCollateral);
        }
        assetRegistry.validateDeposit(
            config.collateralAsset,
            collateralVault.accountedCollateralByAsset(config.collateralAsset),
            collateral
        );

        collateralVault.lockFrom(seriesId, config.collateralAsset, msg.sender, collateral);
        positionId = writerPosition.mint(
            receiver,
            seriesId,
            contracts,
            collateral,
            accounting.premiumIndexX128,
            accounting.lossIndexX128
        );
        seriesController.recordWritten(seriesId, contracts, collateral);
        emit OptionsWritten(seriesId, positionId, msg.sender, receiver, contracts, collateral);
    }

    function quotePurchase(uint64 seriesId, uint128 contracts)
        public
        view
        returns (CalderaTypes.PremiumQuote memory quote)
    {
        CalderaTypes.SeriesConfig memory config = seriesController.configOf(seriesId);
        CalderaTypes.SeriesAccounting memory accounting = seriesController.accountingOf(seriesId);
        uint256 spotPriceX18 = oracleRouter.getPrice(config.underlyingId, config.maxOracleAge);
        quote = premiumModel.quote(config, accounting, spotPriceX18, contracts);
    }

    /// @notice Collects premium and mints long option tokens for available inventory.
    function buyOptions(
        uint64 seriesId,
        uint128 contracts,
        address receiver,
        uint256 maximumPremium
    ) external nonReentrant whenNotPaused returns (uint256 premiumPaid) {
        if (receiver == address(0)) {
            revert CalderaErrors.InvalidRecipient(receiver);
        }
        if (contracts == 0) revert CalderaErrors.ZeroAmount();
        CalderaTypes.SeriesConfig memory config = seriesController.configOf(seriesId);
        CalderaTypes.PremiumQuote memory quote = quotePurchase(seriesId, contracts);
        if (quote.totalPremium > maximumPremium) {
            revert CalderaErrors.PremiumAboveLimit(quote.totalPremium, maximumPremium);
        }

        uint256 writerAmount = premiumEscrow.collect(
            seriesId, config.collateralAsset, msg.sender, quote.totalPremium, quote.feeAmount
        );
        seriesController.recordSale(seriesId, contracts);
        seriesController.accruePremium(seriesId, quote.totalPremium, writerAmount);
        optionToken.mint(receiver, seriesId, contracts);
        premiumPaid = quote.totalPremium;
        emit OptionsPurchased(
            seriesId, msg.sender, receiver, contracts, premiumPaid, quote.feeAmount
        );
    }

    function previewExercise(uint64 seriesId, uint128 contracts)
        public
        view
        returns (uint256 spotPriceX18, uint256 payout)
    {
        CalderaTypes.SeriesConfig memory config = seriesController.configOf(seriesId);
        spotPriceX18 = oracleRouter.getPrice(config.underlyingId, config.maxOracleAge);
        payout = riskEngine.exercisePayout(config, spotPriceX18, contracts);
    }

    /// @notice Burns longs and stores an immutable delayed cash-settlement request.
    function requestExercise(
        uint64 seriesId,
        uint128 contracts,
        address recipient,
        uint256 minimumPayout
    ) external nonReentrant whenNotPaused returns (uint256 requestId) {
        if (recipient == address(0)) {
            revert CalderaErrors.InvalidRecipient(recipient);
        }
        if (!seriesController.isExerciseOpen(seriesId)) {
            revert CalderaErrors.ExerciseNotOpen(seriesId, block.timestamp);
        }

        CalderaTypes.SeriesConfig memory config = seriesController.configOf(seriesId);
        (uint256 priceX18, uint256 payout) = previewExercise(seriesId, contracts);
        if (payout == 0) revert CalderaErrors.PayoutIsZero(seriesId, priceX18);
        if (payout < minimumPayout) {
            revert CalderaErrors.PayoutBelowMinimum(payout, minimumPayout);
        }

        optionToken.burn(msg.sender, seriesId, contracts);
        requestId = exerciseQueue.enqueue(
            seriesId,
            contracts,
            msg.sender,
            recipient,
            uint192(priceX18),
            payout,
            config.settlementDelay
        );
        CalderaTypes.ExerciseRequest memory request = exerciseQueue.getRequest(requestId);
        emit ExerciseRequested(
            requestId,
            seriesId,
            msg.sender,
            recipient,
            contracts,
            priceX18,
            payout,
            request.executableAt
        );
    }

    /// @notice Processes one mature request and realizes its loss across writer shares.
    function processExercise(uint256 requestId)
        external
        nonReentrant
        returns (CalderaTypes.SettlementPreview memory result)
    {
        result = _processExercise(requestId, msg.sender);
    }

    function processExerciseBatch(uint256[] calldata requestIds)
        external
        nonReentrant
        returns (CalderaTypes.SettlementPreview[] memory results)
    {
        uint256 length = requestIds.length;
        if (length > exerciseQueue.MAX_BATCH_SIZE()) {
            revert CalderaErrors.BatchTooLarge(length, exerciseQueue.MAX_BATCH_SIZE());
        }
        results = new CalderaTypes.SettlementPreview[](length);
        for (uint256 i; i < length; ++i) {
            results[i] = _processExercise(requestIds[i], msg.sender);
        }
    }

    function claimPremium(uint256 positionId, address recipient)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amount)
    {
        _requirePositionAuthority(positionId);
        if (recipient == address(0)) revert CalderaErrors.InvalidRecipient(recipient);
        CalderaTypes.WriterPositionData memory position = writerPosition.getPosition(positionId);
        CalderaTypes.SeriesConfig memory config = seriesController.configOf(position.seriesId);
        CalderaTypes.SeriesAccounting memory accounting =
            seriesController.accountingOf(position.seriesId);
        amount = writerPosition.checkpointPremium(positionId, accounting.premiumIndexX128);
        premiumEscrow.pay(position.seriesId, config.collateralAsset, recipient, amount);
        emit PremiumClaimed(position.seriesId, positionId, msg.sender, recipient, amount);
    }

    /// @notice Finalizes a writer receipt after expiry and returns its remaining collateral.
    function settleWriterPosition(uint256 positionId, address recipient)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 collateralReturned, uint256 recognizedLoss, uint256 premiumPaid)
    {
        _requirePositionAuthority(positionId);
        if (recipient == address(0)) revert CalderaErrors.InvalidRecipient(recipient);
        CalderaTypes.WriterPositionData memory position = writerPosition.getPosition(positionId);
        CalderaTypes.SeriesConfig memory config = seriesController.configOf(position.seriesId);
        if (block.timestamp < config.expiry) {
            revert CalderaErrors.SeriesNotExpired(position.seriesId, config.expiry);
        }
        CalderaTypes.SeriesAccounting memory accounting =
            seriesController.accountingOf(position.seriesId);

        premiumPaid = writerPosition.claimablePremium(positionId, accounting.premiumIndexX128);
        if (premiumPaid != 0) {
            writerPosition.checkpointPremium(positionId, accounting.premiumIndexX128);
            premiumEscrow.pay(position.seriesId, config.collateralAsset, recipient, premiumPaid);
        }
        (collateralReturned, recognizedLoss) =
            writerPosition.settle(positionId, accounting.lossIndexX128);
        if (collateralReturned != 0) {
            collateralVault.release(
                position.seriesId, config.collateralAsset, recipient, collateralReturned
            );
        }
        seriesController.recordRelease(position.seriesId, collateralReturned);
        emit WriterPositionSettled(
            position.seriesId,
            positionId,
            msg.sender,
            recipient,
            recognizedLoss,
            collateralReturned,
            premiumPaid
        );
    }

    function withdrawProtocolFees(address asset, address recipient, uint256 amount)
        external
        onlyGovernor
        nonReentrant
        whenNotPaused
    {
        premiumEscrow.withdrawFees(asset, recipient, amount);
        emit ProtocolFeesWithdrawn(asset, recipient, amount);
    }

    function modulesBound() external view returns (bool) {
        return seriesController.protocol() == address(this)
            && collateralVault.protocol() == address(this)
            && premiumEscrow.protocol() == address(this)
            && exerciseQueue.protocol() == address(this) && optionToken.protocol() == address(this)
            && writerPosition.protocol() == address(this);
    }

    function _processExercise(uint256 requestId, address processor)
        internal
        returns (CalderaTypes.SettlementPreview memory result)
    {
        CalderaTypes.ExerciseRequest memory request = exerciseQueue.start(requestId);
        CalderaTypes.SeriesConfig memory config = seriesController.configOf(request.seriesId);
        CalderaTypes.SeriesAccounting memory accounting =
            seriesController.accountingOf(request.seriesId);
        uint256 reserveBefore = collateralVault.reserveBySeries(request.seriesId);
        result = settlementEngine.preview(requestId, request, config, accounting, reserveBefore);
        (uint256 reserveDebit, uint256 liquidityDebit) = collateralVault.payExercise(
            request.seriesId, config.collateralAsset, request.recipient, request.payout
        );
        if (reserveDebit != result.reserveDebit || liquidityDebit != result.liquidityDebit) {
            revert CalderaErrors.InvalidSettlement(requestId);
        }
        seriesController.recordSettlement(request.seriesId, request.contracts, request.payout);
        exerciseQueue.complete(requestId);
        emit ExerciseProcessed(
            requestId,
            request.seriesId,
            processor,
            request.recipient,
            request.contracts,
            request.payout,
            reserveDebit,
            liquidityDebit
        );
    }

    function _requirePositionAuthority(uint256 positionId) internal view {
        address owner = writerPosition.ownerOf(positionId);
        if (
            msg.sender != owner && writerPosition.getApproved(positionId) != msg.sender
                && !writerPosition.isApprovedForAll(owner, msg.sender)
        ) {
            revert CalderaErrors.NotPositionOwner(positionId, msg.sender);
        }
    }
}
