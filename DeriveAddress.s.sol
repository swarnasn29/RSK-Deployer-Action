pragma solidity ^0.8.19;
import "forge-std/Script.sol";
contract DeriveAddress is Script {
    function run() public view {
        uint256 pk = vm.envUint("FOUNDRY_PRIVATE_KEY");
        address addr = vm.addr(pk);
        console.log("DEPLOYER_ADDRESS:%s", addr);
    }
}
