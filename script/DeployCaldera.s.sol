// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { CalderaOptionsProtocol } from "../src/CalderaOptionsProtocol.sol";
import { CalderaAccessController } from "../src/access/CalderaAccessController.sol";
import { AssetRegistry } from "../src/assets/AssetRegistry.sol";
import { OracleRouter } from "../src/oracle/OracleRouter.sol";
import { RiskEngine } from "../src/risk/RiskEngine.sol";
import { PremiumModel } from "../src/pricing/PremiumModel.sol";
import { SeriesController } from "../src/core/SeriesController.sol";
import { CollateralVault } from "../src/core/CollateralVault.sol";
import { PremiumEscrow } from "../src/core/PremiumEscrow.sol";
import { ExerciseQueue } from "../src/core/ExerciseQueue.sol";
import { SettlementEngine } from "../src/core/SettlementEngine.sol";
import { OptionToken } from "../src/token/OptionToken.sol";
import { WriterPosition } from "../src/token/WriterPosition.sol";
import { CalderaLens } from "../src/lens/CalderaLens.sol";

contract DeployCaldera is Script {
    function run() external returns (CalderaOptionsProtocol protocol, CalderaLens lens) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address administrator = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        CalderaAccessController accessController = new CalderaAccessController(administrator);
        CalderaOptionsProtocol.Components memory components;
        components.accessController = address(accessController);
        components.assetRegistry = address(new AssetRegistry(address(accessController)));
        components.oracleRouter = address(new OracleRouter(address(accessController)));
        components.riskEngine = address(new RiskEngine(address(accessController)));
        components.premiumModel = address(new PremiumModel(address(accessController)));
        components.seriesController = address(new SeriesController(address(accessController)));
        components.collateralVault = address(new CollateralVault(address(accessController)));
        components.premiumEscrow = address(new PremiumEscrow(address(accessController)));
        components.exerciseQueue = address(new ExerciseQueue(address(accessController)));
        components.settlementEngine = address(new SettlementEngine(address(accessController)));
        components.optionToken = address(new OptionToken(address(accessController)));
        components.writerPosition = address(new WriterPosition(address(accessController)));

        protocol = new CalderaOptionsProtocol(components);
        SeriesController(components.seriesController).bindProtocol(address(protocol));
        CollateralVault(components.collateralVault).bindProtocol(address(protocol));
        PremiumEscrow(components.premiumEscrow).bindProtocol(address(protocol));
        ExerciseQueue(components.exerciseQueue).bindProtocol(address(protocol));
        OptionToken(components.optionToken).bindProtocol(address(protocol));
        WriterPosition(components.writerPosition).bindProtocol(address(protocol));
        lens = new CalderaLens(address(protocol));

        vm.stopBroadcast();

        console2.log("Administrator", administrator);
        console2.log("CalderaOptionsProtocol", address(protocol));
        console2.log("CalderaLens", address(lens));
        console2.log("CalderaAccessController", components.accessController);
    }
}
