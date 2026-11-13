// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IERC3643 } from "./interfaces/IERC3643.sol";

/// @title TreasuryVault
/// @notice Treasury vault that holds ERC-3643 tokens and enforces holder-side
///         policies (token allowlist, counterparty whitelist, daily cap per
///         counterparty and token, daily outflow cap per token) before delegating
///         to the token's own ERC-3643 compliance layer.
/// @dev Vault pattern: the contract OWNS the tokens, so executeTransfer is the only
///      way for the AI agent (AGENT_ROLE) to move them, and every such transfer
///      passes these policies. Every policy is default-deny: a token must be allowed,
///      a counterparty must be active, and a cap that was never set is zero.
///      "Unlimited" is the explicit value type(uint256).max. The token issuer is not
///      bound by these policies: ERC-3643 lets the issuer's agents force transfers,
///      freeze, pause, recover and burn directly on the vault's balance. The vault
///      must be registered and verified in the token's identity registry before it
///      can receive tokens. Each role is assigned to its own account at construction.
///      The admin role follows OpenZeppelin's AccessControlDefaultAdminRules: a single
///      admin, handed over in two steps with a delay. A multisig admin and SafeERC20
///      are out of scope for this reference implementation.
contract TreasuryVault is AccessControlDefaultAdminRules, ReentrancyGuardTransient {
    struct AssetConfig {
        bool allowed;
        uint256 dailyOutflowCap;
    }

    struct Counterparty {
        bool active;
        uint256 addedAt;
    }

    enum RejectReason {
        None,
        AssetNotAllowed,
        NotWhitelisted,
        DailyCapExceeded,
        AssetDailyCapExceeded,
        ERC3643Compliance
    }

    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");
    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    bool private _paused;
    mapping(address token => AssetConfig) private _assets;
    mapping(address cp => Counterparty) private _counterparties;
    mapping(address cp => mapping(address token => uint256)) private _counterpartyDailyCaps;
    mapping(address cp => mapping(address token => mapping(uint256 day => uint256))) private _dailySpent;
    mapping(address token => mapping(uint256 day => uint256)) private _assetDailySpent;

    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event TransferExecuted(address indexed token, address indexed to, uint256 amount, address indexed by);
    event AssetConfigSet(address indexed token, bool allowed, uint256 dailyOutflowCap);
    event CounterpartyAdded(address indexed counterparty);
    event CounterpartyDeactivated(address indexed counterparty);
    event CounterpartyDailyCapSet(address indexed counterparty, address indexed token, uint256 dailyCap);
    event TransferRejected(
        address indexed token, address indexed to, uint256 amount, RejectReason reason, bytes detail
    );

    error VaultPaused();
    error InvalidCounterparty();
    error CounterpartyAlreadyActive();
    error CounterpartyNotActive();
    error ZeroAddress();
    error ZeroAmount();
    error TokenTransferFailedWithoutReason(address token);

    /// @notice Assigns each role to the account passed in. The deployer gets no role
    ///         unless it is passed explicitly.
    /// @dev The base constructor rejects a zero `admin` with AccessControlInvalidDefaultAdmin.
    ///      The other three roles revert with ZeroAddress. Emits RoleGranted per role.
    /// @param adminTransferDelay Seconds a new admin must wait before accepting the handover.
    /// @param admin Holder of DEFAULT_ADMIN_ROLE: grants and revokes the other roles.
    /// @param treasurer Holder of TREASURER_ROLE: manages the token allowlist, counterparties and caps.
    /// @param agent Holder of AGENT_ROLE: the only account that can call executeTransfer.
    /// @param pauser Holder of PAUSER_ROLE: can pause and unpause the vault.
    constructor(uint48 adminTransferDelay, address admin, address treasurer, address agent, address pauser)
        AccessControlDefaultAdminRules(adminTransferDelay, admin)
    {
        if (treasurer == address(0) || agent == address(0) || pauser == address(0)) revert ZeroAddress();
        _grantRole(TREASURER_ROLE, treasurer);
        _grantRole(AGENT_ROLE, agent);
        _grantRole(PAUSER_ROLE, pauser);
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
    /// @dev Check order: re-entrancy → role → pause → amount → token allowed →
    ///      counterparty active → daily cap per counterparty and token →
    ///      daily outflow cap per token → token.transfer(). A missing role, a paused
    ///      vault, a re-entrant call or a zero amount reverts. A policy rejection
    ///      (gates 1-5) emits TransferRejected and returns the same values without
    ///      reverting, so it stays in the log with a typed reason. A token that fails
    ///      without giving a reason (empty revert data, which includes running out of
    ///      gas, or a `false` return) reverts with TokenTransferFailedWithoutReason.
    ///      See docs/adr/0001-emit-instead-of-revert.md.
    /// @param token The ERC-3643 token to transfer.
    /// @param to The recipient counterparty.
    /// @param amount The token amount. Must not be zero.
    /// @return executed True if the tokens moved and TransferExecuted was emitted.
    /// @return reason The gate that refused the transfer, or None if it was executed.
    /// @return detail For ERC3643Compliance, the token's revert data; empty otherwise.
    // `token` must be allowed by the treasurer (gate 1) before anything is written for it.
    // forge-lint: disable-next-line(missing-zero-check)
    function executeTransfer(address token, address to, uint256 amount)
        external
        nonReentrant
        onlyRole(AGENT_ROLE)
        whenNotPaused
        returns (bool executed, RejectReason reason, bytes memory detail)
    {
        if (amount == 0) revert ZeroAmount();

        // Gate 1: Token allowlist
        AssetConfig memory asset = _assets[token];
        if (!asset.allowed) return _reject(token, to, amount, RejectReason.AssetNotAllowed, "");

        // Gate 2: Counterparty whitelist
        if (!_counterparties[to].active) return _reject(token, to, amount, RejectReason.NotWhitelisted, "");

        // Gate 3: Daily cap per counterparty and token
        uint256 dayBucket = block.timestamp / 1 days;
        uint256 spent = _dailySpent[to][token][dayBucket];
        if (_exceedsCap(spent, amount, _counterpartyDailyCaps[to][token])) {
            return _reject(token, to, amount, RejectReason.DailyCapExceeded, "");
        }

        // Gate 4: Daily outflow cap per token, summed over all counterparties
        uint256 assetSpent = _assetDailySpent[token][dayBucket];
        if (_exceedsCap(assetSpent, amount, asset.dailyOutflowCap)) {
            return _reject(token, to, amount, RejectReason.AssetDailyCapExceeded, "");
        }

        // Gate 5: ERC-3643 compliance (identity + token-level rules)
        // Counters are written after the call on purpose: a rejected transfer must not consume a cap.
        // This breaks checks-effects-interactions, so nonReentrant blocks any call back into
        // executeTransfer while the token runs. The events report the token's result, so they
        // can only follow the call.
        // Gates 3 and 4 guarantee spent + amount <= cap, so the additions below cannot overflow.
        // forge-lint: disable-start(reentrancy-no-eth, reentrancy-events)
        try IERC3643(token).transfer(to, amount) returns (bool success) {
            if (!success) revert TokenTransferFailedWithoutReason(token);
            _dailySpent[to][token][dayBucket] = spent + amount;
            _assetDailySpent[token][dayBucket] = assetSpent + amount;
            emit TransferExecuted(token, to, amount, msg.sender);
            return (true, RejectReason.None, "");
        } catch (bytes memory tokenError) {
            // No data means no decision: an out-of-gas in the token lands here too (EIP-150
            // leaves the vault 1/64 of the gas). Only a reason from the token is logged.
            if (tokenError.length == 0) revert TokenTransferFailedWithoutReason(token);
            return _reject(token, to, amount, RejectReason.ERC3643Compliance, tokenError);
        }
        // forge-lint: disable-end(reentrancy-no-eth, reentrancy-events)
    }

    /// @notice Allow or block a token and set its daily outflow cap.
    /// @dev Only TREASURER_ROLE. A token that was never configured is not allowed.
    ///      The cap counts all counterparties together; 0 blocks every transfer,
    ///      type(uint256).max means unlimited. Emits AssetConfigSet.
    /// @param token The token address.
    /// @param allowed Whether executeTransfer may move this token at all.
    /// @param dailyOutflowCap The maximum total amount of this token per day bucket.
    function setAssetConfig(address token, bool allowed, uint256 dailyOutflowCap) external onlyRole(TREASURER_ROLE) {
        _assets[token] = AssetConfig({ allowed: allowed, dailyOutflowCap: dailyOutflowCap });
        emit AssetConfigSet(token, allowed, dailyOutflowCap);
    }

    /// @notice Read a token's configuration.
    /// @param token The token address to query.
    /// @return The AssetConfig (not allowed, cap 0 if never set).
    function getAssetConfig(address token) external view returns (AssetConfig memory) {
        return _assets[token];
    }

    /// @notice Add a counterparty to the whitelist, or reactivate a deactivated one.
    /// @dev Reverts on zero address or if the counterparty is already active. addedAt is
    ///      set only the first time, so the audit trail keeps the original date. Caps are
    ///      set per token with setCounterpartyDailyCap; caps set earlier apply again on
    ///      reactivation. Emits CounterpartyAdded.
    /// @param cp The counterparty address to whitelist.
    function addCounterparty(address cp) external onlyRole(TREASURER_ROLE) {
        if (cp == address(0)) revert InvalidCounterparty();
        Counterparty storage record = _counterparties[cp];
        if (record.active) revert CounterpartyAlreadyActive();
        record.active = true;
        if (record.addedAt == 0) record.addedAt = block.timestamp;
        emit CounterpartyAdded(cp);
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

    /// @notice Read the counterparty record (active flag, addedAt).
    /// @param cp The counterparty address to query.
    /// @return The full Counterparty struct (zero-valued if never added).
    function getCounterparty(address cp) external view returns (Counterparty memory) {
        return _counterparties[cp];
    }

    /// @notice Set how much of one token a counterparty may receive per day.
    /// @dev Only TREASURER_ROLE. Each token has its own cap and counter, because raw amounts
    ///      of tokens with different decimals cannot be added. 0 (the default) blocks the
    ///      token for this counterparty, type(uint256).max means unlimited.
    ///      Emits CounterpartyDailyCapSet.
    /// @param cp The counterparty address.
    /// @param token The token address.
    /// @param dailyCap The maximum amount of `token` transferable to `cp` per day bucket.
    function setCounterpartyDailyCap(address cp, address token, uint256 dailyCap) external onlyRole(TREASURER_ROLE) {
        _counterpartyDailyCaps[cp][token] = dailyCap;
        emit CounterpartyDailyCapSet(cp, token, dailyCap);
    }

    /// @notice Read a counterparty's daily cap for one token.
    /// @param cp The counterparty address.
    /// @param token The token address.
    /// @return The daily cap (0 if never set).
    function getCounterpartyDailyCap(address cp, address token) external view returns (uint256) {
        return _counterpartyDailyCaps[cp][token];
    }

    /// @notice How much of `token` went to `cp` in the current day bucket.
    /// @param cp The counterparty address.
    /// @param token The token address.
    /// @return The amount transferred today (UTC day bucket).
    function spentToday(address cp, address token) external view returns (uint256) {
        return _dailySpent[cp][token][block.timestamp / 1 days];
    }

    /// @notice How much of `token` left the vault in the current day bucket, over all counterparties.
    /// @param token The token address.
    /// @return The amount transferred today (UTC day bucket).
    function assetSpentToday(address token) external view returns (uint256) {
        return _assetDailySpent[token][block.timestamp / 1 days];
    }

    /// @dev Emit TransferRejected and return the same values, so the event and the return value
    ///      of executeTransfer always agree.
    function _reject(address token, address to, uint256 amount, RejectReason reason, bytes memory detail)
        private
        returns (bool, RejectReason, bytes memory)
    {
        // Gate 5 calls this after token.transfer; nonReentrant on executeTransfer covers it.
        // forge-lint: disable-next-line(reentrancy-events)
        emit TransferRejected(token, to, amount, reason, detail);
        return (false, reason, detail);
    }

    /// @dev True if `amount` does not fit into what is left of `cap`. Written so that it cannot
    ///      overflow, and so that a cap lowered below `spent` rejects instead of underflowing.
    function _exceedsCap(uint256 spent, uint256 amount, uint256 cap) private pure returns (bool) {
        return spent > cap || amount > cap - spent;
    }
}
