// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { CalderaErrors } from "../errors/CalderaErrors.sol";
import { IERC721Receiver } from "../interfaces/ICalderaTokens.sol";
import { FixedPointMath } from "../libraries/FixedPointMath.sol";
import { CalderaTypes } from "../types/CalderaTypes.sol";
import { AccessManaged } from "../utils/AccessManaged.sol";

/// @notice Transferable ERC-721 receipts for collateralized writer positions.
contract WriterPosition is AccessManaged {
    using FixedPointMath for uint256;

    string public constant name = "Caldera Writer Position";
    string public constant symbol = "CAL-WP";

    uint256 private _nextPositionId = 1;
    mapping(uint256 id => address owner) private _owners;
    mapping(address owner => uint256 balance) private _balances;
    mapping(uint256 id => address approved) private _tokenApprovals;
    mapping(address owner => mapping(address operator => bool approved)) private _operatorApprovals;
    mapping(uint256 id => CalderaTypes.WriterPositionData data) private _positions;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event PositionMinted(
        uint256 indexed positionId,
        uint64 indexed seriesId,
        address indexed owner,
        uint128 contracts,
        uint256 collateral
    );
    event PremiumCheckpointed(
        uint256 indexed positionId, uint256 indexX128, uint256 amount, uint256 cumulativeClaimed
    );
    event PositionSettled(
        uint256 indexed positionId,
        uint64 indexed seriesId,
        uint256 collateralRefund,
        uint256 loss,
        uint256 lossIndexX128
    );

    constructor(address accessController_) AccessManaged(accessController_) { }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0x80ac58cd;
    }

    function ownerOf(uint256 positionId) public view returns (address owner) {
        owner = _owners[positionId];
        if (owner == address(0)) revert CalderaErrors.PositionNotFound(positionId);
    }

    function balanceOf(address owner) external view returns (uint256) {
        if (owner == address(0)) revert CalderaErrors.ZeroAddress();
        return _balances[owner];
    }

    function totalSupply() external view returns (uint256) {
        return _nextPositionId - 1;
    }

    function getApproved(uint256 positionId) public view returns (address) {
        _requirePosition(positionId);
        return _tokenApprovals[positionId];
    }

    function isApprovedForAll(address owner, address operator) public view returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function getPosition(uint256 positionId)
        external
        view
        returns (CalderaTypes.WriterPositionData memory)
    {
        _requirePosition(positionId);
        return _positions[positionId];
    }

    function claimablePremium(uint256 positionId, uint256 premiumIndexX128)
        public
        view
        returns (uint256)
    {
        _requirePosition(positionId);
        CalderaTypes.WriterPositionData storage data = _positions[positionId];
        uint256 entry = data.premiumIndexEntryX128;
        if (premiumIndexX128 < entry) revert CalderaErrors.InvalidConfiguration();
        return uint256(data.contracts).fromQ128(premiumIndexX128 - entry);
    }

    function settlementPreview(uint256 positionId, uint256 lossIndexX128)
        public
        view
        returns (uint256 collateralRefund, uint256 loss)
    {
        _requirePosition(positionId);
        CalderaTypes.WriterPositionData storage data = _positions[positionId];
        if (data.status == CalderaTypes.PositionStatus.Settled) {
            revert CalderaErrors.PositionAlreadySettled(positionId);
        }
        if (data.status != CalderaTypes.PositionStatus.Active) {
            revert CalderaErrors.PositionNotActive(positionId);
        }
        uint256 entry = data.lossIndexEntryX128;
        if (lossIndexX128 < entry) revert CalderaErrors.InvalidConfiguration();
        loss = uint256(data.contracts).fromQ128(lossIndexX128 - entry);
        if (loss > data.collateral) loss = data.collateral;
        collateralRefund = data.collateral - loss;
    }

    function approve(address approved, uint256 positionId) external {
        address owner = ownerOf(positionId);
        if (msg.sender != owner && !_operatorApprovals[owner][msg.sender]) {
            revert CalderaErrors.TokenNotApproved(owner, msg.sender);
        }
        _tokenApprovals[positionId] = approved;
        emit Approval(owner, approved, positionId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        if (operator == address(0)) revert CalderaErrors.ZeroAddress();
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 positionId) public {
        _transfer(from, to, positionId);
    }

    function safeTransferFrom(address from, address to, uint256 positionId) external {
        safeTransferFrom(from, to, positionId, "");
    }

    function safeTransferFrom(address from, address to, uint256 positionId, bytes memory data)
        public
    {
        _transfer(from, to, positionId);
        _checkReceiver(msg.sender, from, to, positionId, data);
    }

    function mint(
        address to,
        uint64 seriesId,
        uint128 contracts,
        uint256 collateral,
        uint256 premiumIndexEntryX128,
        uint256 lossIndexEntryX128
    ) external onlyProtocol returns (uint256 positionId) {
        if (to == address(0)) revert CalderaErrors.InvalidRecipient(to);
        if (contracts == 0 || collateral == 0) revert CalderaErrors.ZeroAmount();
        positionId = _nextPositionId++;
        _owners[positionId] = to;
        _balances[to] += 1;
        _positions[positionId] = CalderaTypes.WriterPositionData({
            seriesId: seriesId,
            contracts: contracts,
            collateral: collateral,
            premiumIndexEntryX128: premiumIndexEntryX128,
            premiumClaimed: 0,
            lossIndexEntryX128: lossIndexEntryX128,
            lossRecognized: 0,
            createdAt: uint64(block.timestamp),
            settledAt: 0,
            status: CalderaTypes.PositionStatus.Active
        });
        emit Transfer(address(0), to, positionId);
        emit PositionMinted(positionId, seriesId, to, contracts, collateral);
    }

    function checkpointPremium(uint256 positionId, uint256 premiumIndexX128)
        external
        onlyProtocol
        returns (uint256 amount)
    {
        _requirePosition(positionId);
        CalderaTypes.WriterPositionData storage data = _positions[positionId];
        uint256 previousIndex = data.premiumIndexEntryX128;
        if (premiumIndexX128 < previousIndex) revert CalderaErrors.InvalidConfiguration();
        amount = uint256(data.contracts).fromQ128(premiumIndexX128 - previousIndex);
        if (amount == 0) revert CalderaErrors.PremiumUnavailable(positionId);
        data.premiumIndexEntryX128 = premiumIndexX128;
        data.premiumClaimed += amount;
        emit PremiumCheckpointed(positionId, premiumIndexX128, amount, data.premiumClaimed);
    }

    function settle(uint256 positionId, uint256 lossIndexX128)
        external
        onlyProtocol
        returns (uint256 collateralRefund, uint256 loss)
    {
        (collateralRefund, loss) = settlementPreview(positionId, lossIndexX128);
        CalderaTypes.WriterPositionData storage data = _positions[positionId];
        data.lossIndexEntryX128 = lossIndexX128;
        data.lossRecognized = loss;
        data.settledAt = uint64(block.timestamp);
        data.status = CalderaTypes.PositionStatus.Settled;
        emit PositionSettled(positionId, data.seriesId, collateralRefund, loss, lossIndexX128);
    }

    function _transfer(address from, address to, uint256 positionId) private {
        address owner = ownerOf(positionId);
        if (owner != from) revert CalderaErrors.NotPositionOwner(positionId, from);
        if (to == address(0)) revert CalderaErrors.InvalidRecipient(to);
        if (
            msg.sender != owner && _tokenApprovals[positionId] != msg.sender
                && !_operatorApprovals[owner][msg.sender]
        ) revert CalderaErrors.TokenNotApproved(owner, msg.sender);
        delete _tokenApprovals[positionId];
        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[positionId] = to;
        emit Transfer(from, to, positionId);
    }

    function _requirePosition(uint256 positionId) private view {
        if (_owners[positionId] == address(0)) {
            revert CalderaErrors.PositionNotFound(positionId);
        }
    }

    function _checkReceiver(
        address operator,
        address from,
        address to,
        uint256 positionId,
        bytes memory data
    ) private {
        if (to.code.length == 0) return;
        (bool success, bytes memory result) = to.call(
            abi.encodeWithSelector(
                IERC721Receiver.onERC721Received.selector, operator, from, positionId, data
            )
        );
        if (
            !success || result.length < 32
                || abi.decode(result, (bytes4)) != IERC721Receiver.onERC721Received.selector
        ) revert CalderaErrors.PositionTransferRejected(to);
    }
}
