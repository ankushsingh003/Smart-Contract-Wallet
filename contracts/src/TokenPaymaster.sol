// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@account-abstraction/contracts/core/BasePaymaster.sol";
import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

contract Paymaster is BasePaymaster {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ── Constants ────────────────────────────────────────────────

    uint256 public constant COST_OF_POST = 40_000;  // estimated postOp gas overhead

    // ── Sponsorship modes ────────────────────────────────────────
    // Encoded in the first byte of userOp.paymasterAndData (after the paymaster address).
    //   0x00 = FREE       — paymaster covers gas entirely (e.g. for onboarding)
    //   0x01 = ERC20      — user pays gas in an ERC-20 token
    //   0x02 = ALLOWLIST  — only whitelisted wallets get free gas

    uint8 public constant MODE_FREE      = 0x00;
    uint8 public constant MODE_ERC20     = 0x01;
    uint8 public constant MODE_ALLOWLIST = 0x02;

    // ── State ────────────────────────────────────────────────────

    address public signer;                          // signs off-chain approvals
    IERC20  public gasToken;                        // ERC-20 used for MODE_ERC20
    uint256 public tokenPricePerGas;                // token units per 1 gas unit

    mapping(address => bool) public allowlist;
    mapping(address => uint256) public tokenBalances; // user deposits for ERC-20 mode

    // ── Events ───────────────────────────────────────────────────

    event GasSponsored(address indexed account, uint8 mode, uint256 gasCost);
    event AllowlistUpdated(address indexed account, bool allowed);
    event TokenDeposited(address indexed account, uint256 amount);
    event TokenWithdrawn(address indexed account, uint256 amount);
    event SignerUpdated(address indexed oldSigner, address indexed newSigner);

    // ── Errors ───────────────────────────────────────────────────

    error InvalidMode(uint8 mode);
    error NotAllowlisted(address account);
    error InvalidSignature();
    error InsufficientTokenBalance(address account, uint256 required, uint256 available);
    error InvalidDataLength();

    // ── Constructor ──────────────────────────────────────────────

    constructor(
        IEntryPoint _entryPoint,
        address     _signer,
        IERC20      _gasToken,
        uint256     _tokenPricePerGas
    ) BasePaymaster(_entryPoint) {
        signer            = _signer;
        gasToken          = _gasToken;
        tokenPricePerGas  = _tokenPricePerGas;
    }

    // ── Core ─────────────────────────────────────────────────────

    /**
     * @dev Called by EntryPoint before execution.
     *      We decode the mode from paymasterAndData and decide whether to sponsor.
     *      Returns `context` which is passed into postOp for final accounting.
     *
     *      paymasterAndData layout:
     *        [0:20]  — paymaster address (consumed by EntryPoint, not visible here)
     *        [20]    — mode byte (0x00 / 0x01 / 0x02)
     *        [21:]   — mode-specific data (signature for FREE, empty for others)
     */
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) internal override returns (bytes memory context, uint256 validationData) {

        if (userOp.paymasterAndData.length < 21) revert InvalidDataLength();

        uint8 mode = uint8(userOp.paymasterAndData[20]);

        if (mode == MODE_FREE) {
            _validateSignature(userOpHash, userOp.paymasterAndData[21:]);
            context = abi.encode(mode, userOp.sender, maxCost);

        } else if (mode == MODE_ERC20) {
            uint256 tokenCost = _tokenCost(maxCost);
            if (tokenBalances[userOp.sender] < tokenCost) {
                revert InsufficientTokenBalance(userOp.sender, tokenCost, tokenBalances[userOp.sender]);
            }
            context = abi.encode(mode, userOp.sender, maxCost);

        } else if (mode == MODE_ALLOWLIST) {
            if (!allowlist[userOp.sender]) revert NotAllowlisted(userOp.sender);
            context = abi.encode(mode, userOp.sender, maxCost);

        } else {
            revert InvalidMode(mode);
        }

        return (context, 0);
    }

    /**
     * @dev Called by EntryPoint after execution.
     *      actualGasCost is the true gas used. We do final token deduction here
     *      for ERC-20 mode, and emit a sponsorship event for all modes.
     */
    function _postOp(
        PostOpMode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256
    ) internal override {
        (uint8 mode, address account,) = abi.decode(context, (uint8, address, uint256));

        if (mode == MODE_ERC20) {
            uint256 tokenCost = _tokenCost(actualGasCost + COST_OF_POST);
            tokenBalances[account] -= tokenCost;
        }

        emit GasSponsored(account, mode, actualGasCost);
    }

    // ── Token Deposits ───────────────────────────────────────────

    function depositToken(uint256 amount) external {
        gasToken.transferFrom(msg.sender, address(this), amount);
        tokenBalances[msg.sender] += amount;
        emit TokenDeposited(msg.sender, amount);
    }

    function withdrawToken(uint256 amount) external {
        tokenBalances[msg.sender] -= amount;
        gasToken.transfer(msg.sender, amount);
        emit TokenWithdrawn(msg.sender, amount);
    }

    // ── Admin ────────────────────────────────────────────────────

    function setAllowlist(address account, bool allowed) external onlyOwner {
        allowlist[account] = allowed;
        emit AllowlistUpdated(account, allowed);
    }

    function setAllowlistBatch(address[] calldata accounts, bool allowed) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; ) {
            allowlist[accounts[i]] = allowed;
            emit AllowlistUpdated(accounts[i], allowed);
            unchecked { i++; }
        }
    }

    function setSigner(address newSigner) external onlyOwner {
        emit SignerUpdated(signer, newSigner);
        signer = newSigner;
    }

    function setTokenPrice(uint256 newPrice) external onlyOwner {
        tokenPricePerGas = newPrice;
    }

    // ── Internal ─────────────────────────────────────────────────

    function _validateSignature(bytes32 userOpHash, bytes calldata sig) internal view {
        address recovered = userOpHash.toEthSignedMessageHash().recover(sig);
        if (recovered != signer) revert InvalidSignature();
    }

    function _tokenCost(uint256 gasCost) internal view returns (uint256) {
        return gasCost * tokenPricePerGas;
    }

    // ── Views ────────────────────────────────────────────────────

    function getTokenBalance(address account) external view returns (uint256) {
        return tokenBalances[account];
    }

    function isAllowlisted(address account) external view returns (bool) {
        return allowlist[account];
    }
}
