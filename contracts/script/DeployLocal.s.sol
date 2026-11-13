// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { Script, console } from "forge-std/Script.sol";
import { TreasuryVault } from "../src/TreasuryVault.sol";
import { MockERC3643 } from "../test/mocks/MockERC3643.sol";

/// @title DeployLocal
/// @notice Deploys MockERC3643 + TreasuryVault to a local Anvil node, verifies the
///         vault, cp1 and cp2 in the token, funds the vault, allows the token with a
///         daily outflow cap, whitelists three counterparties and sets their daily caps
///         for the token. cp3 is whitelisted in the vault but not verified in the token,
///         so the token rejects transfers to it.
///         Each vault role sits on its own Anvil account.
///         Output is parsed by scripts/local-dev.sh into deployments/local.json.
contract DeployLocal is Script {
    // Anvil default mnemonic. Accounts: #0 admin + deployer + token issuer, #1 cp1,
    // #2 cp2, #3 treasurer, #4 pauser, #5 agent, #6 cp3. Local-dev only.
    string constant ANVIL_MNEMONIC = "test test test test test test test test test test test junk";

    uint48 constant ADMIN_TRANSFER_DELAY = 1 days;
    uint256 constant VAULT_FUNDING = 100_000 * 1e18;
    uint256 constant CP1_DAILY_CAP = 5000 * 1e18;
    uint256 constant CP2_DAILY_CAP = 1000 * 1e18;
    uint256 constant CP3_DAILY_CAP = 1000 * 1e18;
    uint256 constant MOCK_DAILY_OUTFLOW_CAP = 8000 * 1e18;

    function run() external {
        uint256 adminKey = vm.deriveKey(ANVIL_MNEMONIC, 0);
        uint256 treasurerKey = vm.deriveKey(ANVIL_MNEMONIC, 3);
        address admin = vm.addr(adminKey);
        address treasurer = vm.addr(treasurerKey);
        address pauser = vm.addr(vm.deriveKey(ANVIL_MNEMONIC, 4));
        address agent = vm.addr(vm.deriveKey(ANVIL_MNEMONIC, 5));
        address cp1 = vm.addr(vm.deriveKey(ANVIL_MNEMONIC, 1));
        address cp2 = vm.addr(vm.deriveKey(ANVIL_MNEMONIC, 2));
        address cp3 = vm.addr(vm.deriveKey(ANVIL_MNEMONIC, 6));

        // The admin account deploys and funds. It holds no vault role besides DEFAULT_ADMIN_ROLE.
        // Deploying the mock also makes it the token's issuer agent. Locally that is a shortcut:
        // in production the issuer is a separate party.
        vm.startBroadcast(adminKey);
        MockERC3643 mock = new MockERC3643();
        TreasuryVault vault = new TreasuryVault(ADMIN_TRANSFER_DELAY, admin, treasurer, agent, pauser);
        // The token only delivers to verified wallets, the vault included. cp3 stays unverified.
        mock.setVerified(address(vault), true);
        mock.setVerified(cp1, true);
        mock.setVerified(cp2, true);
        require(mock.transfer(address(vault), VAULT_FUNDING), "funding failed");
        vm.stopBroadcast();

        // Policy setup needs TREASURER_ROLE, so the treasurer account signs it.
        vm.startBroadcast(treasurerKey);
        vault.setAssetConfig(address(mock), true, MOCK_DAILY_OUTFLOW_CAP);
        vault.addCounterparty(cp1);
        vault.addCounterparty(cp2);
        vault.addCounterparty(cp3);
        vault.setCounterpartyDailyCap(cp1, address(mock), CP1_DAILY_CAP);
        vault.setCounterpartyDailyCap(cp2, address(mock), CP2_DAILY_CAP);
        vault.setCounterpartyDailyCap(cp3, address(mock), CP3_DAILY_CAP);
        vm.stopBroadcast();

        console.log("=== DEPLOYMENT ===");
        console.log("vault=", address(vault));
        console.log("mock=", address(mock));
        console.log("cp1=", cp1);
        console.log("cp2=", cp2);
        console.log("cp3=", cp3);
        console.log("admin=", admin);
        console.log("treasurer=", treasurer);
        console.log("pauser=", pauser);
        console.log("agent=", agent);
        console.log("vaultFunding=", VAULT_FUNDING);
        console.log("=== END ===");
    }
}
