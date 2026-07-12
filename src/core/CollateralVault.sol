// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { AccessManaged } from "../utils/AccessManaged.sol";
import { ReentrancyGuard } from "../utils/ReentrancyGuard.sol";
import { CalderaTypes } from "../types/CalderaTypes.sol";
import { CalderaErrors } from "../errors/CalderaErrors.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";
import { FixedPointMath } from "../libraries/FixedPointMath.sol";

/// @title CollateralVault
/// @notice Custodies collateral in pooled asset balances while maintaining per-series reserves.
contract CollateralVault is AccessManaged, ReentrancyGuard {
    using SafeTransferLib for address;

    mapping(uint64 seriesId => address asset) private _assetBySeries;
    mapping(uint64 seriesId => uint256 reserve) public reserveBySeries;

    mapping(address asset => uint256 amount) public accountedCollateralByAsset;
    mapping(address asset => uint256 amount) public liquidityDebitByAsset;
    mapping(address asset => uint256 amount) public cumulativeLockedByAsset;
    mapping(address asset => uint256 amount) public cumulativeReleasedByAsset;
    mapping(address asset => uint256 amount) public cumulativeExercisePaidByAsset;

    address[] private _assets;
    mapping(address asset => bool known) private _knownAsset;

    event SeriesAssetBound(uint64 indexed seriesId, address indexed asset);
    event CollateralLocked(
        uint64 indexed seriesId,
        address indexed asset,
        address indexed payer,
        uint256 amount,
        uint256 seriesReserve
    );
    event CollateralReleased(
        uint64 indexed seriesId,
        address indexed asset,
        address indexed recipient,
        uint256 amount,
        uint256 seriesReserve
    );
    event ExercisePaid(
        uint64 indexed seriesId,
        address indexed asset,
        address indexed recipient,
        uint256 payout,
        uint256 reserveDebit,
        uint256 liquidityDebit
    );

    constructor(address accessController_) AccessManaged(accessController_) { }

    /// @notice Pulls collateral from a payer and credits the reserve of a series.
    /// @return received Amount observed in the vault balance delta.
    function lockFrom(uint64 seriesId, address asset, address payer, uint256 amount)
        external
        onlyProtocol
        whenNotPaused
        nonReentrant
        returns (uint256 received)
    {
        if (seriesId == 0) revert CalderaErrors.SeriesNotFound(seriesId);
        if (asset == address(0) || payer == address(0)) revert CalderaErrors.ZeroAddress();
        if (amount == 0) revert CalderaErrors.ZeroAmount();

        _bindSeriesAsset(seriesId, asset);

        uint256 balanceBefore = asset.balanceOf(address(this));
        asset.safeTransferFrom(payer, address(this), amount);
        uint256 balanceAfter = asset.balanceOf(address(this));

        if (balanceAfter < balanceBefore) {
            revert CalderaErrors.UnsupportedTokenBehavior(asset);
        }
        received = balanceAfter - balanceBefore;
        if (received != amount) revert CalderaErrors.UnsupportedTokenBehavior(asset);

        reserveBySeries[seriesId] = _add(reserveBySeries[seriesId], received);
        accountedCollateralByAsset[asset] = _add(accountedCollateralByAsset[asset], received);
        cumulativeLockedByAsset[asset] = _add(cumulativeLockedByAsset[asset], received);

        emit CollateralLocked(seriesId, asset, payer, received, reserveBySeries[seriesId]);
    }

    /// @notice Returns collateral from the reserve assigned to a series.
    function release(uint64 seriesId, address asset, address recipient, uint256 amount)
        external
        onlyProtocol
        whenNotPaused
        nonReentrant
    {
        if (recipient == address(0)) revert CalderaErrors.InvalidRecipient(recipient);
        if (amount == 0) revert CalderaErrors.ZeroAmount();
        _requireSeriesAsset(seriesId, asset);

        uint256 reserve = reserveBySeries[seriesId];
        if (amount > reserve) {
            revert CalderaErrors.ReserveTooLow(seriesId, reserve, amount);
        }

        uint256 physicalBefore = asset.balanceOf(address(this));
        if (physicalBefore < amount) {
            revert CalderaErrors.InsufficientPhysicalBalance(asset, physicalBefore, amount);
        }

        reserveBySeries[seriesId] = reserve - amount;
        accountedCollateralByAsset[asset] -= amount;
        cumulativeReleasedByAsset[asset] = _add(cumulativeReleasedByAsset[asset], amount);

        asset.safeTransfer(recipient, amount);
        _requireExactOutflow(asset, physicalBefore, amount);

        emit CollateralReleased(seriesId, asset, recipient, amount, reserveBySeries[seriesId]);
    }

    /// @notice Pays an exercise request from the pooled asset balance.
    /// @dev The series reserve is debited first. Any remainder is recorded as an asset-level
    ///      liquidity debit while the recipient still receives the complete payout.
    function payExercise(uint64 seriesId, address asset, address recipient, uint256 payout)
        external
        onlyProtocol
        whenNotPaused
        nonReentrant
        returns (uint256 reserveDebit, uint256 liquidityDebit)
    {
        if (recipient == address(0)) revert CalderaErrors.InvalidRecipient(recipient);
        if (payout == 0) revert CalderaErrors.ZeroAmount();
        _requireSeriesAsset(seriesId, asset);

        uint256 physicalBefore = asset.balanceOf(address(this));
        if (physicalBefore < payout) {
            revert CalderaErrors.InsufficientPhysicalBalance(asset, physicalBefore, payout);
        }

        uint256 reserve = reserveBySeries[seriesId];
        reserveDebit = FixedPointMath.min(reserve, payout);
        liquidityDebit = payout - reserveDebit;

        reserveBySeries[seriesId] = reserve - reserveDebit;
        accountedCollateralByAsset[asset] -= reserveDebit;
        if (liquidityDebit != 0) {
            liquidityDebitByAsset[asset] = _add(liquidityDebitByAsset[asset], liquidityDebit);
        }
        cumulativeExercisePaidByAsset[asset] = _add(cumulativeExercisePaidByAsset[asset], payout);

        asset.safeTransfer(recipient, payout);
        _requireExactOutflow(asset, physicalBefore, payout);

        emit ExercisePaid(seriesId, asset, recipient, payout, reserveDebit, liquidityDebit);
    }

    function assetOfSeries(uint64 seriesId) external view returns (address asset) {
        asset = _assetBySeries[seriesId];
        if (asset == address(0)) revert CalderaErrors.SeriesNotFound(seriesId);
    }

    function reserveOf(uint64 seriesId) external view returns (uint256) {
        return reserveBySeries[seriesId];
    }

    function physicalBalance(address asset) public view returns (uint256) {
        if (asset == address(0)) revert CalderaErrors.ZeroAddress();
        return asset.balanceOf(address(this));
    }

    function availableSurplus(address asset) external view returns (uint256) {
        uint256 physical = physicalBalance(asset);
        uint256 accounted = accountedCollateralByAsset[asset];
        return physical > accounted ? physical - accounted : 0;
    }

    function solvency(address asset)
        public
        view
        returns (CalderaTypes.AssetSolvency memory status)
    {
        uint256 physical = physicalBalance(asset);
        uint256 accounted = accountedCollateralByAsset[asset];
        uint256 surplus;
        uint256 deficit;

        if (physical >= accounted) {
            surplus = physical - accounted;
        } else {
            deficit = accounted - physical;
        }

        status = CalderaTypes.AssetSolvency({
            asset: asset,
            physicalBalance: physical,
            accountedCollateral: accounted,
            protocolBuffer: surplus,
            cumulativeLiquidityDebit: liquidityDebitByAsset[asset],
            surplus: surplus,
            deficit: deficit
        });
    }

    function isSolvent(address asset) external view returns (bool) {
        return physicalBalance(asset) >= accountedCollateralByAsset[asset];
    }

    function assetCount() external view returns (uint256) {
        return _assets.length;
    }

    function assetAt(uint256 index) external view returns (address) {
        return _assets[index];
    }

    function assetPage(uint256 cursor, uint256 size)
        external
        view
        returns (
            address[] memory assets,
            CalderaTypes.AssetSolvency[] memory statuses,
            uint256 nextCursor
        )
    {
        uint256 length = _assets.length;
        if (cursor >= length || size == 0) {
            return (new address[](0), new CalderaTypes.AssetSolvency[](0), cursor);
        }

        uint256 resultLength = FixedPointMath.min(size, length - cursor);
        uint256 end = cursor + resultLength;
        assets = new address[](resultLength);
        statuses = new CalderaTypes.AssetSolvency[](resultLength);

        for (uint256 i; i < resultLength; ++i) {
            address asset = _assets[cursor + i];
            assets[i] = asset;
            statuses[i] = solvency(asset);
        }
        nextCursor = end;
    }

    function _bindSeriesAsset(uint64 seriesId, address asset) private {
        address current = _assetBySeries[seriesId];
        if (current == address(0)) {
            _assetBySeries[seriesId] = asset;
            emit SeriesAssetBound(seriesId, asset);
        } else if (current != asset) {
            revert CalderaErrors.InvalidConfiguration();
        }

        if (!_knownAsset[asset]) {
            _knownAsset[asset] = true;
            _assets.push(asset);
        }
    }

    function _requireSeriesAsset(uint64 seriesId, address asset) private view {
        if (asset == address(0)) revert CalderaErrors.ZeroAddress();
        address expected = _assetBySeries[seriesId];
        if (expected == address(0)) revert CalderaErrors.SeriesNotFound(seriesId);
        if (expected != asset) revert CalderaErrors.InvalidConfiguration();
    }

    function _requireExactOutflow(address asset, uint256 balanceBefore, uint256 amount)
        private
        view
    {
        uint256 balanceAfter = asset.balanceOf(address(this));
        if (balanceAfter > balanceBefore || balanceBefore - balanceAfter != amount) {
            revert CalderaErrors.UnsupportedTokenBehavior(asset);
        }
    }

    function _add(uint256 a, uint256 b) private pure returns (uint256 result) {
        unchecked {
            result = a + b;
        }
        if (result < a) revert CalderaErrors.AccountingOverflow();
    }
}
