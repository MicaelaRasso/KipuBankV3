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
    mapping (address user => uint256 balance) private s_balances;

    mapping(address => uint256) public s_totalDepositsByToken;

    uint256 public s_totalWithdrawals;

    uint256 public immutable i_bankCap;

    uint256 public immutable i_maxWithdrawal;

    IERC20 public immutable i_usdc;

    address public immutable i_weth;

    IUniswapV2Router02 public immutable uniswapRouter;

    IUniswapV2Factory public uniswapFactory;

/*Events*/
    event KipuBank_SuccessfulWithdrawal (address receiver, uint256 amount);

    event KipuBank_SuccessfulDeposit(address receiver, uint256 amount);

    event KipuBank_EmergencyWithdrawal(uint256 amount);

/*Errors*/
    error KipuBank_FailedWithdrawal (bytes error);

    error KipuBank_FailedOperation(bytes error);

    error KipuBank_InsufficientFunds(bytes error);

    error KipuBank_FailedDeposit(bytes error);

    error KipuBank_DeniedContract();

    error KipuBank_NotSupportedToken(address token);

/*Modifiers*/
    modifier _availableAmount(uint256 _amount){
        if(i_maxWithdrawal < _amount) revert KipuBank_FailedWithdrawal("Amount exceeds the maximum withdrawal");
        if(s_balances[msg.sender] < _amount) revert KipuBank_InsufficientFunds("Not enough Funds");
        _;
    }

    modifier _onlySupportedToken(address _token){ //prevents using excesive gas in case of unsupported tokens
        address pair = uniswapFactory.getPair(_token, address(i_usdc));
            if(pair == address(0)){
                revert KipuBank_NotSupportedToken(_token);
            }
        _;
    }
    modifier _areFundsExceeded(address _token, uint256 _amount){
    uint256 amountInUSDC = _estimateUSDCOut(_token, _amount); 
    if (IERC20(i_usdc).balanceOf(address(this)) + amountInUSDC > i_bankCap) {
        revert KipuBank_FailedDeposit("Total KipuBank's Funds exceeded");
    }
    _;
}

    modifier _isTokenTransferAllowed(address _token, uint256 _amount) {
        if (_token != address(0)) {
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
        
        i_bankCap = _bankCap * 10**6; //in usdc
        i_maxWithdrawal  = _maxWithdrawal* 10**6; //in usdc
        
        i_usdc = IERC20(_usdc);
        i_weth = _weth;

        uniswapRouter = IUniswapV2Router02(_router);
        uniswapFactory = IUniswapV2Factory(uniswapRouter.factory());
    }

//receive & fallback
    receive() external payable{
        revert KipuBank_FailedOperation("Use deposit for ETH deposit");
    }

    fallback() external{
        revert KipuBank_FailedOperation("Operation does not exists or data was incorrect");
    }

//external
    function consultKipuBankFunds() external view returns (uint256 amount_){
        return _consultFunds();
    }

    function deposit() external payable nonReentrant{
        _depositETH(msg.sender, msg.value);
    }

    function depositERC20(
        address _token, uint256 _amountIn, uint256 _amountMinOut
    ) external nonReentrant _onlySupportedToken(_token) _isTokenTransferAllowed(_token, _amountIn) _areFundsExceeded(_token, _amountIn){
        // Checks: (Manejados por Modificadores y nonReentrant)
        // 1. Interactions
        IERC20 token = IERC20(_token);
        token.safeTransferFrom(msg.sender, address(this), _amountIn);
        // 2. Effects
        uint256 usdcReceived;
        uint256 beforeBalance = IERC20(i_usdc).balanceOf(address(this));
        if (_token != address(i_usdc)) {
            address[] memory path = new address[](2);
            path[0] = _token;
            path[1] = address(i_usdc);
            // 3. Interactions
            uniswapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                _amountIn,
                _amountMinOut,
                path,
                address(this),
                block.timestamp + 300
            );
            // 4. Effects
            uint256 afterBalance = IERC20(i_usdc).balanceOf(address(this));
            usdcReceived = afterBalance - beforeBalance;
        } else {
            usdcReceived = _amountIn;
        }
        if(beforeBalance + usdcReceived > i_bankCap) revert KipuBank_FailedDeposit("Total KipuBank's Funds exceeded");
        // 5. Effects
        s_balances[msg.sender] += usdcReceived;
        _actualizeOperations(true, _token);
        // 6. Events
        emit KipuBank_SuccessfulDeposit(msg.sender, usdcReceived);
    }

    function withdrawUsdc(uint256 _amount) external nonReentrant _availableAmount(_amount){
        s_balances[msg.sender] -= _amount;
        IERC20 token = i_usdc;
        _actualizeOperations(false, address(token));
        token.safeTransfer(msg.sender, _amount);

        emit KipuBank_SuccessfulWithdrawal(msg.sender, _amount);
    }

    function emergencyWithdrawal(uint256 _amount, address _recipient) external onlyOwner {
        IERC20(i_usdc).safeTransfer(_recipient, _amount);
        emit KipuBank_EmergencyWithdrawal(_amount);
    }

    //internal
    function _estimateUSDCOut(address _token, uint256 _amount) internal view returns (uint256) {
        if (_token == address(i_usdc)) return _amount;

        address pair = uniswapFactory.getPair(_token, address(i_usdc));

        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        (uint112 reserveIn, uint112 reserveOut) = _token < address(i_usdc) ? (reserve0, reserve1) : (reserve1, reserve0);

        uint256 amountInWithFee = _amount * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        return numerator / denominator;
    }


    //private
    function _depositETH(address _sender, uint256 _amountIn) private _areFundsExceeded(address(0), _amountIn) {
        uint256 beforeBalance = IERC20(i_usdc).balanceOf(address(this));
        
        uint256 _amountMinOut = _estimateUSDCOut(i_weth, _amountIn);
        _amountMinOut = (_amountMinOut * 99) / 100;

        address[] memory path = new address[](2);
        path[0] = i_weth;
        path[1] = address(i_usdc);

        uniswapRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{ value: _amountIn }(
            _amountMinOut,
            path,
            address(this),
            block.timestamp + 300
        );

        uint256 afterBalance = IERC20(i_usdc).balanceOf(address(this));
        uint256 usdcReceived = afterBalance - beforeBalance;
        
        if(beforeBalance + usdcReceived > i_bankCap) revert KipuBank_FailedDeposit("Total KipuBank's Funds exceeded");
 
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
    function _consultFunds() internal view returns (uint256 amount_) {
        amount_ = IERC20(i_usdc).balanceOf(address(this));
    }

}