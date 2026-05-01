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
    struct Counterparty {
        bool active;
        uint256 dailyCap;
        uint256 addedAt;
    }

    enum RejectReason {
        None,
        Paused,
        NotWhitelisted,
        ExposureCapExceeded,
        DailyCapExceeded,
        ERC3643Compliance
    }

    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");
    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    bool private _paused;
    mapping(address => Counterparty) private _counterparties;

    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event TransferExecuted(address indexed token, address indexed to, uint256 amount, address indexed by);
    event CounterpartyAdded(address indexed counterparty, uint256 dailyCap);
    event CounterpartyDeactivated(address indexed counterparty);
    event TransferRejected(
        address indexed token, address indexed to, uint256 amount, RejectReason reason, bytes detail
    );

    error VaultPaused();
    error InvalidCounterparty();
    error CounterpartyAlreadyActive();
    error CounterpartyNotActive();

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
    /// @dev Pause + whitelist enforced. Exposure cap + daily cap + ERC-3643
    ///      transfer wiring come in later phases.
    /// @param token The ERC-3643 token to transfer.
    /// @param to The recipient counterparty.
    /// @param amount The token amount.
    function executeTransfer(address token, address to, uint256 amount) external onlyRole(AGENT_ROLE) whenNotPaused {
        if (!_counterparties[to].active) {
            emit TransferRejected(token, to, amount, RejectReason.NotWhitelisted, "");
            return;
        }
        emit TransferExecuted(token, to, amount, msg.sender);
    }

    /// @notice Add a counterparty to the whitelist with a per-day transfer cap.
    /// @dev Reverts on zero address or if the counterparty is already active.
    ///      Emits CounterpartyAdded.
    /// @param cp The counterparty address to whitelist.
    /// @param dailyCap The maximum amount transferable to this counterparty per day bucket.
    function addCounterparty(address cp, uint256 dailyCap) external onlyRole(TREASURER_ROLE) {
        if (cp == address(0)) revert InvalidCounterparty();
        if (_counterparties[cp].active) revert CounterpartyAlreadyActive();
        _counterparties[cp] = Counterparty({ active: true, dailyCap: dailyCap, addedAt: block.timestamp });
        emit CounterpartyAdded(cp, dailyCap);
    }

    /// @notice Deactivate a counterparty. Preserves addedAt for audit trail.
    /// @dev Sets active=false instead of deleting the struct, so off-chain auditors
    ///      can still reconstruct when this counterparty was added.
    /// @param cp The counterparty address to deactivate.
    function deactivateCounterparty(address cp) external onlyRole(TREASURER_ROLE) {
        if (!_counterparties[cp].active) revert CounterpartyNotActive();
        _counterparties[cp].active = false;
        emit CounterpartyDeactivated(cp);
    }

    /// @notice Read the full counterparty record (active flag, dailyCap, addedAt).
    /// @param cp The counterparty address to query.
    /// @return The full Counterparty struct (zero-valued if never added).
    function getCounterparty(address cp) external view returns (Counterparty memory) {
        return _counterparties[cp];
    }
}
