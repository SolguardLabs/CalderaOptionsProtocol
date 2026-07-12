// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { AccessManaged } from "../utils/AccessManaged.sol";
import { ReentrancyGuard } from "../utils/ReentrancyGuard.sol";
import { CalderaErrors } from "../errors/CalderaErrors.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";
import { FixedPointMath } from "../libraries/FixedPointMath.sol";

/// @title PremiumEscrow
/// @notice Holds writer premium allocations and protocol fees until they are paid out.
contract PremiumEscrow is AccessManaged, ReentrancyGuard {
    using SafeTransferLib for address;

    mapping(uint64 seriesId => address asset) private _assetBySeries;
    mapping(uint64 seriesId => uint256 amount) public escrowedPremiumBySeries;
    mapping(address asset => uint256 amount) public escrowedPremiumByAsset;
    mapping(address asset => uint256 amount) public feesByAsset;
    mapping(address asset => uint256 amount) public cumulativeCollectedByAsset;
    mapping(address asset => uint256 amount) public cumulativePremiumPaidByAsset;
    mapping(address asset => uint256 amount) public cumulativeFeesWithdrawnByAsset;

    address[] private _assets;
    mapping(address asset => bool known) private _knownAsset;

    event SeriesAssetBound(uint64 indexed seriesId, address indexed asset);
    event PremiumCollected(
        uint64 indexed seriesId,
        address indexed asset,
        address indexed payer,
        uint256 totalPremium,
        uint256 writerAmount,
        uint256 feeAmount
    );
    event PremiumPaid(
        uint64 indexed seriesId, address indexed asset, address indexed recipient, uint256 amount
    );
    event FeesWithdrawn(address indexed asset, address indexed recipient, uint256 amount);

    constructor(address accessController_) AccessManaged(accessController_) { }

    /// @notice Pulls a buyer payment and separates the writer allocation from fees.
    function collect(
        uint64 seriesId,
        address asset,
        address payer,
        uint256 totalPremium,
        uint256 feeAmount
    ) external onlyProtocol whenNotPaused nonReentrant returns (uint256 writerAmount) {
        if (seriesId == 0) revert CalderaErrors.SeriesNotFound(seriesId);
        if (asset == address(0) || payer == address(0)) revert CalderaErrors.ZeroAddress();
        if (totalPremium == 0) revert CalderaErrors.ZeroAmount();
        if (feeAmount > totalPremium) revert CalderaErrors.InvalidFee(feeAmount);

        _bindSeriesAsset(seriesId, asset);

        uint256 balanceBefore = asset.balanceOf(address(this));
        asset.safeTransferFrom(payer, address(this), totalPremium);
        uint256 balanceAfter = asset.balanceOf(address(this));
        if (balanceAfter < balanceBefore || balanceAfter - balanceBefore != totalPremium) {
            revert CalderaErrors.UnsupportedTokenBehavior(asset);
        }

        writerAmount = totalPremium - feeAmount;
        escrowedPremiumBySeries[seriesId] = _add(escrowedPremiumBySeries[seriesId], writerAmount);
        escrowedPremiumByAsset[asset] = _add(escrowedPremiumByAsset[asset], writerAmount);
        feesByAsset[asset] = _add(feesByAsset[asset], feeAmount);
        cumulativeCollectedByAsset[asset] = _add(cumulativeCollectedByAsset[asset], totalPremium);

        emit PremiumCollected(seriesId, asset, payer, totalPremium, writerAmount, feeAmount);
    }

    /// @notice Pays an accrued premium claim from a series escrow balance.
    function pay(uint64 seriesId, address asset, address recipient, uint256 amount)
        external
        onlyProtocol
        whenNotPaused
        nonReentrant
    {
        if (recipient == address(0)) revert CalderaErrors.InvalidRecipient(recipient);
        if (amount == 0) revert CalderaErrors.ZeroAmount();
        _requireSeriesAsset(seriesId, asset);

        uint256 available = escrowedPremiumBySeries[seriesId];
        if (amount > available) {
            revert CalderaErrors.EscrowBalanceTooLow(asset, available, amount);
        }

        uint256 physicalBefore = asset.balanceOf(address(this));
        if (physicalBefore < amount) {
            revert CalderaErrors.InsufficientPhysicalBalance(asset, physicalBefore, amount);
        }

        escrowedPremiumBySeries[seriesId] = available - amount;
        escrowedPremiumByAsset[asset] -= amount;
        cumulativePremiumPaidByAsset[asset] = _add(cumulativePremiumPaidByAsset[asset], amount);

        asset.safeTransfer(recipient, amount);
        _requireExactOutflow(asset, physicalBefore, amount);

        emit PremiumPaid(seriesId, asset, recipient, amount);
    }

    /// @notice Transfers accrued protocol fees to the selected recipient.
    function withdrawFees(address asset, address recipient, uint256 amount)
        external
        onlyProtocol
        whenNotPaused
        nonReentrant
    {
        if (asset == address(0)) revert CalderaErrors.ZeroAddress();
        if (recipient == address(0)) revert CalderaErrors.InvalidRecipient(recipient);
        if (amount == 0) revert CalderaErrors.ZeroAmount();

        uint256 available = feesByAsset[asset];
        if (amount > available) {
            revert CalderaErrors.EscrowBalanceTooLow(asset, available, amount);
        }

        uint256 physicalBefore = asset.balanceOf(address(this));
        if (physicalBefore < amount) {
            revert CalderaErrors.InsufficientPhysicalBalance(asset, physicalBefore, amount);
        }

        feesByAsset[asset] = available - amount;
        cumulativeFeesWithdrawnByAsset[asset] = _add(cumulativeFeesWithdrawnByAsset[asset], amount);

        asset.safeTransfer(recipient, amount);
        _requireExactOutflow(asset, physicalBefore, amount);

        emit FeesWithdrawn(asset, recipient, amount);
    }

    function assetOfSeries(uint64 seriesId) external view returns (address asset) {
        asset = _assetBySeries[seriesId];
        if (asset == address(0)) revert CalderaErrors.SeriesNotFound(seriesId);
    }

    function premiumBalance(uint64 seriesId) external view returns (uint256) {
        return escrowedPremiumBySeries[seriesId];
    }

    function feeBalance(address asset) external view returns (uint256) {
        return feesByAsset[asset];
    }

    function totalLiability(address asset) public view returns (uint256) {
        return _add(escrowedPremiumByAsset[asset], feesByAsset[asset]);
    }

    function physicalBalance(address asset) public view returns (uint256) {
        if (asset == address(0)) revert CalderaErrors.ZeroAddress();
        return asset.balanceOf(address(this));
    }

    function solvency(address asset)
        external
        view
        returns (uint256 physical, uint256 liability, uint256 surplus, uint256 deficit)
    {
        physical = physicalBalance(asset);
        liability = totalLiability(asset);
        if (physical >= liability) {
            surplus = physical - liability;
        } else {
            deficit = liability - physical;
        }
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
        returns (address[] memory assets, uint256 nextCursor)
    {
        uint256 length = _assets.length;
        if (cursor >= length || size == 0) return (new address[](0), cursor);

        uint256 remaining = length - cursor;
        uint256 resultLength = FixedPointMath.min(size, remaining);
        assets = new address[](resultLength);
        for (uint256 i; i < resultLength; ++i) {
            assets[i] = _assets[cursor + i];
        }
        nextCursor = cursor + resultLength;
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
