pragma solidity 0.6.8;

/**
 * NOTE: This contract only exists to serve as a testing utility. It is not recommended to be used outside of a testing environment
 */

import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ERC20 Token
 *
 * Basic ERC20 Implementation
 */
contract ERC20 is IERC20, Ownable {
    using SafeMath for uint256;

    // ============ Variables ============

    string internal _name;
    string internal _symbol;
    uint256 internal _supply;
    uint8 internal _decimals;
    address public admin;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // ============ Constructor ============

    constructor(
        address manager,
        string memory name,
        string memory symbol,
        uint8 decimals
    ) public {
        admin = manager;
        _name = name;
        _symbol = symbol;
        _decimals = decimals;
    }

    // ============ Public Functions ============
    
    modifier  _isOwner() {
        require(msg.sender == admin);
        _;
    }
    
    function changeOwner(address manager) external _isOwner {
        admin = manager;
        emit AdminChange(msg.sender,manager);
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function name() public view returns (string memory) {
        return _name;
    }

    function decimals() public view virtual returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return _supply;
    }

    function balanceOf(address who) public view override returns (uint256) {
        return _balances[who];
    }

    function allowance(address owner, address spender)
        public
        view
        override
        returns (uint256)
    {
        return _allowances[owner][spender];
    }

    // ============ Internal Functions ============

    function _mint(address to, uint256 value) internal {
        require(to != address(0), "Cannot mint to zero address");

        _balances[to] = _balances[to].add(value);
        _supply = _supply.add(value);

        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint256 value) internal {
        require(from != address(0), "Cannot burn to zero");

        _balances[from] = _balances[from].sub(value);
        _supply = _supply.sub(value);

        emit Transfer(from, address(0), value);
    }
}
