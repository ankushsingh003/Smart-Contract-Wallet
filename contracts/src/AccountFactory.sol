// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import "./SmartAccount.sol";

contract AccountFactory {

    // ── State ────────────────────────────────────────────────────

    IEntryPoint public immutable entryPoint;

    mapping(address => address) public ownerToAccount;

    // ── Events ───────────────────────────────────────────────────

    event AccountCreated(address indexed owner, address indexed account, uint256 salt);

    // ── Errors ───────────────────────────────────────────────────

    error AccountAlreadyExists(address owner, address existing);

    // ── Constructor ──────────────────────────────────────────────

    constructor(IEntryPoint _entryPoint) {
        entryPoint = _entryPoint;
    }

    // ── Core ─────────────────────────────────────────────────────

    /**
     * @dev Deploys a SmartAccount for `owner` using CREATE2.
     *      If the account already exists, returns the existing address (idempotent).
     *      The bundler calls this via the `initCode` field in a UserOperation
     *      when the wallet is being used for the very first time.
     */
    function createAccount(address owner, uint256 salt) external returns (SmartAccount account) {
        address predicted = getAddress(owner, salt);

        // If already deployed, return it — no revert, no duplicate
        if (predicted.code.length > 0) {
            return SmartAccount(payable(predicted));
        }

        if (ownerToAccount[owner] != address(0)) {
            revert AccountAlreadyExists(owner, ownerToAccount[owner]);
        }

        account = new SmartAccount{salt: bytes32(salt)}(owner, entryPoint);

        ownerToAccount[owner] = address(account);

        emit AccountCreated(owner, address(account), salt);
    }

    // ── Views ────────────────────────────────────────────────────

    /**
     * @dev Computes the counterfactual address of a SmartAccount before it is deployed.
     *      This is how ERC-4337 works — the address exists and can receive funds
     *      even before the first transaction deploys the contract.
     */
    function getAddress(address owner, uint256 salt) public view returns (address) {
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(
                type(SmartAccount).creationCode,
                abi.encode(owner, entryPoint)
            )
        );

        return address(uint160(uint256(keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                bytes32(salt),
                bytecodeHash
            )
        ))));
    }

    function getAccountForOwner(address owner) external view returns (address) {
        return ownerToAccount[owner];
    }
}
