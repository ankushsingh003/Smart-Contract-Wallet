// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import "@account-abstraction/contracts/interfaces/IAccount.sol";
import "@account-abstraction/contracts/core/Helpers.sol";

contract SmartAccount is IAccount {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ── State ────────────────────────────────────────────────────

    address public owner;
    IEntryPoint private immutable _entryPoint;
    uint256 public nonce;

    struct SessionKey {
        bool     isActive;
        uint48   validUntil;
        uint256  spendingLimit;
        address  allowedTarget;   // address(0) = any target allowed
    }

    mapping(address => SessionKey) public sessionKeys;

    // ── Events ───────────────────────────────────────────────────

    event Executed(address indexed target, uint256 value, bytes data);
    event SessionKeyAdded(address indexed key, uint48 validUntil, uint256 spendingLimit);
    event SessionKeyRevoked(address indexed key);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    // ── Errors ───────────────────────────────────────────────────

    error NotOwnerOrEntryPoint();
    error NotEntryPoint();
    error CallFailed(address target, bytes returnData);
    error SessionKeyExpired(address key);
    error SessionKeyInactive(address key);
    error ExceedsSpendingLimit(uint256 attempted, uint256 limit);
    error WrongTarget(address attempted, address allowed);

    // ── Modifiers ────────────────────────────────────────────────

    modifier onlyEntryPoint() {
        if (msg.sender != address(_entryPoint)) revert NotEntryPoint();
        _;
    }

    modifier onlyOwnerOrEntryPoint() {
        if (msg.sender != owner && msg.sender != address(_entryPoint))
            revert NotOwnerOrEntryPoint();
        _;
    }

    // ── Constructor ──────────────────────────────────────────────

    constructor(address _owner, IEntryPoint entryPointAddress) {
        owner = _owner;
        _entryPoint = entryPointAddress;
    }

    receive() external payable {}

    // ── ERC-4337 Core ────────────────────────────────────────────

    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external override onlyEntryPoint returns (uint256 validationData) {
        address recovered = userOpHash
            .toEthSignedMessageHash()
            .recover(userOp.signature);

        bool sigFailed = (recovered != owner);

        if (missingAccountFunds > 0) {
            (bool success, ) = payable(address(_entryPoint)).call{
                value: missingAccountFunds
            }("");
            (success);
        }

        return _packValidationData(sigFailed, 0, 0);
    }

    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyEntryPoint {
        nonce++;
        (bool success, bytes memory returnData) = target.call{value: value}(data);
        if (!success) revert CallFailed(target, returnData);
        emit Executed(target, value, data);
    }

    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[]   calldata datas
    ) external onlyEntryPoint {
        nonce++;
        uint256 len = targets.length;
        for (uint256 i = 0; i < len; ) {
            (bool success, bytes memory returnData) = targets[i].call{value: values[i]}(datas[i]);
            if (!success) revert CallFailed(targets[i], returnData);
            emit Executed(targets[i], values[i], datas[i]);
            unchecked { i++; }
        }
    }

    function executeWithSessionKey(
        address sessionKeyAddr,
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyEntryPoint {
        SessionKey storage sk = sessionKeys[sessionKeyAddr];

        if (!sk.isActive)                                        revert SessionKeyInactive(sessionKeyAddr);
        if (block.timestamp > sk.validUntil)                     revert SessionKeyExpired(sessionKeyAddr);
        if (value > sk.spendingLimit)                            revert ExceedsSpendingLimit(value, sk.spendingLimit);
        if (sk.allowedTarget != address(0) && target != sk.allowedTarget)
                                                                 revert WrongTarget(target, sk.allowedTarget);
        nonce++;
        (bool success, bytes memory returnData) = target.call{value: value}(data);
        if (!success) revert CallFailed(target, returnData);
        emit Executed(target, value, data);
    }

    // ── Session Keys ─────────────────────────────────────────────

    function addSessionKey(
        address key,
        uint48  validUntil,
        uint256 spendingLimit,
        address allowedTarget
    ) external onlyOwnerOrEntryPoint {
        sessionKeys[key] = SessionKey({
            isActive:      true,
            validUntil:    validUntil,
            spendingLimit: spendingLimit,
            allowedTarget: allowedTarget
        });
        emit SessionKeyAdded(key, validUntil, spendingLimit);
    }

    function revokeSessionKey(address key) external onlyOwnerOrEntryPoint {
        sessionKeys[key].isActive = false;
        emit SessionKeyRevoked(key);
    }

    // ── Owner ────────────────────────────────────────────────────

    function changeOwner(address newOwner) external onlyOwnerOrEntryPoint {
        address old = owner;
        owner = newOwner;
        emit OwnerChanged(old, newOwner);
    }

    // ── Views ────────────────────────────────────────────────────

    function entryPoint() public view returns (IEntryPoint) {
        return _entryPoint;
    }

    // EIP-1271: lets other contracts verify signatures made by this wallet
    function isValidSignature(bytes32 hash, bytes memory signature)
        external view returns (bytes4)
    {
        address recovered = hash.toEthSignedMessageHash().recover(signature);
        return recovered == owner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    function isSessionKeyValid(address key) external view returns (bool) {
        SessionKey storage sk = sessionKeys[key];
        return sk.isActive && block.timestamp <= sk.validUntil;
    }

    function getEntryPointDeposit() external view returns (uint256) {
        return _entryPoint.balanceOf(address(this));
    }

    function addEntryPointDeposit() external payable {
        _entryPoint.depositTo{value: msg.value}(address(this));
    }
}
