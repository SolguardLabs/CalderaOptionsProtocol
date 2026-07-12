// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { CalderaFixture } from "./helpers/CalderaFixture.sol";
import { AcceptingTokenReceiver, RejectingTokenReceiver } from "./mocks/TokenReceivers.sol";

contract TokenPositionsTest is CalderaFixture {
    function testOptionTransfersAndOperatorApproval() public {
        uint64 seriesId = _createCallSeries();
        _write(seriesId, writer, 10);
        _buy(seriesId, buyer, 7);
        address recipient = makeAddr("optionRecipient");

        vm.prank(buyer);
        optionToken.safeTransferFrom(buyer, recipient, seriesId, 2, "direct transfer");

        assertEq(optionToken.balanceOf(buyer, seriesId), 5);
        assertEq(optionToken.balanceOf(recipient, seriesId), 2);

        vm.prank(keeper);
        vm.expectRevert();
        optionToken.safeTransferFrom(buyer, recipient, seriesId, 1, "unauthorized");

        vm.prank(buyer);
        optionToken.setApprovalForAll(keeper, true);
        assertTrue(optionToken.isApprovedForAll(buyer, keeper));

        vm.prank(keeper);
        optionToken.safeTransferFrom(buyer, recipient, seriesId, 3, "operator transfer");

        assertEq(optionToken.balanceOf(buyer, seriesId), 2);
        assertEq(optionToken.balanceOf(recipient, seriesId), 5);
        assertEq(optionToken.totalSupply(seriesId), 7);
    }

    function testOptionSafeSingleAndBatchTransfersCallReceiverHooks() public {
        uint64 seriesId = _createCallSeries();
        _write(seriesId, writer, 10);
        _buy(seriesId, buyer, 6);
        AcceptingTokenReceiver receiver = new AcceptingTokenReceiver();

        vm.prank(buyer);
        optionToken.safeTransferFrom(buyer, address(receiver), seriesId, 2, "single");

        uint256[] memory ids = new uint256[](2);
        ids[0] = seriesId;
        ids[1] = seriesId;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 2;

        vm.prank(buyer);
        optionToken.safeBatchTransferFrom(buyer, address(receiver), ids, amounts, "batch");

        assertEq(optionToken.balanceOf(address(receiver), seriesId), 5);
        assertEq(optionToken.balanceOf(buyer, seriesId), 1);
    }

    function testWriterPositionApprovalTransferAndSafeReceiver() public {
        uint64 seriesId = _createCallSeries();
        uint256 positionId = _write(seriesId, writer, 4);
        AcceptingTokenReceiver receiver = new AcceptingTokenReceiver();

        vm.prank(keeper);
        vm.expectRevert();
        writerPosition.transferFrom(writer, secondWriter, positionId);

        vm.prank(writer);
        writerPosition.approve(keeper, positionId);
        assertEq(writerPosition.getApproved(positionId), keeper);

        vm.prank(keeper);
        writerPosition.transferFrom(writer, secondWriter, positionId);
        assertEq(writerPosition.ownerOf(positionId), secondWriter);
        assertEq(writerPosition.getApproved(positionId), address(0));

        vm.prank(secondWriter);
        writerPosition.setApprovalForAll(keeper, true);
        assertTrue(writerPosition.isApprovedForAll(secondWriter, keeper));

        vm.prank(keeper);
        writerPosition.safeTransferFrom(secondWriter, address(receiver), positionId, "receipt");

        assertEq(writerPosition.ownerOf(positionId), address(receiver));
        assertEq(writerPosition.balanceOf(secondWriter), 0);
        assertEq(writerPosition.balanceOf(address(receiver)), 1);
    }

    function testSafeTransfersRejectContractsWithoutReceiverHooks() public {
        uint64 seriesId = _createCallSeries();
        uint256 positionId = _write(seriesId, writer, 3);
        _buy(seriesId, buyer, 2);
        RejectingTokenReceiver receiver = new RejectingTokenReceiver();

        vm.prank(buyer);
        vm.expectRevert();
        optionToken.safeTransferFrom(buyer, address(receiver), seriesId, 1, "");

        vm.prank(writer);
        vm.expectRevert();
        writerPosition.safeTransferFrom(writer, address(receiver), positionId);

        assertEq(optionToken.balanceOf(buyer, seriesId), 2);
        assertEq(writerPosition.ownerOf(positionId), writer);
    }
}
