// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { Script, console } from "forge-std/Script.sol";
import { TreasuryVault } from "../src/TreasuryVault.sol";
import { MockERC3643 } from "../test/mocks/MockERC3643.sol";

/// @title DeployLocal
/// @notice Deploys MockERC3643 + TreasuryVault to a local Anvil node, funds the
///         vault, whitelists two counterparties, and sets the exposure cap.
///         Each vault role sits on its own Anvil account.
///         Output is parsed by scripts/local-dev.sh into deployments/local.json.
contract DeployLocal is Script {
    // Anvil default mnemonic. Accounts: #0 admin + deployer, #1 cp1, #2 cp2,
    // #3 treasurer, #4 pauser, #5 agent. Local-dev only.
    string constant ANVIL_MNEMONIC = "test test test test test test test test test test test junk";

    uint48 constant ADMIN_TRANSFER_DELAY = 1 days;
    uint256 constant VAULT_FUNDING = 100_000 * 1e18;
    uint256 constant CP1_DAILY_CAP = 5000 * 1e18;
    uint256 constant CP2_DAILY_CAP = 1000 * 1e18;
    uint256 constant MOCK_EXPOSURE_CAP = 8000 * 1e18;

    function run() external {
        uint256 adminKey = vm.deriveKey(ANVIL_MNEMONIC, 0);
        uint256 treasurerKey = vm.deriveKey(ANVIL_MNEMONIC, 3);
        address admin = vm.addr(adminKey);
        address treasurer = vm.addr(treasurerKey);
        address pauser = vm.addr(vm.deriveKey(ANVIL_MNEMONIC, 4));
        address agent = vm.addr(vm.deriveKey(ANVIL_MNEMONIC, 5));
        address cp1 = vm.addr(vm.deriveKey(ANVIL_MNEMONIC, 1));
        address cp2 = vm.addr(vm.deriveKey(ANVIL_MNEMONIC, 2));

        // The admin account deploys and funds. It holds no role besides DEFAULT_ADMIN_ROLE.
        vm.startBroadcast(adminKey);
        MockERC3643 mock = new MockERC3643();
        TreasuryVault vault = new TreasuryVault(ADMIN_TRANSFER_DELAY, admin, treasurer, agent, pauser);
        require(mock.transfer(address(vault), VAULT_FUNDING), "funding failed");
        vm.stopBroadcast();

        // Policy setup needs TREASURER_ROLE, so the treasurer account signs it.
        vm.startBroadcast(treasurerKey);
        vault.addCounterparty(cp1, CP1_DAILY_CAP);
        vault.addCounterparty(cp2, CP2_DAILY_CAP);
        vault.setExposureCap(address(mock), MOCK_EXPOSURE_CAP);
        vm.stopBroadcast();

        console.log("=== DEPLOYMENT ===");
        console.log("vault=", address(vault));
        console.log("mock=", address(mock));
        console.log("cp1=", cp1);
        console.log("cp2=", cp2);
        console.log("admin=", admin);
        console.log("treasurer=", treasurer);
        console.log("pauser=", pauser);
        console.log("agent=", agent);
        console.log("cp1DailyCap=", CP1_DAILY_CAP);
        console.log("cp2DailyCap=", CP2_DAILY_CAP);
        console.log("mockExposureCap=", MOCK_EXPOSURE_CAP);
        console.log("vaultFunding=", VAULT_FUNDING);
        console.log("=== END ===");
    }
}
