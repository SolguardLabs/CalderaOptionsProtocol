// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { AccessManaged } from "../utils/AccessManaged.sol";
import { CalderaTypes } from "../types/CalderaTypes.sol";
import { CalderaErrors } from "../errors/CalderaErrors.sol";

/// @title AssetRegistry
/// @notice Governance-controlled catalog of collateral assets accepted by the protocol.
/// @dev Deposit caps are stored as whole-token quantities in `AssetConfig.depositCap`. This keeps
///      the compact shared type useful for assets with different decimals. Checks convert the cap
///      into the asset's smallest unit before comparing it with protocol accounting.
contract AssetRegistry is AccessManaged {
    mapping(address asset => CalderaTypes.AssetConfig config) private _assetConfigs;
    mapping(address asset => bool configured) private _configured;
    address[] private _configuredAssets;

    event AssetConfigured(
        address indexed asset, bytes32 indexed symbol, uint8 decimals, uint32 depositCap
    );
    event AssetEnabled(address indexed asset, bool enabled);
    event AssetDepositCapUpdated(
        address indexed asset, uint32 previousDepositCap, uint32 newDepositCap
    );
    event AssetSymbolUpdated(
        address indexed asset, bytes32 indexed previousSymbol, bytes32 indexed newSymbol
    );

    constructor(address accessController_) AccessManaged(accessController_) { }

    /// @notice Registers a new collateral asset and enables it immediately.
    /// @param depositCap Maximum whole-token quantity that may be accounted by the protocol.
    function configureAsset(address asset, bytes32 symbol, uint8 decimals, uint32 depositCap)
        external
        onlyRole(accessController.GOVERNOR_ROLE())
    {
        _configureAsset(asset, symbol, decimals, depositCap);
    }

    /// @notice Enables or disables new protocol activity for a configured asset.
    function setAssetEnabled(address asset, bool enabled)
        external
        onlyRole(accessController.GOVERNOR_ROLE())
    {
        _requireConfigured(asset);

        CalderaTypes.AssetConfig storage config = _assetConfigs[asset];
        if (config.enabled == enabled) return;
        config.enabled = enabled;

        emit AssetEnabled(asset, enabled);
    }

    /// @notice Updates a configured asset's whole-token deposit cap.
    function setDepositCap(address asset, uint32 newDepositCap)
        external
        onlyRole(accessController.GOVERNOR_ROLE())
    {
        _requireConfigured(asset);
        if (newDepositCap == 0) revert CalderaErrors.InvalidConfiguration();

        CalderaTypes.AssetConfig storage config = _assetConfigs[asset];
        uint32 previousDepositCap = config.depositCap;
        if (previousDepositCap == newDepositCap) return;

        config.depositCap = newDepositCap;
        emit AssetDepositCapUpdated(asset, previousDepositCap, newDepositCap);
    }

    /// @notice Updates the human-readable short symbol associated with an asset.
    /// @dev Asset identity and decimal precision remain immutable after registration.
    function setAssetSymbol(address asset, bytes32 newSymbol)
        external
        onlyRole(accessController.GOVERNOR_ROLE())
    {
        _requireConfigured(asset);
        if (newSymbol == bytes32(0)) revert CalderaErrors.InvalidConfiguration();

        CalderaTypes.AssetConfig storage config = _assetConfigs[asset];
        bytes32 previousSymbol = config.symbol;
        if (previousSymbol == newSymbol) return;

        config.symbol = newSymbol;
        emit AssetSymbolUpdated(asset, previousSymbol, newSymbol);
    }

    /// @notice Returns whether an asset has an immutable registry entry.
    function isConfigured(address asset) external view returns (bool) {
        return _configured[asset];
    }

    /// @notice Returns whether an asset is configured and currently enabled.
    function isEnabled(address asset) external view returns (bool) {
        return _configured[asset] && _assetConfigs[asset].enabled;
    }

    /// @notice Returns an asset configuration, including disabled configurations.
    function getAssetConfig(address asset) public view returns (CalderaTypes.AssetConfig memory) {
        _requireConfigured(asset);
        return _assetConfigs[asset];
    }

    /// @notice Returns a configuration only when the asset is enabled.
    function requireEnabledAsset(address asset)
        public
        view
        returns (CalderaTypes.AssetConfig memory config)
    {
        config = getAssetConfig(asset);
        if (!config.enabled) revert CalderaErrors.AssetDisabled(asset);
    }

    /// @notice Converts a configured asset's whole-token cap into its smallest denomination.
    function depositCapAmount(address asset) public view returns (uint256) {
        CalderaTypes.AssetConfig memory config = getAssetConfig(asset);
        return uint256(config.depositCap) * (10 ** uint256(config.decimals));
    }

    /// @notice Verifies that an additional collateral deposit remains within the asset cap.
    /// @param currentDeposits Current protocol-accounted balance in the asset's smallest unit.
    /// @param additionalDeposit Proposed increase in the asset's smallest unit.
    function validateDeposit(address asset, uint256 currentDeposits, uint256 additionalDeposit)
        external
        view
        returns (CalderaTypes.AssetConfig memory config)
    {
        config = requireEnabledAsset(asset);
        if (additionalDeposit == 0) revert CalderaErrors.ZeroAmount();

        uint256 cap = uint256(config.depositCap) * (10 ** uint256(config.decimals));
        if (currentDeposits > cap || additionalDeposit > cap - currentDeposits) {
            uint256 requested;
            unchecked {
                // The exact sum is only used for diagnostics. Saturating avoids an unrelated
                // arithmetic panic when a malformed caller supplies enormous accounting values.
                requested = additionalDeposit > type(uint256).max - currentDeposits
                    ? type(uint256).max
                    : currentDeposits + additionalDeposit;
            }
            revert CalderaErrors.DepositCapExceeded(asset, requested, cap);
        }
    }

    function configuredAssetCount() external view returns (uint256) {
        return _configuredAssets.length;
    }

    function configuredAssetAt(uint256 index) external view returns (address) {
        return _configuredAssets[index];
    }

    function configuredAssets() external view returns (address[] memory) {
        return _configuredAssets;
    }

    function _configureAsset(address asset, bytes32 symbol, uint8 decimals, uint32 depositCap)
        internal
    {
        if (asset == address(0)) revert CalderaErrors.ZeroAddress();
        if (_configured[asset]) revert CalderaErrors.AssetAlreadyConfigured(asset);
        if (decimals > 18) revert CalderaErrors.UnsupportedDecimals(decimals);
        if (symbol == bytes32(0) || depositCap == 0) {
            revert CalderaErrors.InvalidConfiguration();
        }

        _configured[asset] = true;
        _assetConfigs[asset] = CalderaTypes.AssetConfig({
            enabled: true, decimals: decimals, depositCap: depositCap, symbol: symbol
        });
        _configuredAssets.push(asset);

        emit AssetConfigured(asset, symbol, decimals, depositCap);
        emit AssetEnabled(asset, true);
    }

    function _requireConfigured(address asset) internal view {
        if (!_configured[asset]) revert CalderaErrors.AssetNotConfigured(asset);
    }
}
