// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { Test, console } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TreasuryVault } from "../../src/TreasuryVault.sol";
import { MockERC3643 } from "../mocks/MockERC3643.sol";
import { ReentrantToken } from "../mocks/ReentrantToken.sol";
import { VaultHandler } from "./VaultHandler.sol";

/// @dev Properties that must hold after any sequence of agent transfers, time jumps, issuer
///      actions, cap raises and counterparties switched off and on. Foundry calls only the handler; the handler books what moved.
///      Each invariant compares the vault with that ledger or with its own caps.
contract TreasuryVaultInvariants is Test {
    uint256 constant UNLIMITED = type(uint256).max;

    address admin = makeAddr("admin");
    address treasurer = makeAddr("treasurer");
    address agent = makeAddr("agent");
    address pauser = makeAddr("pauser");
    address issuer = makeAddr("issuer");

    address cp0 = makeAddr("cp0");
    address cp1 = makeAddr("cp1");
    address cp2 = makeAddr("cp2");
    /// @dev Verified by the issuer and given caps, but never whitelisted: only gate 2 stops it.
    address outsider = makeAddr("outsider");

    TreasuryVault vault;
    VaultHandler handler;

    address[] internal _tokens;
    address[] internal _counterparties;
    mapping(address token => uint256) internal _funding;

    function setUp() public {
        vault = new TreasuryVault(1 days, admin, treasurer, agent, pauser);
        _counterparties = [cp0, cp1, cp2, outsider];

        // The issuer deploys three ERC-3643 tokens and funds the vault.
        vm.startPrank(issuer);
        MockERC3643 tokenA = _newIssuerToken(20_000e18);
        MockERC3643 tokenB = _newIssuerToken(15_000e18);
        // Funded and verified, but the treasurer never allows it: only gate 1 stops it.
        MockERC3643 foreign = _newIssuerToken(10_000e18);
        vm.stopPrank();

        // Worst case from the threat model: a token that holds AGENT_ROLE and calls back into
        // executeTransfer during its own transfer.
        ReentrantToken reentrant = new ReentrantToken(vault);
        assertTrue(reentrant.transfer(address(vault), 10_000e18));
        _funding[address(reentrant)] = 10_000e18;
        bytes32 agentRole = vault.AGENT_ROLE();
        vm.prank(admin);
        vault.grantRole(agentRole, address(reentrant));

        _tokens = [address(tokenA), address(tokenB), address(foreign), address(reentrant)];

        vm.startPrank(treasurer);
        vault.addCounterparty(cp0);
        vault.addCounterparty(cp1);
        vault.addCounterparty(cp2);

        // Token A: the token cap (gate 4) binds for cp1 and cp2, the counterparty cap (gate 3) for cp0.
        vault.setAssetConfig(address(tokenA), true, 2000e18);
        _setCaps(address(tokenA), 1000e18, 3000e18, UNLIMITED);
        // Token B: no token cap, so only gate 3 and the vault's balance limit it. cp2 has no cap
        // of its own and cannot receive B.
        vault.setAssetConfig(address(tokenB), true, UNLIMITED);
        _setCaps(address(tokenB), UNLIMITED, 1500e18, 0);
        // Foreign: every cap is open; the allowlist alone must stop it.
        vault.setAssetConfig(address(foreign), false, UNLIMITED);
        _setCaps(address(foreign), UNLIMITED, UNLIMITED, UNLIMITED);
        // Reentrant: allowed, so its call back into the vault is reached.
        vault.setAssetConfig(address(reentrant), true, UNLIMITED);
        _setCaps(address(reentrant), 2000e18, UNLIMITED, 0);
        vm.stopPrank();

        MockERC3643[] memory issuerTokens = new MockERC3643[](3);
        issuerTokens[0] = tokenA;
        issuerTokens[1] = tokenB;
        issuerTokens[2] = foreign;
        handler = new VaultHandler(vault, agent, treasurer, issuer, _tokens, issuerTokens, _counterparties);

        // Foundry picks uniformly from this list. The transfer is listed three times, so three in
        // eight calls are transfers and several of them fall into the same day bucket.
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = VaultHandler.transfer.selector;
        selectors[1] = VaultHandler.transfer.selector;
        selectors[2] = VaultHandler.transfer.selector;
        selectors[3] = VaultHandler.warp.selector;
        selectors[4] = VaultHandler.issuerToggle.selector;
        selectors[5] = VaultHandler.issuerForcedTransfer.selector;
        selectors[6] = VaultHandler.treasurerRaiseCap.selector;
        selectors[7] = VaultHandler.treasurerToggleCounterparty.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    /// @dev Deploys a token as the issuer, verifies the vault and every counterparty, and moves
    ///      `funding` into the vault. Call between vm.startPrank(issuer) and vm.stopPrank().
    function _newIssuerToken(uint256 funding) internal returns (MockERC3643 token) {
        token = new MockERC3643();
        token.setVerified(address(vault), true);
        token.setVerified(cp0, true);
        token.setVerified(cp1, true);
        token.setVerified(cp2, true);
        token.setVerified(outsider, true);
        assertTrue(token.transfer(address(vault), funding));
        _funding[address(token)] = funding;
    }

    /// @dev Caps for cp0, cp1 and cp2. The outsider gets no limit, so only gate 2 stops it.
    function _setCaps(address token, uint256 cap0, uint256 cap1, uint256 cap2) internal {
        if (cap0 != 0) vault.setCounterpartyDailyCap(cp0, token, cap0);
        if (cap1 != 0) vault.setCounterpartyDailyCap(cp1, token, cap1);
        if (cap2 != 0) vault.setCounterpartyDailyCap(cp2, token, cap2);
        vault.setCounterpartyDailyCap(outsider, token, UNLIMITED);
    }

    // ── Invariants ───────────────────────────────────────────────────

    /// @dev No counterparty gets more of a token in one day than its cap. Caps only rise in the
    ///      handler, so today's cap bounds everything executed today.
    function invariant_counterpartyDailyCapNeverExceeded() external view {
        uint256 today = block.timestamp / 1 days;
        for (uint256 i = 0; i < _tokens.length; i++) {
            for (uint256 j = 0; j < _counterparties.length; j++) {
                address token = _tokens[i];
                address cp = _counterparties[j];
                uint256 cap = vault.getCounterpartyDailyCap(cp, token);
                assertLe(vault.spentToday(cp, token), cap, "vault counter above the counterparty cap");
                assertLe(handler.executedToCounterparty(cp, token, today), cap, "ledger above the counterparty cap");
            }
        }
    }

    /// @dev No token leaves the vault faster than its daily outflow cap, over all counterparties.
    function invariant_assetDailyCapNeverExceeded() external view {
        uint256 today = block.timestamp / 1 days;
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            uint256 cap = vault.getAssetConfig(token).dailyOutflowCap;
            assertLe(vault.assetSpentToday(token), cap, "vault counter above the token cap");
            assertLe(handler.executedOfToken(token, today), cap, "ledger above the token cap");
        }
    }

    /// @dev The vault's balance changes only through executed transfers and the issuer's forced
    ///      transfers. A rejection, a double payout or any other path breaks the equation.
    function invariant_vaultBalanceOnlyDropsWithExecutedOrIssuerAction() external view {
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            assertEq(
                IERC20(token).balanceOf(address(vault)),
                _funding[token] - handler.totalExecuted(token) - handler.totalForced(token),
                "vault balance differs from funding - executed - forced"
            );
        }
    }

    /// @dev The vault's daily counters equal what the handler saw executed today: nothing is
    ///      counted twice, nothing is missing, and a rejection or forced transfer counts nothing.
    function invariant_countersMatchLedger() external view {
        uint256 today = block.timestamp / 1 days;
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            assertEq(vault.assetSpentToday(token), handler.executedOfToken(token, today), "token counter != ledger");
            for (uint256 j = 0; j < _counterparties.length; j++) {
                address cp = _counterparties[j];
                assertEq(
                    vault.spentToday(cp, token),
                    handler.executedToCounterparty(cp, token, today),
                    "counterparty counter != ledger"
                );
            }
        }
    }

    /// @dev The checks the handler runs around each call held: an executed transfer passed every
    ///      gate and moved exactly its amount, a rejection changed nothing, a forced transfer left
    ///      the counters alone, and no executeTransfer call reverted. Foundry ignores reverts in handler calls, so the handler counts
    ///      failed checks and this invariant reads the count.
    function invariant_handlerChecksHeld() external view {
        assertEq(handler.failedChecks(), 0, handler.firstFailedCheck());
    }

    /// @dev Printed with -vv for the last run only: shows that the invariants checked real work.
    function afterInvariant() external view {
        console.log(
            string.concat(
                "transfer calls: ",
                vm.toString(handler.transfers()),
                ", executed: ",
                vm.toString(handler.executed()),
                ", rejected: ",
                vm.toString(handler.rejected()),
                ", reverted: ",
                vm.toString(handler.reverted())
            )
        );
        console.log(
            string.concat(
                "rejected by gate 1 / 2 / 3 / 4 / 5: ",
                vm.toString(handler.rejectedBy(TreasuryVault.RejectReason.AssetNotAllowed)),
                " / ",
                vm.toString(handler.rejectedBy(TreasuryVault.RejectReason.NotWhitelisted)),
                " / ",
                vm.toString(handler.rejectedBy(TreasuryVault.RejectReason.DailyCapExceeded)),
                " / ",
                vm.toString(handler.rejectedBy(TreasuryVault.RejectReason.AssetDailyCapExceeded)),
                " / ",
                vm.toString(handler.rejectedBy(TreasuryVault.RejectReason.ERC3643Compliance))
            )
        );
        console.log(
            string.concat(
                "other calls: warp ",
                vm.toString(handler.warps()),
                ", issuer toggle ",
                vm.toString(handler.issuerToggles()),
                ", forced transfer ",
                vm.toString(handler.forcedTransfers()),
                ", cap raise ",
                vm.toString(handler.capRaises()),
                ", counterparty toggle ",
                vm.toString(handler.counterpartyToggles()),
                "; day bucket at the end: ",
                vm.toString(block.timestamp / 1 days)
            )
        );
    }
}
