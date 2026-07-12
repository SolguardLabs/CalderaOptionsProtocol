// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { CalderaOptionsProtocol } from "../../src/CalderaOptionsProtocol.sol";
import { CalderaAccessController } from "../../src/access/CalderaAccessController.sol";
import { AssetRegistry } from "../../src/assets/AssetRegistry.sol";
import { OracleRouter } from "../../src/oracle/OracleRouter.sol";
import { RiskEngine } from "../../src/risk/RiskEngine.sol";
import { PremiumModel } from "../../src/pricing/PremiumModel.sol";
import { SeriesController } from "../../src/core/SeriesController.sol";
import { CollateralVault } from "../../src/core/CollateralVault.sol";
import { PremiumEscrow } from "../../src/core/PremiumEscrow.sol";
import { ExerciseQueue } from "../../src/core/ExerciseQueue.sol";
import { SettlementEngine } from "../../src/core/SettlementEngine.sol";
import { OptionToken } from "../../src/token/OptionToken.sol";
import { WriterPosition } from "../../src/token/WriterPosition.sol";
import { CalderaLens } from "../../src/lens/CalderaLens.sol";
import { CalderaTypes } from "../../src/types/CalderaTypes.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

abstract contract CalderaFixture is Test {
    bytes32 internal constant ETH_USD = keccak256("ETH/USD");
    uint256 internal constant WAD = 1e18;
    uint256 internal constant USDC = 1e6;
    uint256 internal constant START_TIME = 1_800_000_000;

    address internal writer = makeAddr("writer");
    address internal secondWriter = makeAddr("secondWriter");
    address internal buyer = makeAddr("buyer");
    address internal secondBuyer = makeAddr("secondBuyer");
    address internal keeper = makeAddr("keeper");
    address internal treasury = makeAddr("treasury");

    CalderaAccessController internal accessController;
    AssetRegistry internal assetRegistry;
    OracleRouter internal oracleRouter;
    RiskEngine internal riskEngine;
    PremiumModel internal premiumModel;
    SeriesController internal seriesController;
    CollateralVault internal collateralVault;
    PremiumEscrow internal premiumEscrow;
    ExerciseQueue internal exerciseQueue;
    SettlementEngine internal settlementEngine;
    OptionToken internal optionToken;
    WriterPosition internal writerPosition;
    CalderaOptionsProtocol internal protocol;
    CalderaLens internal lens;
    MockERC20 internal usdc;

    uint32 internal oracleSequence;

    function setUp() public virtual {
        vm.warp(START_TIME);
        accessController = new CalderaAccessController(address(this));
        assetRegistry = new AssetRegistry(address(accessController));
        oracleRouter = new OracleRouter(address(accessController));
        riskEngine = new RiskEngine(address(accessController));
        premiumModel = new PremiumModel(address(accessController));
        seriesController = new SeriesController(address(accessController));
        collateralVault = new CollateralVault(address(accessController));
        premiumEscrow = new PremiumEscrow(address(accessController));
        exerciseQueue = new ExerciseQueue(address(accessController));
        settlementEngine = new SettlementEngine(address(accessController));
        optionToken = new OptionToken(address(accessController));
        writerPosition = new WriterPosition(address(accessController));

        CalderaOptionsProtocol.Components memory components = CalderaOptionsProtocol.Components({
            accessController: address(accessController),
            assetRegistry: address(assetRegistry),
            oracleRouter: address(oracleRouter),
            riskEngine: address(riskEngine),
            premiumModel: address(premiumModel),
            seriesController: address(seriesController),
            collateralVault: address(collateralVault),
            premiumEscrow: address(premiumEscrow),
            exerciseQueue: address(exerciseQueue),
            settlementEngine: address(settlementEngine),
            optionToken: address(optionToken),
            writerPosition: address(writerPosition)
        });
        protocol = new CalderaOptionsProtocol(components);

        seriesController.bindProtocol(address(protocol));
        collateralVault.bindProtocol(address(protocol));
        premiumEscrow.bindProtocol(address(protocol));
        exerciseQueue.bindProtocol(address(protocol));
        optionToken.bindProtocol(address(protocol));
        writerPosition.bindProtocol(address(protocol));
        lens = new CalderaLens(address(protocol));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        assetRegistry.configureAsset(address(usdc), bytes32("USDC"), 6, 1_000_000_000);
        oracleRouter.configureFeed(ETH_USD, true);
        _publishPrice(2200e18);

        _fundAndApprove(writer);
        _fundAndApprove(secondWriter);
        _fundAndApprove(buyer);
        _fundAndApprove(secondBuyer);
    }

    function defaultCallInput() internal view returns (CalderaTypes.SeriesInput memory input) {
        input = CalderaTypes.SeriesInput({
            collateralAsset: address(usdc),
            underlyingId: ETH_USD,
            optionType: CalderaTypes.OptionType.Call,
            saleStart: uint64(block.timestamp),
            saleEnd: uint64(block.timestamp + 3 days),
            exerciseStart: uint64(block.timestamp + 3 days),
            expiry: uint64(block.timestamp + 7 days),
            settlementDelay: uint32(1 days),
            maxOracleAge: uint32(30 days),
            strikePriceX18: uint96(2000e18),
            capPriceX18: uint96(3000e18),
            contractSizeX18: uint128(WAD),
            feeBps: 100
        });
    }

    function _createCallSeries() internal returns (uint64) {
        return protocol.createSeries(defaultCallInput());
    }

    function _write(uint64 seriesId, address account, uint128 contracts)
        internal
        returns (uint256 positionId)
    {
        vm.prank(account);
        positionId = protocol.writeOptions(seriesId, contracts, account, type(uint256).max);
    }

    function _buy(uint64 seriesId, address account, uint128 contracts)
        internal
        returns (uint256 premium)
    {
        vm.prank(account);
        premium = protocol.buyOptions(seriesId, contracts, account, type(uint256).max);
    }

    function _moveToExercise(uint64 seriesId) internal {
        CalderaTypes.SeriesConfig memory config = seriesController.configOf(seriesId);
        vm.warp(config.exerciseStart);
        _publishPrice(2500e18);
    }

    function _moveToExpiry(uint64 seriesId) internal {
        CalderaTypes.SeriesConfig memory config = seriesController.configOf(seriesId);
        vm.warp(config.expiry);
    }

    function _publishPrice(uint192 priceX18) internal {
        oracleSequence += 1;
        oracleRouter.submitPrice(ETH_USD, priceX18, uint64(block.timestamp), oracleSequence);
    }

    function _fundAndApprove(address account) internal {
        usdc.mint(account, 50_000_000 * USDC);
        vm.startPrank(account);
        usdc.approve(address(collateralVault), type(uint256).max);
        usdc.approve(address(premiumEscrow), type(uint256).max);
        vm.stopPrank();
    }
}
