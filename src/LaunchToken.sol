// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title Swarm Cities launch token
/// @notice Fixed initial supply of GRID, with holder burns and allowance-authorized burns.
/// @dev Transfers are exact-value ERC-20 transfers. The requested universal transfer tax conflicts
/// with the launch token acceptance checks; see README.md for the unresolved launch requirement.
contract LaunchToken is ERC20, ERC20Burnable {
    constructor() ERC20("Swarm Cities", "GRID") {
        _mint(msg.sender, 1_000_000_000 * 10 ** 18);
    }
}
