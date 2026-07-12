// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC1155Receiver, IERC721Receiver } from "../../src/interfaces/ICalderaTokens.sol";

contract AcceptingTokenReceiver is IERC1155Receiver, IERC721Receiver {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract RejectingTokenReceiver { }
