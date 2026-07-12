// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { CalderaErrors } from "../errors/CalderaErrors.sol";
import { IERC1155Receiver } from "../interfaces/ICalderaTokens.sol";
import { AccessManaged } from "../utils/AccessManaged.sol";

/// @notice ERC-1155 long option tokens, with one token identifier per series.
contract OptionToken is AccessManaged {
    string public constant name = "Caldera Option";
    string public constant symbol = "CAL-OPT";

    mapping(uint256 id => mapping(address account => uint256 amount)) private _balances;
    mapping(address owner => mapping(address operator => bool approved)) private _approvals;
    mapping(uint256 id => uint256 supply) private _totalSupply;

    event TransferSingle(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256 id,
        uint256 value
    );
    event TransferBatch(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256[] ids,
        uint256[] values
    );
    event ApprovalForAll(address indexed account, address indexed operator, bool approved);
    event URI(string value, uint256 indexed id);

    constructor(address accessController_) AccessManaged(accessController_) { }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0xd9b67a26 || interfaceId == 0x0e89341c;
    }

    function uri(uint256) external pure returns (string memory) {
        return "caldera://option-series/{id}";
    }

    function balanceOf(address account, uint256 id) public view returns (uint256) {
        if (account == address(0)) revert CalderaErrors.ZeroAddress();
        return _balances[id][account];
    }

    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids)
        external
        view
        returns (uint256[] memory balances)
    {
        uint256 length = accounts.length;
        if (length != ids.length) revert CalderaErrors.LengthMismatch();
        balances = new uint256[](length);
        for (uint256 i; i < length;) {
            balances[i] = balanceOf(accounts[i], ids[i]);
            unchecked {
                ++i;
            }
        }
    }

    function totalSupply(uint256 id) external view returns (uint256) {
        return _totalSupply[id];
    }

    function exists(uint256 id) external view returns (bool) {
        return _totalSupply[id] != 0;
    }

    function setApprovalForAll(address operator, bool approved) external {
        if (operator == address(0)) revert CalderaErrors.ZeroAddress();
        _approvals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address owner, address operator) public view returns (bool) {
        return _approvals[owner][operator];
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external {
        _requireAuthority(from);
        _move(from, to, id, amount);
        emit TransferSingle(msg.sender, from, to, id, amount);
        _checkSingleReceiver(msg.sender, from, to, id, amount, data);
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external {
        _requireAuthority(from);
        if (to == address(0)) revert CalderaErrors.InvalidRecipient(to);
        uint256 length = ids.length;
        if (length != amounts.length) revert CalderaErrors.LengthMismatch();
        for (uint256 i; i < length;) {
            _move(from, to, ids[i], amounts[i]);
            unchecked {
                ++i;
            }
        }
        emit TransferBatch(msg.sender, from, to, ids, amounts);
        _checkBatchReceiver(msg.sender, from, to, ids, amounts, data);
    }

    function mint(address to, uint256 id, uint256 amount) external onlyProtocol {
        _mint(to, id, amount, "");
    }

    function mint(address to, uint256 id, uint256 amount, bytes calldata data)
        external
        onlyProtocol
    {
        _mint(to, id, amount, data);
    }

    function burn(address from, uint256 id, uint256 amount) external onlyProtocol {
        if (amount == 0) revert CalderaErrors.ZeroAmount();
        _debit(from, id, amount);
        _totalSupply[id] -= amount;
        emit TransferSingle(msg.sender, from, address(0), id, amount);
    }

    function _mint(address to, uint256 id, uint256 amount, bytes memory data) private {
        if (to == address(0)) revert CalderaErrors.InvalidRecipient(to);
        if (amount == 0) revert CalderaErrors.ZeroAmount();
        _balances[id][to] += amount;
        _totalSupply[id] += amount;
        emit TransferSingle(msg.sender, address(0), to, id, amount);
        _checkSingleReceiver(msg.sender, address(0), to, id, amount, data);
    }

    function _move(address from, address to, uint256 id, uint256 amount) private {
        if (to == address(0)) revert CalderaErrors.InvalidRecipient(to);
        _debit(from, id, amount);
        _balances[id][to] += amount;
    }

    function _debit(address from, uint256 id, uint256 amount) private {
        if (from == address(0)) revert CalderaErrors.ZeroAddress();
        uint256 available = _balances[id][from];
        if (available < amount) {
            revert CalderaErrors.TokenBalanceTooLow(from, id, available, amount);
        }
        unchecked {
            _balances[id][from] = available - amount;
        }
    }

    function _requireAuthority(address from) private view {
        if (from == address(0)) revert CalderaErrors.ZeroAddress();
        if (msg.sender != from && !_approvals[from][msg.sender]) {
            revert CalderaErrors.TokenNotApproved(from, msg.sender);
        }
    }

    function _checkSingleReceiver(
        address operator,
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) private {
        if (to.code.length == 0) return;
        (bool success, bytes memory result) = to.call(
            abi.encodeWithSelector(
                IERC1155Receiver.onERC1155Received.selector, operator, from, id, amount, data
            )
        );
        if (
            !success || result.length < 32
                || abi.decode(result, (bytes4)) != IERC1155Receiver.onERC1155Received.selector
        ) revert CalderaErrors.TokenTransferRejected(to);
    }

    function _checkBatchReceiver(
        address operator,
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) private {
        if (to.code.length == 0) return;
        (bool success, bytes memory result) = to.call(
            abi.encodeWithSelector(
                IERC1155Receiver.onERC1155BatchReceived.selector, operator, from, ids, amounts, data
            )
        );
        if (
            !success || result.length < 32
                || abi.decode(result, (bytes4)) != IERC1155Receiver.onERC1155BatchReceived.selector
        ) revert CalderaErrors.TokenTransferRejected(to);
    }
}
