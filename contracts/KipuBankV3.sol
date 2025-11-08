// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/*Imports*/
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import { IUniswapV2Factory } from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import { IUniswapV2Pair } from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";



/*Interfaces*/
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/*
@title KipuBank for ETHKipu's Ethereum Developer Pack
@author Micaela Rasso
@notice This contract is part of the third project of the Ethereum Developer Pack 
@custom:security This is an educative contract and should not be used in production
*/
contract KipuBankV3 is Ownable, ReentrancyGuard{
    using SafeERC20 for IERC20;


/*State variables*/
    ///@notice Mapping of user address to their balance in USDC.
    mapping (address user => uint256 balance) private s_balances;

    ///PUEDE QUE LA CANTIDAD DE DEPOSITS POR TOKEN LOS ELIMINE Y VUELVAN A SER GENERALES 
    ///@notice Total number of deposits made per token.
    mapping(address => uint256) public s_totalDepositsByToken;

    ///@notice Total number of withdrawals made.
    uint256 public s_totalWithdrawals;

    ///@notice Maximum Ether capacity that the bank can hold.
    uint256 public immutable i_bankCap;

    ///@notice Maximum allowed withdrawal amount per transaction.
    uint256 public immutable i_maxWithdrawal;

    /// @notice USDC ERC20 token instance.
    IERC20 public immutable i_usdc;

    address public immutable i_weth;

    /// @notice Uniswap V2 Router instance for token swaps.
    IUniswapV2Router02 public immutable uniswapRouter;

    IUniswapV2Factory public uniswapFactory;

/*Events*/
    /*
    @notice Emitted when a withdrawal is successful.
    @param receiver The address receiving the withdrawn Ether.
    @param amount The amount of Ether withdrawn.
    */
    event KipuBank_SuccessfulWithdrawal (address receiver, uint256 amount);

    /*
    @notice Emitted when a deposit is successful.
    @param receiver The address making the deposit.
    @param amount The amount of Ether deposited.
    */
    event KipuBank_SuccessfulDeposit(address receiver, uint256 amount);

/*Errors*/
    /*
    @notice Thrown when a withdrawal fails.
    @param error Encoded error message returned by the failed call.
    */
    error KipuBank_FailedWithdrawal (bytes error);

    /*
    @notice Thrown when a fallback call fails.
    @param error Encoded error message for the failed operation.
    */
    error KipuBank_FailedOperation(bytes error);

    /*
    @notice Thrown when a withdrawal is attempted without sufficient funds.
    @param error Encoded error message.
    */
    error KipuBank_InsufficientFounds(bytes error);

    /*
    @notice Thrown when a deposit exceeds the bank capacity.
    @param error Encoded error message.
    */
    error KipuBank_FailedDeposit(bytes error);

    /*
    @notice Thrown when the bank or withdrawal capacity limits set during deployment are too low.
    */
    error KipuBank_DeniedContract();

    /*
    @notice Thrown when an operation is attempted with a token not supported by the bank.
    @param token The address of the unsupported token.
    */
    error KipuBank_NotSupportedToken(address token);

/*Modifiers*/
    /*
    @dev Ensures that a withdrawal can only be made if it does not exceed the maximum allowed amount and the user has sufficient balance.
    @param amount The requested withdrawal amount.
    */
    modifier _availableAmount(uint256 _amount){
        if(i_maxWithdrawal < _amount) revert KipuBank_FailedWithdrawal("Amount exceeds the maximum withdrawal");
        if(s_balances[msg.sender] < _amount) revert KipuBank_InsufficientFounds("Not enough founds");
        _;
    }

    modifier _areFundsExceeded(address _token, uint256 _amount){
        uint256 amountInUSDC = _estimateUSDCOut(_token, _amount);
        if (IERC20(i_usdc).balanceOf(address(this)) + amountInUSDC > i_bankCap) {
            revert KipuBank_FailedDeposit("Total KipuBank's funds exceeded");
        }
        _;
    }

    modifier _onlySupportedToken(address _token){ //prevents using excesive gas in case of unsupported tokens
        address pair = uniswapFactory.getPair(_token, address(i_usdc));
            if(pair == i_weth){
                revert KipuBank_NotSupportedToken(_token);
            }
        _;
    }

    modifier _isTokenTransferAllowed(address _token, uint256 _amount) {
        if (_token != i_weth) {
            IERC20 token = IERC20(_token);
            if (token.allowance(msg.sender, address(this)) < _amount) {
                revert KipuBank_FailedOperation("ERC20: Insufficient allowance for transferFrom");
            }
        }
        _;
    }

/*Functions*/
//constructor
    constructor(
        address _initialOwner, 
        address _weth, address _usdc, address _router,
        uint256 _bankCap, uint256 _maxWithdrawal
        ) Ownable(_initialOwner)
        {
        if (_bankCap < 10 || _maxWithdrawal < 1) revert KipuBank_DeniedContract();
        
        i_bankCap = _bankCap * 10**8;
        i_maxWithdrawal  = _maxWithdrawal* 10**8;
        
        i_usdc = IERC20(_usdc);
        i_weth = _weth;

        uniswapRouter = IUniswapV2Router02(_router);
        uniswapFactory = IUniswapV2Factory(uniswapRouter.factory());
    }

//receive & fallback
    /*
    @notice Allows contract to receive Ether directly.
    @dev Automatically calls the internal deposit function.
    */
    receive() external payable{
        _depositETH(msg.sender, msg.value);
    }

    /*
    @notice Handles calls with unknown data.
    @dev Always reverts with a failed operation error.
    */
    fallback() external{
        revert KipuBank_FailedOperation("Operation does not exists or data was incorrect");
    }

//external
     /*
    @notice Returns the total value of all assets held by the bank, converted and scaled to standard USD (8 decimals) for human readability.
    @return amount_ The total value of bank assets in 8-decimal USD.
    */
    function consultKipuBankFounds() external view returns (uint256 amount_){
        return _consultFounds() / 10**8; // Convert to 8 decimals for readability
    }

    /*
    @notice Allows users to deposit Ether into the bank. Uses msg.value for the deposit amount.
    @dev Uses _depositEther internal function and emits {KipuBank_SuccessfulDeposit}. 
    @custom:error KipuBank_FailedDeposit Thrown if the bank capacity is exceeded.
    */
    function deposit() external payable nonReentrant{
        _depositETH(msg.sender, msg.value);
    }

    function depositERC20(address _token, uint256 _amountIn, uint256 _amountMinOut
    ) external nonReentrant _onlySupportedToken(_token) _isTokenTransferAllowed(_token, _amountIn) _areFundsExceeded(_token, _amountIn){

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amountIn);

        uint256 beforeBalance = IERC20(i_usdc).balanceOf(address(this));
        uint256 usdcReceived;

        if (_token != address(i_usdc)) {
            IERC20(_token).approve(address(uniswapRouter), 0); // Reset to zero for safety
            IERC20(_token).approve(address(uniswapRouter), _amountIn);

            address[] memory path ;
            path[0] = _token;
            path[1] = address(i_usdc);

            uniswapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                _amountIn,
                _amountMinOut,
                path,
                address(this),
                block.timestamp + 300
            );

            uint256 afterBalance = IERC20(i_usdc).balanceOf(address(this));
            usdcReceived = afterBalance - beforeBalance;
        } else {
            usdcReceived = _amountIn;
        }

        s_balances[msg.sender] += usdcReceived;
        _actualizeOperations(true, _token);
        emit KipuBank_SuccessfulDeposit(msg.sender, usdcReceived);
    }

    function withdrawUsdc(uint256 _amount) external nonReentrant _availableAmount(_amount){
        //Effects
        s_balances[msg.sender] -= _amount;
        _actualizeOperations(false, address(i_usdc));
        //Interactions
        emit KipuBank_SuccessfulWithdrawal(msg.sender, _amount);
        i_usdc.safeTransfer(msg.sender, _amount);
    }

    function emergencyWithdrawal(uint256 _amount, address _recipient) external onlyOwner {
        IERC20(i_usdc).safeTransfer(_recipient, _amount);
    }

//internal
function _estimateUSDCOut(address _token, uint256 _amount) internal view returns (uint256) {
    if (_token == address(i_usdc)) return _amount;

    address pair = uniswapFactory.getPair(_token, address(i_usdc));
    require(pair != i_weth, "No pair");

    (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
    (uint112 reserveIn, uint112 reserveOut) = _token < address(i_usdc) ? (reserve0, reserve1) : (reserve1, reserve0);

    // Basic Uniswap constant product formula
    uint256 amountInWithFee = _amount * 997; // 0.3% fee
    uint256 numerator = amountInWithFee * reserveOut;
    uint256 denominator = reserveIn * 1000 + amountInWithFee;
    return numerator / denominator;
}


    //private
        function _depositETH(address _sender, uint256 _amountIn) private _areFundsExceeded(i_weth, _amountIn) {
        uint256 beforeBalance = IERC20(i_usdc).balanceOf(address(this));
        
        uint256 _amountMinOut = _estimateUSDCOut(i_weth, _amountIn);
        _amountMinOut /= 9 * 10;

        address[] memory path;
        path[0] = i_weth;
        path[1] = address(i_usdc);

        // call router: send ETH with the call
        uniswapRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{ value: _amountIn }(
            _amountMinOut,
            path,
            address(this),
            block.timestamp + 300
        );

        uint256 afterBalance = IERC20(i_usdc).balanceOf(address(this));
        uint256 usdcReceived = afterBalance - beforeBalance;
        
        s_balances[_sender] += usdcReceived;
        _actualizeOperations(true, i_weth);
        emit KipuBank_SuccessfulDeposit(_sender, usdcReceived);
    }

    function _actualizeOperations(bool isDeposit, address token) private{
        if(isDeposit){
            s_totalDepositsByToken[token] += 1;
        }else{
            s_totalWithdrawals += 1;
        }
    }

//view & pure 
    function _consultFounds() internal view returns (uint256 amount_) {
        amount_ = IERC20(i_usdc).balanceOf(address(this));
    }

}