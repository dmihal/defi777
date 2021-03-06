// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.7.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";
import "../../ens/ReverseENS.sol";
import "../../tokens/IWrapped777.sol";
import "../../interfaces/IWETH.sol";
import "../../Receiver.sol";
import "./interfaces/ILendingPoolAddressesProvider.sol";
import "./interfaces/ILendingPool.sol";

contract AaveAdapter is Receiver, Ownable, ReverseENS {
  ILendingPoolAddressesProvider public immutable addressProvider;

  mapping(address => address) public wrappedATokenToWrapper;
  mapping(address => address) public tokenToWrappedAToken;
  IWETH public immutable weth;
  uint16 constant private referralCode = 45;

  constructor(address _addressProvider, IWETH _weth) public {
    addressProvider = ILendingPoolAddressesProvider(_addressProvider);
    weth = _weth;

    // Needs to be explicitly set since we deploy through a Create2 proxy
    transferOwnership(tx.origin);
  }

  receive() external payable {
    if (msg.sender != address(weth)) {
      weth.deposit{ value: msg.value }();

      deposit(ERC20(address(weth)), msg.value, msg.sender);
    }
  }

  function setWrappedAToken(address wrappedToken, address wrappedAToken) public onlyOwner {
    wrappedATokenToWrapper[wrappedAToken] = wrappedToken;
    if (wrappedToken == address(weth)) {
      tokenToWrappedAToken[address(weth)] = wrappedAToken;
    } else {
      tokenToWrappedAToken[address(IWrapped777(wrappedToken).token())] = wrappedAToken;
    }
  }

  function _tokensReceived(IERC777 token, address from, uint256 amount, bytes memory) internal override {
    address outputWrapper = wrappedATokenToWrapper[address(token)];

    if (outputWrapper == address(weth)) {
      withdrawETH(address(token), from, amount);
    } else if (outputWrapper != address(0)) {
      withdraw(address(token), IWrapped777(outputWrapper), from, amount);
    } else {
      ERC20 unwrappedToken = IWrapped777(address(token)).token();
      uint256 unwrappedAmount = IWrapped777(address(token)).unwrap(amount);
      deposit(unwrappedToken, unwrappedAmount, from);
    }
  }

  function deposit(ERC20 token, uint256 amount, address recipient) private {
    ILendingPool _lendingPool = lendingPool();

    address outputWrapper = tokenToWrappedAToken[address(token)];
    require(outputWrapper != address(0), 'Unsupported');

    token.approve(address(_lendingPool), amount);
    _lendingPool.deposit(address(token), amount, outputWrapper, referralCode);
    IWrapped777(outputWrapper).gulp(recipient);
  }

  function withdraw(address token, IWrapped777 outputWrapper, address recipient, uint256 amount) private {
    uint256 unwrappedAmount = IWrapped777(token).unwrap(amount);
    lendingPool().withdraw(address(outputWrapper.token()), unwrappedAmount, address(outputWrapper));
    outputWrapper.gulp(recipient);
  }

  function withdrawETH(address token, address recipient, uint256 amount) private {
    uint256 unwrappedAmount = IWrapped777(token).unwrap(amount);
    lendingPool().withdraw(address(weth), unwrappedAmount, address(this));

    uint256 ethAmount = weth.balanceOf(address(this));
    weth.withdraw(ethAmount);
    TransferHelper.safeTransferETH(recipient, ethAmount);
  }

  function lendingPool() private view returns (ILendingPool) {
    return ILendingPool(addressProvider.getLendingPool());
  }
}
