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
    /// @notice Mapping from user address to their consolidated balance within the bank, tracked entirely in USDC.
    mapping (address user => uint256 balance) private s_balances;

    /// @notice Total number of deposits made, tracked by the original token deposited.
    mapping(address => uint256) public s_totalDepositsByToken;

    /// @notice Total count of withdrawal operations executed from the bank.
    uint256 public s_totalWithdrawals;

    /// @notice Maximum USD capacity that the bank can hold, scaled to 6 USDC decimals. Immutable.
    uint256 public immutable i_bankCap;

    /// @notice Maximum allowed withdrawal amount per transaction in USDC. Immutable.
    uint256 public immutable i_maxWithdrawal;

    /// @notice The immutable interface address for the USDC ERC20 token.
    IERC20 public immutable i_usdc;

    /// @notice The immutable address for the WETH token, used as the intermediary for ETH swaps.
    address public immutable i_weth;

    /// @notice The immutable interface for the Uniswap V2 Router, used for all swaps to USDC.
    IUniswapV2Router02 public immutable uniswapRouter;

    /// @notice The immutable interface for the Uniswap V2 Factory, derived from the router address.
    IUniswapV2Factory public uniswapFactory;

/*Events*/
    /// @notice Emitted when a withdrawal is successful.
    /// @param receiver The address receiving the withdrawn funds.
    /// @param amount The amount of USDC withdrawn.
    event KipuBank_SuccessfulWithdrawal (address receiver, uint256 amount);

    /// @notice Emitted when a deposit is successful.
    /// @param receiver The address making the deposit.
    /// @param amount The net amount of USDC credited to the user's balance.
    event KipuBank_SuccessfulDeposit(address receiver, uint256 amount);

    /// @notice Emitted when the owner executes an emergency withdrawal of USDC.
    /// @param amount The amount of USDC withdrawn by the owner.
    event KipuBank_EmergencyWithdrawal(uint256 amount);

/*Errors*/
    /// @notice Thrown when a withdrawal fails.
    /// @param error Encoded error message returned by the failed call.
    error KipuBank_FailedWithdrawal (bytes error);

    /// @notice Thrown for general operational failures.
    /// @param error Encoded error message returned by the failed call.
    error KipuBank_FailedOperation(bytes error);

    /// @notice Thrown when a withdrawal is attempted without sufficient user balance.
    /// @param error Encoded error message returned by the failed call.
    error KipuBank_InsufficientFunds(bytes error);

    /// @notice Thrown when a deposit fails due to exceeding the bank's maximum capacity.
    /// @param error Encoded error message returned by the failed call.
    error KipuBank_FailedDeposit(bytes error);

    /// @notice Thrown during deployment if bank limits are set too low.
    error KipuBank_DeniedContract();

    /// @notice Thrown when a deposit is attempted for an ERC20 token that lacks a direct pair with USDC on Uniswap V2.
    /// @param token The address of the unsupported token.
    error KipuBank_NotSupportedToken(address token);

/*Modifiers*/
    /// @dev Ensures the requested withdrawal amount does not exceed the maximum allowed amount and the user's available USDC balance.
    /// @param _amount The requested withdrawal amount (in USDC decimals).
    /// @custom:error KipuBank_InsufficientFunds Thrown if user balance is insufficient.
    modifier _availableAmount(uint256 _amount){
        if(i_maxWithdrawal < _amount) revert KipuBank_FailedWithdrawal("Amount exceeds the maximum withdrawal");
        if(s_balances[msg.sender] < _amount) revert KipuBank_InsufficientFunds("Not enough Funds");
        _;
    }

    /// @dev Checks if a direct trading pair exists between the input token and USDC on the Uniswap V2 factory. 
    /// @param _token The ERC20 token address to check.
    /// @custom:error KipuBank_NotSupportedToken Thrown if the pair does not exist.
    modifier _onlySupportedToken(address _token){ //prevents using excesive gas in case of unsupported tokens
        address pair = uniswapFactory.getPair(_token, address(i_usdc));
            if(pair == address(0)){
                revert KipuBank_NotSupportedToken(_token);
            }
        _;
    }

    /// @dev Estimates the USDC output of a swap and ensures that the bank's current balance plus the estimated deposit does not exceed the maximum capacity.
    /// @param _token The address of the token being deposited.
    /// @param _amount The amount of the token being deposited.
    /// @custom:error KipuBank_FailedDeposit Thrown if the bank capacity is exceeded.
    modifier _areFundsExceeded(address _token, uint256 _amount){
        uint256 amountInUSDC = _estimateUSDCOut(_token, _amount); 
        if (IERC20(i_usdc).balanceOf(address(this)) + amountInUSDC > i_bankCap) {
            revert KipuBank_FailedDeposit("Total KipuBank's Funds exceeded");
        }
        _;
    }

    /// @dev Ensures the caller has granted sufficient ERC20 allowance to the bank contract for a safeTransferFrom operation.
    /// @param _token The ERC20 token address.
    /// @param _amount The amount of token to be transferred.
    /// @custom:error KipuBank_FailedOperation Thrown if the allowance is insufficient.
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
    /// @notice Deploys the contract, initializing the owner, bank limits, supported tokens and the Uniswap V2 environment.
    /// @param _initialOwner The address that will be set as the contract owner.
    /// @param _weth The address of the WETH token (used for ETH swaps).
    /// @param _usdc The address of the USDC ERC20 token. 
    /// @param _router The address of the Uniswap V2 Router02.
    /// @param _bankCap The maximum capacity the bank can hold (in unscaled USD value).
    /// @param _maxWithdrawal The maximum amount a user can withdraw per transaction (in unscaled USD value).
    /// @custom:error KipuBank_DeniedContract Thrown if the capacity or withdrawal limits are set too low.
    constructor(
        address _initialOwner, 
        address _weth, address _usdc, address _router,
        uint256 _bankCap, uint256 _maxWithdrawal
        ) Ownable(_initialOwner)
        {
        if (_bankCap < 10 || _maxWithdrawal < 1) revert KipuBank_DeniedContract();
        
        i_bankCap = _bankCap * 10**6;
        i_maxWithdrawal  = _maxWithdrawal* 10**6;
        
        i_usdc = IERC20(_usdc);
        i_weth = _weth;

        uniswapRouter = IUniswapV2Router02(_router);
        uniswapFactory = IUniswapV2Factory(uniswapRouter.factory());
    }

//receive & fallback
    /// @notice Prevents direct Ether transfers to ensure users use the deposit() function for proper accounting and swapping.
    receive() external payable nonReentrant{
        revert KipuBank_FailedOperation("Use deposit for ETH deposit");
    }

    /// @notice Handles calls with unknown data, always reverting.
    fallback() external{
        revert KipuBank_FailedOperation("Operation does not exists or data was incorrect");
    }

//external
    /// @notice Returns the total consolidated value of all assets held by the bank, which is the total balance of USDC.
    /// @return amount_ The contract's USDC balance (6 decimals).
    function consultKipuBankFunds() external view returns (uint256 amount_){
        return _consultFunds();
    }

    /// @notice Allows users to deposit native Ether (ETH) into the bank. ETH is automatically swapped to USDC.
    /// @dev Calls _depositETH and is protected by nonReentrant.
    function deposit() external payable nonReentrant{
        _depositETH(msg.sender, msg.value);
    }

    /// @notice Allows users to deposit any supported ERC20 token. The token is automatically swapped to USDC.
    /// @param _token The address of the ERC20 token being deposited.
    /// @param _amountIn The amount of the ERC20 token being deposited.
    /// @param _amountMinOut The minimum amount of USDC expected to receive from the swap.
    /// @custom:error KipuBank_FailedDeposit Thrown if the post-swap USDC balance exceeds i_bankCap.
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

    /// @notice Allows users to withdraw their consolidated balance, which is always paid out in USDC.
    /// @param _amount The amount of USDC to withdraw (in USDC decimals).
    function withdrawUsdc(uint256 _amount) external nonReentrant _availableAmount(_amount){
        s_balances[msg.sender] -= _amount;
        IERC20 token = i_usdc;
        _actualizeOperations(false, address(token));
        token.safeTransfer(msg.sender, _amount);

        emit KipuBank_SuccessfulWithdrawal(msg.sender, _amount);
    }

    /// @notice Allows the contract owner to safely withdraw USDC from the contract in case of emergency or error.
    /// @param _amount The amount of USDC to withdraw.
    /// @param _recipient The address to send the funds to.
    function emergencyWithdrawal(uint256 _amount, address _recipient) external onlyOwner {
        IERC20(i_usdc).safeTransfer(_recipient, _amount);
        emit KipuBank_EmergencyWithdrawal(_amount);
    }

    //internal
    /// @dev Calculates the estimated USDC output for a given amount of an input token using the Uniswap V2 formula based on current reserves.
    /// @param _token The input token address.
    /// @param _amount The input token amount.
    /// @return The estimated USDC output.
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
    /// @dev Handles the core logic for ETH deposits, including the Uniswap swap to USDC and the post-swap bank cap check.
    /// @param _sender The address of the depositor.
    /// @param _amountIn The amount of native ETH received.
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

    /// @dev Updates internal counters for total deposits and withdrawals.
    /// @param isDeposit True if a deposit operation, false if a withdrawal.
    /// @param token The token associated with the operation (used only for deposits).
    function _actualizeOperations(bool isDeposit, address token) private{
        if(isDeposit){
            s_totalDepositsByToken[token] += 1;
        }else{
            s_totalWithdrawals += 1;
        }
    }

//view & pure 
    /// @dev Returns the total amount of USDC currently held by the contract (internal balance).
    /// @return amount_ The contract's USDC balance (6 decimals).
    function _consultFunds() internal view returns (uint256 amount_) {
        amount_ = IERC20(i_usdc).balanceOf(address(this));
    }

}