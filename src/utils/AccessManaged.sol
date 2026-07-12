// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { CalderaAccessController } from "../access/CalderaAccessController.sol";
import { CalderaErrors } from "../errors/CalderaErrors.sol";

/// @title AccessManaged
/// @notice Shared authorization and lifecycle checks for Caldera protocol modules.
abstract contract AccessManaged {
    CalderaAccessController public immutable accessController;

    /// @notice Core protocol contract allowed to invoke module-only entry points.
    address public protocol;

    event ProtocolBound(address indexed protocol, address indexed administrator);

    constructor(address accessController_) {
        if (accessController_ == address(0)) revert CalderaErrors.ZeroAddress();
        accessController = CalderaAccessController(accessController_);
    }

    modifier onlyRole(bytes32 role) {
        _requireRole(role, msg.sender);
        _;
    }

    modifier onlyProtocol() {
        address boundProtocol = protocol;
        if (boundProtocol == address(0)) revert CalderaErrors.ProtocolNotBound();
        if (msg.sender != boundProtocol) {
            revert CalderaErrors.Unauthorized(keccak256("PROTOCOL_ROLE"), msg.sender);
        }
        _;
    }

    modifier whenNotPaused() {
        if (accessController.paused()) revert CalderaErrors.ProtocolPaused();
        _;
    }

    modifier whenPaused() {
        if (!accessController.paused()) revert CalderaErrors.ProtocolNotPaused();
        _;
    }

    /// @notice Permanently binds this module to the core protocol contract.
    /// @dev Binding is deliberately one-time. Replacing a protocol requires deploying a new module.
    function bindProtocol(address protocol_)
        external
        onlyRole(accessController.DEFAULT_ADMIN_ROLE())
    {
        if (protocol_ == address(0)) revert CalderaErrors.ZeroAddress();
        if (protocol != address(0)) revert CalderaErrors.AlreadyInitialized();

        protocol = protocol_;
        emit ProtocolBound(protocol_, msg.sender);
    }

    function _requireRole(bytes32 role, address account) internal view {
        if (!accessController.hasRole(role, account)) {
            revert CalderaErrors.Unauthorized(role, account);
        }
    }
}
