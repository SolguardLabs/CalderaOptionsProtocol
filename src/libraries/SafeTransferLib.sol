// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC20Minimal } from "../interfaces/ICalderaTokens.sol";
import { CalderaErrors } from "../errors/CalderaErrors.sol";

library SafeTransferLib {
    function safeTransfer(address token, address recipient, uint256 amount) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeCall(IERC20Minimal.transfer, (recipient, amount)));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert CalderaErrors.TransferFailed(token, address(this), recipient, amount);
        }
    }

    function safeTransferFrom(address token, address owner, address recipient, uint256 amount)
        internal
    {
        (bool success, bytes memory data) =
            token.call(abi.encodeCall(IERC20Minimal.transferFrom, (owner, recipient, amount)));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert CalderaErrors.TransferFailed(token, owner, recipient, amount);
        }
    }

    function safeApprove(address token, address spender, uint256 amount) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeCall(IERC20Minimal.approve, (spender, amount)));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert CalderaErrors.TransferFailed(token, address(this), spender, amount);
        }
    }

    function balanceOf(address token, address account) internal view returns (uint256 balance) {
        (bool success, bytes memory data) =
            token.staticcall(abi.encodeCall(IERC20Minimal.balanceOf, (account)));
        if (!success || data.length < 32) {
            revert CalderaErrors.TransferFailed(token, account, account, 0);
        }
        balance = abi.decode(data, (uint256));
    }
}
