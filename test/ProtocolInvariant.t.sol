// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { CalderaFixture } from "./helpers/CalderaFixture.sol";
import { CalderaOptionsProtocol } from "../src/CalderaOptionsProtocol.sol";
import { SeriesController } from "../src/core/SeriesController.sol";
import { OptionToken } from "../src/token/OptionToken.sol";
import { CalderaTypes } from "../src/types/CalderaTypes.sol";

contract FundingHandler is Test {
    CalderaOptionsProtocol private immutable protocol;
    SeriesController private immutable seriesController;
    OptionToken private immutable optionToken;
    uint64 private immutable seriesId;
    address private immutable firstBuyer;
    address private immutable secondBuyer;

    constructor(
        CalderaOptionsProtocol protocol_,
        SeriesController seriesController_,
        OptionToken optionToken_,
        uint64 seriesId_,
        address firstBuyer_,
        address secondBuyer_
    ) {
        protocol = protocol_;
        seriesController = seriesController_;
        optionToken = optionToken_;
        seriesId = seriesId_;
        firstBuyer = firstBuyer_;
        secondBuyer = secondBuyer_;
    }

    function buy(uint128 rawContracts, bool useSecondBuyer) external {
        uint256 available = seriesController.availableInventory(seriesId);
        if (available == 0) return;
        uint128 contracts = uint128(bound(rawContracts, 1, available > 5 ? 5 : available));
        address account = useSecondBuyer ? secondBuyer : firstBuyer;
        vm.prank(account);
        protocol.buyOptions(seriesId, contracts, account, type(uint256).max);
    }

    function transfer(uint128 rawContracts, bool fromSecondBuyer) external {
        address from = fromSecondBuyer ? secondBuyer : firstBuyer;
        address to = fromSecondBuyer ? firstBuyer : secondBuyer;
        uint256 balance = optionToken.balanceOf(from, seriesId);
        if (balance == 0) return;
        uint256 amount = bound(rawContracts, 1, balance);
        vm.prank(from);
        optionToken.safeTransferFrom(from, to, seriesId, amount, "");
    }
}

contract ProtocolInvariantTest is CalderaFixture {
    uint64 private seriesId;
    FundingHandler private handler;

    function setUp() public override {
        super.setUp();
        seriesId = _createCallSeries();
        _write(seriesId, writer, 100);
        handler = new FundingHandler(
            protocol, seriesController, optionToken, seriesId, buyer, secondBuyer
        );
        targetContract(address(handler));
    }

    function invariantLongSupplyMatchesSoldContracts() public view {
        CalderaTypes.SeriesAccounting memory accounting = seriesController.accountingOf(seriesId);
        assertEq(optionToken.totalSupply(seriesId), accounting.soldContracts);
        assertLe(accounting.soldContracts, accounting.writtenContracts);
        assertEq(
            optionToken.balanceOf(buyer, seriesId) + optionToken.balanceOf(secondBuyer, seriesId),
            accounting.soldContracts
        );
    }

    function invariantFundingCollateralRemainsFullyBacked() public view {
        CalderaTypes.SeriesAccounting memory accounting = seriesController.accountingOf(seriesId);
        assertEq(collateralVault.reserveBySeries(seriesId), accounting.collateralDeposited);
        assertEq(usdc.balanceOf(address(collateralVault)), accounting.collateralDeposited);
        assertTrue(collateralVault.isSolvent(address(usdc)));
    }

    function invariantPremiumEscrowMatchesItsLiabilities() public view {
        uint256 liability = premiumEscrow.escrowedPremiumByAsset(address(usdc))
            + premiumEscrow.feesByAsset(address(usdc));
        assertEq(usdc.balanceOf(address(premiumEscrow)), liability);
    }
}
