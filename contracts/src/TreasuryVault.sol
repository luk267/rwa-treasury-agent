// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title TreasuryVault
/// @notice Treasury vault that holds ERC-3643 tokens and enforces holder-side
///         compliance policies (pause, counterparty whitelist, per-asset exposure
///         caps, daily caps per counterparty) before delegating to the token's
///         own ERC-3643 compliance layer.
/// @dev Vault pattern: the contract OWNS the tokens and is the single entry
///      point for transfers. The agent (AGENT_ROLE) can only act through this
///      contract — no token transfers can bypass these policies. Designed for
///      ETHGlobal Open Agents 2026 demo; production hardening (multisig admin,
///      timelocks, SafeERC20, ONCHAINID) is deliberately out of scope here.
contract TreasuryVault is AccessControl {
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");
    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    bool private _paused;

    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event TransferExecuted(address indexed token, address indexed to, uint256 amount, address indexed by);

    error VaultPaused();

    /// @notice Grants the deployer all four roles for the demo. Production setups
    ///         must split these (Treasurer = multisig, Pauser = hot-key, etc.).
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(TREASURER_ROLE, msg.sender);
        _grantRole(AGENT_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
    }

    modifier whenNotPaused() {
        _requireNotPaused();
        _;
    }

    function _requireNotPaused() internal view {
        if (_paused) revert VaultPaused();
    }

    /// @notice Pause the vault. Reverts all executeTransfer calls until unpaused.
    /// @dev Restricted to PAUSER_ROLE. Emits Paused(by).
    function pause() external onlyRole(PAUSER_ROLE) {
        _paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpause the vault.
    /// @dev Restricted to PAUSER_ROLE. Emits Unpaused(by).
    function unpause() external onlyRole(PAUSER_ROLE) {
        _paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Returns whether the vault is currently paused.
    function paused() external view returns (bool) {
        return _paused;
    }

    /// @notice Execute a token transfer through the vault's policy gate.
    /// @dev Skeleton stub — emits TransferExecuted only. Real
    ///      whitelist / cap / token-transfer logic is added in the next step.
    /// @param token The ERC-3643 token to transfer.
    /// @param to The recipient counterparty.
    /// @param amount The token amount.
    function executeTransfer(address token, address to, uint256 amount) external onlyRole(AGENT_ROLE) whenNotPaused {
        emit TransferExecuted(token, to, amount, msg.sender);
    }
}
