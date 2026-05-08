// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { TreasuryVault } from "../src/TreasuryVault.sol";
import { MockERC3643 } from "../test/mocks/MockERC3643.sol";

/// @title DeployLocal
/// @notice Deploys MockERC3643 + TreasuryVault to a local Anvil node, funds the
///         vault, whitelists two counterparties, and sets the exposure cap.
///         Output is parsed by scripts/local-dev.sh into deployments/local.json.
contract DeployLocal is Script {
    // Anvil default mnemonic accounts. #0 deployer/agent, #1 cp1, #2 cp2.
    address constant CP1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant CP2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    uint256 constant VAULT_FUNDING = 100_000 * 1e18;
    uint256 constant CP1_DAILY_CAP = 5_000 * 1e18;
    uint256 constant CP2_DAILY_CAP = 1_000 * 1e18;
    uint256 constant MOCK_EXPOSURE_CAP = 8_000 * 1e18;

    function run() external {
        vm.startBroadcast();

        MockERC3643 mock = new MockERC3643();
        TreasuryVault vault = new TreasuryVault();

        mock.transfer(address(vault), VAULT_FUNDING);

        vault.addCounterparty(CP1, CP1_DAILY_CAP);
        vault.addCounterparty(CP2, CP2_DAILY_CAP);
        vault.setExposureCap(address(mock), MOCK_EXPOSURE_CAP);

        vm.stopBroadcast();

        console.log("=== DEPLOYMENT ===");
        console.log("vault=", address(vault));
        console.log("mock=", address(mock));
        console.log("cp1=", CP1);
        console.log("cp2=", CP2);
        console.log("cp1DailyCap=", CP1_DAILY_CAP);
        console.log("cp2DailyCap=", CP2_DAILY_CAP);
        console.log("mockExposureCap=", MOCK_EXPOSURE_CAP);
        console.log("vaultFunding=", VAULT_FUNDING);
        console.log("=== END ===");
    }
}
