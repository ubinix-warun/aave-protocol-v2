// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.6.8;

import {ERC20} from './ERC20.sol';
import {LendingPool} from '../lendingpool/LendingPool.sol';
import {WadRayMath} from '../libraries/math/WadRayMath.sol';
import {Errors} from '../libraries/helpers/Errors.sol';
import {
  VersionedInitializable
} from '../libraries/openzeppelin-upgradeability/VersionedInitializable.sol';
import {IAToken} from './interfaces/IAToken.sol';
import {IERC20} from '../interfaces/IERC20.sol';
import {SafeERC20} from '../misc/SafeERC20.sol';

/**
 * @title Aave ERC20 AToken
 *
 * @dev Implementation of the interest bearing token for the DLP protocol.
 * @author Aave
 */
contract AToken is VersionedInitializable, ERC20, IAToken {
  using WadRayMath for uint256;
  using SafeERC20 for ERC20;

  uint256 public constant UINT_MAX_VALUE = uint256(-1);

  address public immutable UNDERLYING_ASSET_ADDRESS;
  address public immutable RESERVE_TREASURY_ADDRESS;
  LendingPool public immutable POOL;

  mapping(address => uint256) private _scaledRedirectedBalances;


  uint256 public constant ATOKEN_REVISION = 0x1;

  modifier onlyLendingPool {
    require(msg.sender == address(POOL), Errors.CALLER_MUST_BE_LENDING_POOL);
    _;
  }

  constructor(
    LendingPool pool,
    address underlyingAssetAddress,
    address reserveTreasuryAddress,
    string memory tokenName,
    string memory tokenSymbol
  ) public ERC20(tokenName, tokenSymbol, 18) {
    POOL = pool;
    UNDERLYING_ASSET_ADDRESS = underlyingAssetAddress;
    RESERVE_TREASURY_ADDRESS = reserveTreasuryAddress;
  }

  function getRevision() internal virtual override pure returns (uint256) {
    return ATOKEN_REVISION;
  }

  function initialize(
    uint8 underlyingAssetDecimals,
    string calldata tokenName,
    string calldata tokenSymbol
  ) external virtual initializer {
    _setName(tokenName);
    _setSymbol(tokenSymbol);
    _setDecimals(underlyingAssetDecimals);
  }

  /**
   * @dev burns the aTokens and sends the equivalent amount of underlying to the target.
   * only lending pools can call this function
   * @param amount the amount being burned
   **/
  function burn(
    address user,
    address receiverOfUnderlying,
    uint256 amount,
    uint256 index
  ) external override onlyLendingPool {

    uint256 currentBalance = balanceOf(user);

    require(amount <= currentBalance, Errors.INVALID_ATOKEN_BALANCE);

    uint256 scaledAmount = amount.rayDiv(index);

    _burn(user, scaledAmount);

    //transfers the underlying to the target
    ERC20(UNDERLYING_ASSET_ADDRESS).safeTransfer(receiverOfUnderlying, amount);


    emit Burn(msg.sender, receiverOfUnderlying, amount, index);
  }

  /**
   * @dev mints aTokens to user
   * only lending pools can call this function
   * @param user the address receiving the minted tokens
   * @param amount the amount of tokens to mint
   */
  function mint(address user, uint256 amount, uint256 index) external override onlyLendingPool {


    uint256 scaledAmount = amount.rayDiv(index);
 
    //mint an equivalent amount of tokens to cover the new deposit
    _mint(user,scaledAmount);

    emit Mint(user, amount, index);
  }

  function mintToReserve(uint256 amount) external override onlyLendingPool {
      uint256 index = _pool.getReserveNormalizedIncome(UNDERLYING_ASSET_ADDRESS);
      _mint(RESERVE_TREASURY_ADDRESS, amount.div(index));
  }

  /**
   * @dev transfers tokens in the event of a borrow being liquidated, in case the liquidators reclaims the aToken
   *      only lending pools can call this function
   * @param from the address from which transfer the aTokens
   * @param to the destination address
   * @param value the amount to transfer
   **/
  function transferOnLiquidation(
    address from,
    address to,
    uint256 value
  ) external override onlyLendingPool {
    //being a normal transfer, the Transfer() and BalanceTransfer() are emitted
    //so no need to emit a specific event here
    _transfer(from, to, value, false);
  }

  /**
   * @dev calculates the balance of the user, which is the
   * principal balance + interest generated by the principal balance 
   * @param user the user for which the balance is being calculated
   * @return the total balance of the user
   **/
  function balanceOf(address user) public override(ERC20, IERC20) view returns (uint256) {
    return super.balanceOf(user).rayMul(POOL.getReserveNormalizedIncome(UNDERLYING_ASSET_ADDRESS));
  }

  /**
   * @dev returns the scaled balance of the user. The scaled balance is the sum of all the
   * updated stored balance divided the reserve index at the moment of the update
   * @param user the address of the user
   * @return the scaled balance of the user
   **/
  function scaledBalanceOf(address user) external override view returns (uint256) {
    return super.balanceOf(user);
  }

  /**
   * @dev calculates the total supply of the specific aToken
   * since the balance of every single user increases over time, the total supply
   * does that too.
   * @return the current total supply
   **/
  function totalSupply() public override(ERC20, IERC20) view returns (uint256) {
    uint256 currentSupplyScaled = super.totalSupply();

    if (currentSupplyScaled == 0) {
      return 0;
    }

    return
      currentSupplyScaled
        .rayMul(POOL.getReserveNormalizedIncome(UNDERLYING_ASSET_ADDRESS));
  }

  /**
   * @dev Used to validate transfers before actually executing them.
   * @param user address of the user to check
   * @param amount the amount to check
   * @return true if the user can transfer amount, false otherwise
   **/
  function isTransferAllowed(address user, uint256 amount) public override view returns (bool) {
    return POOL.balanceDecreaseAllowed(UNDERLYING_ASSET_ADDRESS, user, amount);
  }

  /**
  * @dev transfers the underlying asset to the target. Used by the lendingpool to transfer
  * assets in borrow(), redeem() and flashLoan()
  * @param target the target of the transfer
  * @param amount the amount to transfer
  * @return the amount transferred
  **/
  function transferUnderlyingTo(address target, uint256 amount)
    external
    override
    onlyLendingPool
    returns (uint256)
  {
    ERC20(UNDERLYING_ASSET_ADDRESS).safeTransfer(target, amount);
    return amount;
  }

  function _transfer(
    address from,
    address to,
    uint256 amount,
    bool validate
  ) internal  {
    if(validate){
      require(isTransferAllowed(from, amount), Errors.TRANSFER_NOT_ALLOWED);
    }

    uint256 index = POOL.getReserveNormalizedIncome(UNDERLYING_ASSET_ADDRESS);

    uint256 scaledAmount = amount.rayDiv(index);

    super._transfer(from, to, scaledAmount);

    emit BalanceTransfer(from, to, amount, index);

  }
  
  function _transfer(
    address from,
    address to,
    uint256 amount
    ) internal override {

      _transfer(from, to, amount, true);
  }
  /**
   * @dev aTokens should not receive ETH
   **/
  receive() external payable {
    revert();
  }
}
