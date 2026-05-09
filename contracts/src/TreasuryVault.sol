// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC3643 } from "./interfaces/IERC3643.sol";

/// @title TreasuryVault
/// @notice Treasury vault that holds ERC-3643 tokens and enforces holder-side
///         compliance policies (pause, counterparty whitelist, per-asset exposure
///         caps, daily caps per counterparty) before delegating to the token's
///         own ERC-3643 compliance layer.
/// @dev Vault pattern: the contract OWNS the tokens and is the single entry
///      point for transfers. The agent (AGENT_ROLE) can only act through this
///      contract - no token transfers can bypass these policies. Production
///      hardening (multisig admin, timelocks, SafeERC20, ONCHAINID) is
///      deliberately out of scope for this reference implementation.
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
    mapping(address => mapping(uint256 => uint256)) private _dailySpent;
    mapping(address => uint256) private _exposureCaps;
    mapping(address => mapping(uint256 => uint256)) private _assetDailySpent;

    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event TransferExecuted(address indexed token, address indexed to, uint256 amount, address indexed by);
    event CounterpartyAdded(address indexed counterparty, uint256 dailyCap);
    event CounterpartyDeactivated(address indexed counterparty);
    event TransferRejected(
        address indexed token, address indexed to, uint256 amount, RejectReason reason, bytes detail
    );
    event ExposureCapSet(address indexed asset, uint256 cap);

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
    /// @dev Check order: pause → whitelist → daily cap → exposure cap → token.transfer().
    ///      Rejected transfers emit TransferRejected (no revert) so the agent
    ///      can read the reason off-chain.
    /// @param token The ERC-3643 token to transfer.
    /// @param to The recipient counterparty.
    /// @param amount The token amount.
    function executeTransfer(address token, address to, uint256 amount) external onlyRole(AGENT_ROLE) whenNotPaused {
        // Gate 1: Counterparty whitelist
        if (!_counterparties[to].active) {
            emit TransferRejected(token, to, amount, RejectReason.NotWhitelisted, "");
            return;
        }

        // Gate 2: Daily cap per counterparty
        uint256 dayBucket = block.timestamp / 1 days;
        uint256 spent = _dailySpent[to][dayBucket];
        if (spent + amount > _counterparties[to].dailyCap) {
            emit TransferRejected(token, to, amount, RejectReason.DailyCapExceeded, "");
            return;
        }

        // Gate 3: Per-asset exposure cap (0 = no limit)
        uint256 assetCap = _exposureCaps[token];
        uint256 assetSpent = _assetDailySpent[token][dayBucket];
        if (assetCap > 0 && assetSpent + amount > assetCap) {
            emit TransferRejected(token, to, amount, RejectReason.ExposureCapExceeded, "");
            return;
        }

        // Gate 4: ERC-3643 compliance (identity + token-level rules)
        try IERC3643(token).transfer(to, amount) returns (bool success) {
            if (!success) {
                emit TransferRejected(token, to, amount, RejectReason.ERC3643Compliance, "");
                return;
            }
            _dailySpent[to][dayBucket] = spent + amount;
            _assetDailySpent[token][dayBucket] = assetSpent + amount;
            emit TransferExecuted(token, to, amount, msg.sender);
        } catch (bytes memory reason) {
            emit TransferRejected(token, to, amount, RejectReason.ERC3643Compliance, reason);
        }
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

    /// @notice Set the daily outflow limit for a specific asset.
    /// @dev 0 = no limit. Only TREASURER_ROLE can call. Emits ExposureCapSet.
    /// @param asset The token address to cap.
    /// @param cap The maximum total amount transferable per day (0 = unlimited).
    function setExposureCap(address asset, uint256 cap) external onlyRole(TREASURER_ROLE) {
        _exposureCaps[asset] = cap;
        emit ExposureCapSet(asset, cap);
    }

    /// @notice Read the exposure cap for an asset.
    /// @param asset The token address to query.
    /// @return The daily outflow cap (0 = no limit).
    function getExposureCap(address asset) external view returns (uint256) {
        return _exposureCaps[asset];
    }
}
