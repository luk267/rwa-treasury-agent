// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TreasuryVault } from "../../src/TreasuryVault.sol";
import { MockERC3643 } from "../mocks/MockERC3643.sol";

/// @title VaultHandler
/// @notice Drives the TreasuryVault with random but valid calls during invariant runs and keeps
///         its own ledger of what moved.
/// @dev The invariant suite lets Foundry call only this contract. Each action turns fuzzed numbers
///      into a call the vault sees in practice: the agent's transfer, a jump in time, an issuer
///      action on the token, or the treasurer raising a cap. The ledger is written from what the
///      handler observes, never copied from the vault's own counters.
///      With fail_on_revert = false, Foundry also ignores a failed assertion inside a handler call,
///      because the assertion reverts. So the checks in this contract record a violation instead of
///      reverting, and the invariant suite asserts that none was recorded.
contract VaultHandler is Test {
    /// @dev The state of one (token, counterparty) pair around a transfer.
    struct Snapshot {
        uint256 vaultBalance;
        uint256 counterpartyBalance;
        uint256 spent;
        uint256 assetSpent;
        uint256 counterpartyCap;
        uint256 assetCap;
        bool assetAllowed;
        bool counterpartyActive;
    }

    uint256 internal constant MAX_TRANSFER = 2500e18;
    uint256 internal constant MAX_RAISE = 3000e18;
    uint256 internal constant MAX_WARP = 2 days;

    TreasuryVault public immutable VAULT;
    address public immutable AGENT;
    address public immutable TREASURER;
    address public immutable ISSUER;

    /// @dev Every token the agent may name, allowed or not.
    address[] internal _tokens;
    /// @dev The tokens whose issuer agent is ISSUER.
    MockERC3643[] internal _issuerTokens;
    /// @dev Whitelisted counterparties and addresses the treasurer never added.
    address[] internal _counterparties;

    // ── Ledger ───────────────────────────────────────────────────────

    /// @notice Executed amount per counterparty, token and day bucket.
    mapping(address cp => mapping(address token => mapping(uint256 day => uint256))) public executedToCounterparty;
    /// @notice Executed amount per token and day bucket, over all counterparties.
    mapping(address token => mapping(uint256 day => uint256)) public executedOfToken;
    /// @notice Executed amount per token since the start of the run.
    mapping(address token => uint256) public totalExecuted;
    /// @notice Amount the issuer moved out of the vault per token since the start of the run.
    mapping(address token => uint256) public totalForced;

    // ── Call statistics ──────────────────────────────────────────────

    /// @notice Number of transfer actions, and how each one ended.
    uint256 public transfers;
    uint256 public executed;
    uint256 public rejected;
    uint256 public reverted;
    /// @notice Number of rejections per reason.
    mapping(TreasuryVault.RejectReason reason => uint256) public rejectedBy;
    /// @notice Number of the other actions.
    uint256 public warps;
    uint256 public issuerToggles;
    uint256 public forcedTransfers;
    uint256 public capRaises;

    // ── Checks inside actions ────────────────────────────────────────

    /// @notice Number of checks inside actions that failed.
    uint256 public failedChecks;
    /// @notice The first check that failed, empty if none.
    string public firstFailedCheck;

    /// @param vault The vault under test.
    /// @param agent Holder of AGENT_ROLE.
    /// @param treasurer Holder of TREASURER_ROLE.
    /// @param issuer Issuer agent of every token in `issuerTokens`.
    /// @param tokens Every token the agent may name.
    /// @param issuerTokens The tokens the issuer controls.
    /// @param counterparties Whitelisted counterparties and outsiders.
    constructor(
        TreasuryVault vault,
        address agent,
        address treasurer,
        address issuer,
        address[] memory tokens,
        MockERC3643[] memory issuerTokens,
        address[] memory counterparties
    ) {
        VAULT = vault;
        AGENT = agent;
        TREASURER = treasurer;
        ISSUER = issuer;
        _tokens = tokens;
        _issuerTokens = issuerTokens;
        _counterparties = counterparties;
    }

    // ── Actions ──────────────────────────────────────────────────────

    /// @notice The agent asks the vault to send 1 to 2500 whole tokens to a counterparty.
    /// @dev Whole tokens, because the fuzzer often supplies small values that `bound` passes
    ///      through unchanged: as wei they would be dust that never reaches a cap. The fuzz suite
    ///      covers the cap boundary down to one wei.
    ///      An executed transfer must have passed every vault gate, measured on the state before
    ///      the call, and must move exactly `amount`. A rejection must change nothing. A revert is
    ///      counted; none is expected, because the amount is never zero and the vault is never
    ///      paused here.
    /// @param tokenSeed Picks the token.
    /// @param cpSeed Picks the counterparty.
    /// @param amount The amount in whole tokens, bounded to [1, 2500].
    function transfer(uint256 tokenSeed, uint256 cpSeed, uint256 amount) external {
        address token = _tokens[tokenSeed % _tokens.length];
        address cp = _counterparties[cpSeed % _counterparties.length];
        amount = bound(amount, 1, MAX_TRANSFER / 1e18) * 1e18;
        transfers++;

        Snapshot memory before = _snapshot(token, cp);
        vm.prank(AGENT);
        try VAULT.executeTransfer(token, cp, amount) returns (
            bool ok, TreasuryVault.RejectReason reason, bytes memory
        ) {
            Snapshot memory afterCall = _snapshot(token, cp);
            if (ok) _bookExecuted(token, cp, amount, before, afterCall);
            else _checkRejected(reason, before, afterCall);
        } catch {
            reverted++;
        }
    }

    /// @notice Move time forward by up to two days, so transfers fall into new day buckets.
    /// @param secondsAhead Seconds to move, bounded to [0, 2 days].
    function warp(uint256 secondsAhead) external {
        secondsAhead = bound(secondsAhead, 0, MAX_WARP);
        warps++;
        vm.warp(block.timestamp + secondsAhead);
    }

    /// @notice The issuer changes one token-side rule.
    /// @dev `kind % 4` picks the rule: 0 verification of a counterparty, 1 freeze of the vault or
    ///      a counterparty, 2 token pause, 3 compliance verdict. One call in eight sets the
    ///      blocking state, the others clear it, so most transfers still reach the token.
    /// @param kind Picks the rule.
    /// @param seed Picks the token, the new state and the wallet.
    function issuerToggle(uint256 kind, uint256 seed) external {
        MockERC3643 token = _issuerTokens[seed % _issuerTokens.length];
        seed /= _issuerTokens.length;
        bool blocking = seed % 8 == 0;
        seed /= 8;
        address cp = _counterparties[seed % _counterparties.length];
        seed /= _counterparties.length;
        issuerToggles++;

        uint256 rule = kind % 4;
        bool tokenPaused = token.paused();
        vm.startPrank(ISSUER);
        if (rule == 0) {
            token.setVerified(cp, !blocking);
        } else if (rule == 1) {
            token.setAddressFrozen(seed % 2 == 0 ? address(VAULT) : cp, blocking);
        } else if (rule == 2) {
            if (blocking && !tokenPaused) token.pause();
            if (!blocking && tokenPaused) token.unpause();
        } else {
            token.setCompliance(!blocking);
        }
        vm.stopPrank();
    }

    /// @notice The issuer takes tokens out of the vault with a forced transfer, bypassing it.
    /// @dev The vault's balance must drop by `amount` and its counters must not move.
    /// @param tokenSeed Picks the token.
    /// @param amount The amount, bounded to [1, min(balance, 2500e18)].
    function issuerForcedTransfer(uint256 tokenSeed, uint256 amount) external {
        MockERC3643 token = _issuerTokens[tokenSeed % _issuerTokens.length];
        uint256 balance = token.balanceOf(address(VAULT));
        if (balance == 0) return;
        amount = bound(amount, 1, balance < MAX_TRANSFER ? balance : MAX_TRANSFER);
        uint256 assetSpent = VAULT.assetSpentToday(address(token));
        forcedTransfers++;

        vm.prank(ISSUER);
        bool ok = token.forcedTransfer(address(VAULT), ISSUER, amount);
        totalForced[address(token)] += amount;

        _check(ok, "forced transfer returned false");
        _check(token.balanceOf(address(VAULT)) + amount == balance, "forced transfer moved a different amount");
        _check(VAULT.assetSpentToday(address(token)) == assetSpent, "forced transfer changed the asset counter");
    }

    /// @notice The treasurer raises a daily cap: one counterparty's cap for one token, or a
    ///         token's outflow cap.
    /// @dev Caps only go up here. A lowered cap can sit below what was already spent today, and
    ///      the cap invariants would then flag a correct vault. Unit tests cover lowering.
    /// @param seed Picks the token, the kind of cap and the counterparty.
    /// @param cap The increase, bounded to [1, 3000e18].
    function treasurerRaiseCap(uint256 seed, uint256 cap) external {
        address token = _tokens[seed % _tokens.length];
        seed /= _tokens.length;
        bool assetCap = seed % 2 == 0;
        seed /= 2;
        address cp = _counterparties[seed % _counterparties.length];

        TreasuryVault.AssetConfig memory asset = VAULT.getAssetConfig(token);
        uint256 current = assetCap ? asset.dailyOutflowCap : VAULT.getCounterpartyDailyCap(cp, token);
        // Unlimited, or close enough that the raise would overflow.
        if (current > type(uint256).max - MAX_RAISE) return;
        uint256 raised = current + bound(cap, 1, MAX_RAISE);
        capRaises++;

        vm.prank(TREASURER);
        if (assetCap) VAULT.setAssetConfig(token, asset.allowed, raised);
        else VAULT.setCounterpartyDailyCap(cp, token, raised);
    }

    // ── Internals ────────────────────────────────────────────────────

    function _snapshot(address token, address cp) private view returns (Snapshot memory s) {
        TreasuryVault.AssetConfig memory asset = VAULT.getAssetConfig(token);
        s.vaultBalance = IERC20(token).balanceOf(address(VAULT));
        s.counterpartyBalance = IERC20(token).balanceOf(cp);
        s.spent = VAULT.spentToday(cp, token);
        s.assetSpent = VAULT.assetSpentToday(token);
        s.counterpartyCap = VAULT.getCounterpartyDailyCap(cp, token);
        s.assetCap = asset.dailyOutflowCap;
        s.assetAllowed = asset.allowed;
        s.counterpartyActive = VAULT.getCounterparty(cp).active;
    }

    function _bookExecuted(address token, address cp, uint256 amount, Snapshot memory before, Snapshot memory afterCall)
        private
    {
        uint256 day = block.timestamp / 1 days;
        executedToCounterparty[cp][token][day] += amount;
        executedOfToken[token][day] += amount;
        totalExecuted[token] += amount;
        executed++;

        _check(before.assetAllowed, "executed a token that is not allowed");
        _check(before.counterpartyActive, "executed to a counterparty that is not active");
        _check(before.spent + amount <= before.counterpartyCap, "executed above the counterparty cap");
        _check(before.assetSpent + amount <= before.assetCap, "executed above the token cap");
        _check(afterCall.vaultBalance + amount == before.vaultBalance, "vault balance did not drop by amount");
        _check(
            afterCall.counterpartyBalance == before.counterpartyBalance + amount, "counterparty did not receive amount"
        );
    }

    function _checkRejected(TreasuryVault.RejectReason reason, Snapshot memory before, Snapshot memory afterCall)
        private
    {
        rejected++;
        rejectedBy[reason]++;

        _check(reason != TreasuryVault.RejectReason.None, "rejected with reason None");
        _check(afterCall.vaultBalance == before.vaultBalance, "rejection moved vault tokens");
        _check(afterCall.counterpartyBalance == before.counterpartyBalance, "rejection paid the counterparty");
        _check(afterCall.spent == before.spent, "rejection changed the counterparty counter");
        _check(afterCall.assetSpent == before.assetSpent, "rejection changed the token counter");
    }

    function _check(bool ok, string memory what) private {
        if (ok) return;
        if (failedChecks == 0) firstFailedCheck = what;
        failedChecks++;
    }
}
