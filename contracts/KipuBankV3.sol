// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/*Imports*/
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

/*Interfaces*/
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/*
@title KipuBank for ETHKipu's Ethereum Developer Pack
@author Micaela Rasso
@notice This contract is part of the third project of the Ethereum Developer Pack 
@custom:security This is an educative contract and should not be used in production
*/
contract KipuBankV3 is Ownable, ReentrancyGuard{

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
    
    /// @notice USDC ERC20 token instance.
    IERC20 public immutable i_WETH;

    /// @notice Uniswap V2 Router instance for token swaps.
    IUniswapV2Router02 public immutable uniswapRouter;

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
    modifier _amountAvailable(uint256 amount, address token){
        if(i_maxWithdrawal < amount) revert KipuBank_FailedWithdrawal("Amount exceeds the maximum withdrawal");
        if(s_balances[msg.sender] < amount) revert KipuBank_InsufficientFounds("Not enough founds");
        _;
    }

    modifier _areFundsExceeded(address _token, uint256 _amount){
        uint256 amountInUSDC = _convertToUSDC(_token, _amount);
        if (founds + amountInUSDC > i_bankCap) {
            revert KipuBank_FailedDeposit("Total KipuBank's funds exceeded");
        }
        _;
    }

    modifier _onlySupportedToken(address _token){ //prevents using excesive gas in case of unsupported tokens
        address pair = uniswapFactory.getPair(_token, i_usdc);
            if(pair == address(0)){
                revert KipuBank_NotSupportedToken(_token);
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
        address _usdc, address _weth, address _router,
        uint256 _bankCap, uint256 _maxWithdrawal
        ) Ownable(_initialOwner)
        {
        if (_bankCap < 10 || _maxWithdrawal < 1) revert KipuBank_DeniedContract();
        
        i_bankCap = _bankCap * 10**8;
        i_maxWithdrawal  = _maxWithdrawal* 10**8;
        
        i_usdc = IERC20(_usdc);
        i_WETH = IERC20(_weth);
    }

//receive & fallback
    /*
    @notice Allows contract to receive Ether directly.
    @dev Automatically calls the internal deposit function.
    */
    receive() external payable{
        _depositEther(msg.sender, msg.value);
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
    function deposit(uint256 _amountMinOut) external payable nonReentrant{
        _depositEther(msg.sender, msg.value, _amountMinOut);
    }

    function depositERC20(address _token, uint256 _amountIn, uint256 _amountMinOut
    ) external nonReentrant _onlySupportedToken(_token) _isTokenTransferAllowed(_token, _amountIn) _areFundsExceeded(_token, _amountIn){
        IERC20(_token).transferFrom(msg.sender, address(this), _amountIn);

        uint256 beforeBalance = IERC20(i_usdc).balanceOf(address(this));
        uint256 usdcReceived;

        if (_token != i_usdc) {
            IERC20(_token).approve(address(uniswapRouter), 0); // Reset to zero for safety
            IERC20(_token).approve(address(uniswapRouter), _amountIn);

            address ;
            path[0] = _token;
            path[1] = i_usdc;

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

    function withdrawUsdc(uint256 _amount) external nonReentrant _amountAvailable(_amount){
        //Effects
        s_balances[msg.sender] -= _amount;
        _actualizeOperations(false);
        //Interactions
        emit KipuBank_SuccessfulWithdrawal(msg.sender, amount);
        i_usdc.transfer(msg.sender, _amount);
    }

    function emergencyWithdrawal(uint256 _amount, address _recipient) external onlyOwner {
        IERC20(i_usdc).transfer(_recipient, _amount);
    }

//internal
    function _convertToUSDC(address _token, uint256 _amount) internal view returns (uint256 usdcAmount) {
        if (_token == i_usdc) {
            return _amount;
        }
        AggregatorV3Interface priceFeed = tokenToUsdFeed[_token];
        (, int256 price,,,) = priceFeed.latestRoundData();

        uint8 decimals = IERC20Metadata(_token).decimals();
        usdcAmount = (_amount * uint256(price)) / (10 ** (decimals + 2)); 
    }

//private
    
    function _depositEther(address _address, uint256 _amount, uint256 _amountMinOut) private _areFundsExceeded(_amount, address(0)){
        uint256 beforeBalance = IERC20(i_usdc).balanceOf(address(this));

        address ;
        path[0] = i_WETH;
        path[1] = i_usdc;

        IWETH(i_WETH).deposit{value: msg.value}();
        IERC20(i_WETH).approve(address(uniswapRouter), msg.value);

        uniswapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            msg.value,
            _amountMinOut,
            path,
            address(this),
            block.timestamp + 300
        );

        uint256 afterBalance = IERC20(i_usdc).balanceOf(address(this));
        uint256 usdcReceived = afterBalance - beforeBalance;

        s_balances[msg.sender] += usdcReceived;
        _actualizeOperations(true, address(0));

        emit KipuBank_SuccessfulDeposit(msg.sender, usdcReceived);
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