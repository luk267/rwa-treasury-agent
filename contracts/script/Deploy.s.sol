// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { Script, console } from "forge-std/Script.sol";
import { TreasuryVault } from "../src/TreasuryVault.sol";
import { MockERC3643 } from "../test/mocks/MockERC3643.sol";

/// @title Deploy
/// @notice Deploys MockERC3643 + TreasuryVault to any network and sets up the same demo policy
///         as DeployLocal: the token verifies the vault, cp1 and cp2; the vault is funded,
///         allows the token with a daily outflow cap, whitelists three counterparties and sets
///         their daily caps for the token. cp3 stays unverified in the token, so the token
///         rejects transfers to it.
/// @dev Role addresses come from the environment: ADMIN, TREASURER, PAUSER, AGENT and
///      ADMIN_TRANSFER_DELAY (seconds). The signer comes from the command line
///      (--private-key or --account), so no key appears in this script. The signer must be
///      TREASURER, because the policy setup needs TREASURER_ROLE. It also becomes the mock's
///      issuer agent and funds the vault. The agent must not hold any other role.
contract Deploy is Script {
    uint256 constant VAULT_FUNDING = 100_000 * 1e18;
    uint256 constant CP1_DAILY_CAP = 5000 * 1e18;
    uint256 constant CP2_DAILY_CAP = 1000 * 1e18;
    uint256 constant CP3_DAILY_CAP = 1000 * 1e18;
    uint256 constant MOCK_DAILY_OUTFLOW_CAP = 8000 * 1e18;

    function run() external {
        address admin = vm.envAddress("ADMIN");
        address treasurer = vm.envAddress("TREASURER");
        address pauser = vm.envAddress("PAUSER");
        address agent = vm.envAddress("AGENT");
        uint48 adminTransferDelay = uint48(vm.envUint("ADMIN_TRANSFER_DELAY"));
        require(agent != admin && agent != treasurer && agent != pauser, "Deploy: AGENT must not hold another role");
        require(msg.sender == treasurer, "Deploy: sign as TREASURER, the policy setup needs TREASURER_ROLE");

        // Placeholder recipients: addresses derived from a label, so nobody holds their key.
        address cp1 = _labelAddress("rwa-treasury-agent cp1");
        address cp2 = _labelAddress("rwa-treasury-agent cp2");
        address cp3 = _labelAddress("rwa-treasury-agent cp3");

        vm.startBroadcast();
        MockERC3643 mock = new MockERC3643();
        TreasuryVault vault = new TreasuryVault(adminTransferDelay, admin, treasurer, agent, pauser);
        // The token only delivers to verified wallets, the vault included. cp3 stays unverified.
        mock.setVerified(address(vault), true);
        mock.setVerified(cp1, true);
        mock.setVerified(cp2, true);
        require(mock.transfer(address(vault), VAULT_FUNDING), "funding failed");

        vault.setAssetConfig(address(mock), true, MOCK_DAILY_OUTFLOW_CAP);
        vault.addCounterparty(cp1);
        vault.addCounterparty(cp2);
        vault.addCounterparty(cp3);
        vault.setCounterpartyDailyCap(cp1, address(mock), CP1_DAILY_CAP);
        vault.setCounterpartyDailyCap(cp2, address(mock), CP2_DAILY_CAP);
        vault.setCounterpartyDailyCap(cp3, address(mock), CP3_DAILY_CAP);
        vm.stopBroadcast();

        console.log("=== DEPLOYMENT ===");
        console.log("chainId=", block.chainid);
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

    function _labelAddress(string memory label) private pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(label)))));
    }
}
