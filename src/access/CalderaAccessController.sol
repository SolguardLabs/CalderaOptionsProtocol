// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { CalderaErrors } from "../errors/CalderaErrors.sol";

/// @title CalderaAccessController
/// @notice Central role registry and emergency-pause authority for the protocol.
/// @dev Role administration intentionally follows the familiar AccessControl model: every role
///      has an administrator role, and the default administrator is its own administrator.
contract CalderaAccessController {
    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant ORACLE_MANAGER_ROLE = keccak256("ORACLE_MANAGER_ROLE");

    struct RoleData {
        mapping(address account => bool granted) members;
        bytes32 adminRole;
    }

    mapping(bytes32 role => RoleData data) private _roles;

    bool public paused;

    event RoleAdminChanged(
        bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole
    );
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event ProtocolPaused(address indexed account);
    event ProtocolUnpaused(address indexed account);

    constructor(address initialAdmin) {
        if (initialAdmin == address(0)) revert CalderaErrors.ZeroAddress();

        _roles[DEFAULT_ADMIN_ROLE].adminRole = DEFAULT_ADMIN_ROLE;
        _roles[GOVERNOR_ROLE].adminRole = DEFAULT_ADMIN_ROLE;
        _roles[GUARDIAN_ROLE].adminRole = DEFAULT_ADMIN_ROLE;
        _roles[ORACLE_MANAGER_ROLE].adminRole = DEFAULT_ADMIN_ROLE;

        // The bootstrap administrator receives each operational role so a deployment is usable
        // immediately. Duties can subsequently be separated with grantRole and renounceRole.
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(GOVERNOR_ROLE, initialAdmin);
        _grantRole(GUARDIAN_ROLE, initialAdmin);
        _grantRole(ORACLE_MANAGER_ROLE, initialAdmin);
    }

    modifier onlyRole(bytes32 role) {
        _checkRole(role, msg.sender);
        _;
    }

    /// @notice Returns whether `account` currently holds `role`.
    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role].members[account];
    }

    /// @notice Reverts unless `account` holds `role`.
    /// @dev Exposed so managed contracts and off-chain simulations share one authorization check.
    function requireRole(bytes32 role, address account) external view {
        _checkRole(role, account);
    }

    /// @notice Returns the role that may grant and revoke `role`.
    function getRoleAdmin(bytes32 role) public view returns (bytes32) {
        return _roles[role].adminRole;
    }

    /// @notice Grants `role` to `account`.
    function grantRole(bytes32 role, address account) external onlyRole(getRoleAdmin(role)) {
        if (account == address(0)) revert CalderaErrors.ZeroAddress();
        _grantRole(role, account);
    }

    /// @notice Revokes `role` from `account`.
    function revokeRole(bytes32 role, address account) external onlyRole(getRoleAdmin(role)) {
        _revokeRole(role, account);
    }

    /// @notice Allows an account to relinquish one of its own roles.
    function renounceRole(bytes32 role, address account) external {
        if (account != msg.sender) revert CalderaErrors.Unauthorized(role, msg.sender);
        _revokeRole(role, account);
    }

    /// @notice Changes the administrator role for `role`.
    /// @dev Restricted to the default administrator to keep the role graph auditable.
    function setRoleAdmin(bytes32 role, bytes32 newAdminRole)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        bytes32 previousAdminRole = getRoleAdmin(role);
        if (previousAdminRole == newAdminRole) return;

        _roles[role].adminRole = newAdminRole;
        emit RoleAdminChanged(role, previousAdminRole, newAdminRole);
    }

    /// @notice Activates the emergency pause.
    function pause() external onlyRole(GUARDIAN_ROLE) {
        if (paused) revert CalderaErrors.ProtocolPaused();
        paused = true;
        emit ProtocolPaused(msg.sender);
    }

    /// @notice Deactivates the emergency pause after governance review.
    function unpause() external {
        if (!hasRole(GOVERNOR_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert CalderaErrors.Unauthorized(GOVERNOR_ROLE, msg.sender);
        }
        if (!paused) revert CalderaErrors.ProtocolNotPaused();

        paused = false;
        emit ProtocolUnpaused(msg.sender);
    }

    function _checkRole(bytes32 role, address account) internal view {
        if (!hasRole(role, account)) revert CalderaErrors.Unauthorized(role, account);
    }

    function _grantRole(bytes32 role, address account) internal {
        if (_roles[role].members[account]) return;
        _roles[role].members[account] = true;
        emit RoleGranted(role, account, msg.sender);
    }

    function _revokeRole(bytes32 role, address account) internal {
        if (!_roles[role].members[account]) return;
        _roles[role].members[account] = false;
        emit RoleRevoked(role, account, msg.sender);
    }
}
