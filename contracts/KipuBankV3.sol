// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/*Imports*/
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/*Interfaces*/
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/*
@title KipuBank for ETHKipu's Ethereum Developer Pack
@author Micaela Rasso
@notice This contract is part of the third project of the Ethereum Developer Pack 
@custom:security This is an educative contract and should not be used in production
*/
contract KipuBankV3 is Ownable, ReentrancyGuard{

/*State variables*/
    ///@notice Mapping of user address to their balance per token.
    mapping (address token => mapping(address user => uint256 balance)) private s_balances;

    /// @notice Supported tokens mapping.
    mapping (address token => bool isSupported) public s_supportedTokens; //es necesario?

    ///@notice Total number of deposits made per token.
    mapping(address => uint256) public s_totalDepositsByToken;

    ///@notice Total number of withdrawals made per token.
    mapping(address => uint256) public s_totalWithdrawalsByToken;

    /// @notice Chainlink BTC/USD price feed.
    AggregatorV3Interface public s_btcFeed;

    /// @notice Chainlink ETH/USD price feed.
    AggregatorV3Interface public s_ethFeed;

    ///@notice Maximum Ether capacity that the bank can hold.
    uint256 public immutable i_bankCap;

    ///@notice Maximum allowed withdrawal amount per transaction.
    uint256 public immutable i_maxWithdrawal;

    /// @notice USDC ERC20 token instance.
    IERC20 public immutable i_usdc;

    /// @notice BTC ERC20 token instance.
    IERC20 public immutable i_btc;

/*Constants*/
    /// @notice The maximum allowed time (in seconds) before a Chainlink price is considered stale.
    uint16 constant ORACLE_HEARTBEAT = 3600;   
    
    /// @notice Decimal factor for Ether (1e18) for use in unit conversion calculations.
    uint256 constant DECIMAL_FACTOR_ETH = 1 * 10 ** 18;
    
    /// @notice Decimal factor for USDC (1e2) used in conversion to 8-decimal USD value.
    uint256 constant DECIMAL_FACTOR_USDC = 1 * 10 ** 2;
    
    /// @notice Decimal factor for BTC (1e8) used in unit conversion calculations.
    uint256 constant DECIMAL_FACTOR_BTC = 1 * 10 ** 8;

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

    /* 
    @notice Emitted when a Chainlink price feed address is successfully updated by the owner. 
    @param feed The address of the new price feed.
    */
    event KipuBank_ChainlinkFeedUpdated(address feed);

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

    /*
    @notice Thrown when a Chainlink price feed returns a price of zero, indicating a potential issue
    */
    error KipuBank_OracleCompromised();

    /*
    @notice Thrown when a Chainlink price feed's last update is older than the configured ORACLE_HEARTBEAT.
    */
    error KipuBank_StalePrice();

/*Modifiers*/
    /*
    @dev Ensures that a withdrawal can only be made if it does not exceed the maximum allowed amount and the user has sufficient balance.
    @param amount The requested withdrawal amount.
    */
    modifier amountAvailable(uint256 amount, address token){
        if(i_maxWithdrawal < amount) revert KipuBank_FailedWithdrawal("Amount exceeds the maximum withdrawal");
        if(s_balances[token][msg.sender] < amount) revert KipuBank_InsufficientFounds("Not enough founds");
        _;
    }

    /*
    @dev Ensures that the current deposit amount, when converted to USD, does not exceed the bank's maximum capacity (i_bankCap).
    @param amount The amount of the token being deposited. 
    @param token The address of the token being deposited (address(0) for Ether).
    @custom:error KipuBank_FailedDeposit Thrown if the bank capacity is exceeded.
    */
    modifier _areFundsExceeded(uint256 amount, address token){
        uint256 founds = _consultFounds();
        uint256 newAmount = _convertToUSD(amount, token);
        if(founds + newAmount > i_bankCap)
            revert KipuBank_FailedDeposit("Total KipuBank's founds exceeded");
        _;
    }

    /*
    @dev Ensures that the token address used in the function is registered as supported in s_supportedTokens.
    @param token The address of the token to check.
    @custom:error KipuBank_NotSupportedToken Thrown if the token is not supported.
    */
    modifier _onlySupportedToken(address token){
        if(!s_supportedTokens[token])
            revert KipuBank_NotSupportedToken(token);
        _;
    }

    /*
    @dev Ensures the caller has granted sufficient ERC20 allowance to the bank contract for transferFrom. This is skipped for Ether (address(0)).
    @param _token The ERC20 token address.
    @param _amount The amount of token to be transferred.
    @custom:error KipuBank_FailedOperation Thrown if the allowance is insufficient.
    */
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
/*
    @notice Deploys the contract, initializing the bank's operational limits, token support, and Chainlink price feeds.
    @param initialOwner The address that will be set as the contract owner, granted control over administrative functions.
    @param _ethFeed The address of the Chainlink AggregatorV3Interface for the ETH/USD price feed.
    @param _btcFeed The address of the Chainlink AggregatorV3Interface for the BTC/USD price feed.
    @param _btc The address of the supported ERC20 token representing BTC.
    @param _usdc The address of the supported ERC20 token for USDC.
    @param _bankCap The maximum capacity the bank can hold, measured in unscaled USD.
    @param _maxWithdrawal The maximum amount, measured in unscaled USD, a user can withdraw per transaction.
    @custom:error KipuBank_DeniedContract Thrown if the initial bank capacity or maximum withdrawal are set to unrealistically low values (less than $10 \text{ USD}$ and $1 \text{ USD}$, respectively).
    */
    constructor(
        address initialOwner, 
        address _ethFeed, address _btcFeed, 
        address _btc, address _usdc, 
        uint256 _bankCap, uint256 _maxWithdrawal
        ) Ownable(initialOwner)
        {
        if (_bankCap < 10 || _maxWithdrawal < 1) revert KipuBank_DeniedContract();
        
        i_bankCap = _bankCap * 10**8;
        i_maxWithdrawal  = _maxWithdrawal* 10**8;

        s_supportedTokens[address(0)] = true;
        s_supportedTokens[_usdc] = true;
        i_usdc = IERC20(_usdc);
        s_supportedTokens[_btc] = true;
        i_btc = IERC20(_btc);

        s_btcFeed = AggregatorV3Interface(_btcFeed);
        s_ethFeed = AggregatorV3Interface(_ethFeed);
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
        return _consultFounds() / 10**8;
    }

    /*
    @notice Allows users to deposit Ether into the bank. Uses msg.value for the deposit amount.
    @dev Uses _depositEther internal function and emits {KipuBank_SuccessfulDeposit}. 
    @custom:error KipuBank_FailedDeposit Thrown if the bank capacity is exceeded.
    */
    function deposit() external payable nonReentrant{
        _depositEther(msg.sender, msg.value);
    }

    /*
    @notice Allows users to withdraw Ether from the bank.
    @param amount The amount of Ether to withdraw.
    @dev Requires available balance and maximum withdrawal limit via {amountAvailable}. 
    @custom:error KipuBank_FailedWithdrawal Thrown when Ether transfer fails.
    */
    function withdraw(uint256 amount) external nonReentrant amountAvailable(amount, address(0)){
        //Checks that the amount is Available
        //Effects
        s_balances[address(0)][msg.sender] -= amount;
        _actualizeOperations(false, address(0));
        (bool success, bytes memory error) = payable(msg.sender).call{value: amount}("");
        //Interactions
        if (!success) 
            revert KipuBank_FailedWithdrawal(error);
        emit KipuBank_SuccessfulWithdrawal(msg.sender, amount);
    }

    /*
    @notice Allows users to deposit USDC tokens into the bank. 
    @param amount The amount of USDC to deposit.
    @dev Transfers USDC using transferFrom, updates balance, and emits {KipuBank_SuccessfulDeposit}.
    @custom:error KipuBank_NotSupportedToken Thrown if USDC is not supported.
    @custom:error KipuBank_FailedOperation Thrown if ERC20 allowance is insufficient. 
    @custom:error KipuBank_FailedDeposit Thrown if the bank capacity is exceeded.
    */
    function depositUSDC(uint256 amount) external nonReentrant _onlySupportedToken(address(i_usdc)) _isTokenTransferAllowed(address(i_usdc), amount) _areFundsExceeded(amount, address(i_usdc)){
        //Checks that the token is supported by KipuBank
        //Effects
        i_usdc.transferFrom(msg.sender, address(this), amount);
        s_balances[address(i_usdc)][msg.sender] += amount;
        _actualizeOperations(true, address(i_usdc));
        //Interactions
        emit KipuBank_SuccessfulDeposit(msg.sender, amount);
    }
 
    /*
    @notice Allows users to withdraw USDC tokens from the bank.
    @param amount The amount of USDC to withdraw.
    @dev Transfers USDC using transfer, updates balance, and emits {KipuBank_SuccessfulWithdrawal}.
    @custom:error KipuBank_InsufficientFounds Thrown if user balance is too low.
    */
    function withdrawUSDC(uint256 amount) external nonReentrant _onlySupportedToken(address(i_usdc)) amountAvailable(amount, address(i_usdc)){
        //Checks that the balance has sufficient amount to withdraw
        //Effects
        s_balances[address(i_usdc)][msg.sender] -= amount;
        _actualizeOperations(false, address(i_usdc));
        //Interactions
        emit KipuBank_SuccessfulWithdrawal(msg.sender, amount);
        i_usdc.transfer(msg.sender, amount);
    }

    /*
    @notice Allows users to deposit BTC tokens (WBTC/renBTC equivalent) into the bank.
    @param amount The amount of BTC to deposit.
    @dev Transfers BTC using transferFrom, updates balance, and emits {KipuBank_SuccessfulDeposit}.
    @custom:error KipuBank_NotSupportedToken Thrown if BTC is not supported.
    @custom:error KipuBank_FailedOperation Thrown if ERC20 allowance is insufficient.
    @custom:error KipuBank_FailedDeposit Thrown if the bank capacity is exceeded.
    */
    function depositBTC(uint256 amount) external nonReentrant  _onlySupportedToken(address(i_btc)) _isTokenTransferAllowed(address(i_btc), amount) _areFundsExceeded(amount, address(i_btc)){
        //Checks that the token is supported by KipuBank
        //Effects
        i_btc.transferFrom(msg.sender, address(this), amount);
        s_balances[address(i_btc)][msg.sender] += amount;
        _actualizeOperations(true, address(i_btc));
        //Interactions
        emit KipuBank_SuccessfulDeposit(msg.sender, amount);
    }
 
    /*
    @notice Allows users to withdraw BTC tokens (WBTC/renBTC equivalent) from the bank.
    @param amount The amount of BTC to withdraw.
    @dev Transfers BTC using transfer, updates balance, and emits {KipuBank_SuccessfulWithdrawal}.
    @custom:error KipuBank_InsufficientFounds Thrown if user balance is too low.
    */
    function withdrawBTC(uint256 amount) external nonReentrant _onlySupportedToken(address(i_btc)) amountAvailable(amount, address(i_btc)){
        //Checks that the balance has sufficient amount to withdraw
        //Effects
        s_balances[address(i_btc)][msg.sender] -= amount;
        _actualizeOperations(false, address(i_btc));
        //Interactions
        emit KipuBank_SuccessfulWithdrawal(msg.sender, amount);
        i_btc.transfer(msg.sender, amount);
    }

    /*
    @notice Allows the owner to update the Chainlink price feed addresses for BTC and ETH.
    @param _btcFeed The new address for the BTC/USD price feed.
    @param _ethFeed The new address for the ETH/USD price feed.
    @dev Emits two {KipuBank_ChainlinkFeedUpdated} events.
    */
    function setFeeds(address _btcFeed, address _ethFeed) external onlyOwner{
        s_btcFeed = AggregatorV3Interface(_btcFeed);
        emit KipuBank_ChainlinkFeedUpdated(_btcFeed);
        s_ethFeed = AggregatorV3Interface(_ethFeed);
        emit KipuBank_ChainlinkFeedUpdated(_ethFeed);
    }

    /*
    @notice Allows the owner to withdraw accidentally sent ETH or ERC20 tokens that are not tracked as user deposits.
    @param token The address of the token to withdraw (address(0) for Ether).
    @param amount The amount to withdraw.
    @param recipient The address to send the funds to.
    @custom:error KipuBank_FailedWithdrawal Thrown if the Ether transfer fails.
    */
    function emergencyWithdrawal(address token, uint256 amount, address recipient) external onlyOwner {
        if (token == address(0)) {
            (bool success, ) = payable(recipient).call{value: amount}("");
            if (!success) revert KipuBank_FailedWithdrawal("ETH transfer failed");
        } else {
            IERC20(token).transfer(recipient, amount);
        }
    }

//private
    /*
    @dev Handles the actual deposit logic.
    @param addr The address of the depositor.
    @param amount The amount of Ether to deposit.
    */
    function _depositEther(address addr, uint256 amount) private _areFundsExceeded(amount, address(0)){
        s_balances[address(0)][addr] += amount;
        _actualizeOperations(true, address(0));

        emit KipuBank_SuccessfulDeposit(addr, amount);
    }

    /*
    @dev Updates the actual Ether amount stored in the contract.
    @param isDeposit Boolean indicating if operation is deposit (true) or withdrawal (false).
    @param amount The amount to update.
    */
    function _actualizeOperations(bool isDeposit, address token) private{
        if(isDeposit){
            s_totalDepositsByToken[token] += 1;
        }else{
            s_totalWithdrawalsByToken[token] += 1;
        }
    }

//view & pure
 
    /*
    @dev Calculates the total value of all assets (ETH, USDC, BTC) held by the contract, converted to 8-decimal USD.
    @return amount_ The total value of all assets in 8-decimal USD.
    */
    function _consultFounds() internal view returns (uint256 amount_){
        uint256 ethBalance = address(this).balance;
        uint256 usdcBalance = i_usdc.balanceOf(address(this));
        uint256 btcBalance = i_btc.balanceOf(address(this));

        uint256 ethToUSD = _convertEthToUSD(ethBalance);    
        uint256 usdcToUSD = _convertUsdcToUSD(usdcBalance);   
        uint256 btcToUSD =  _convertBtcToUSD(btcBalance);

        return ethToUSD + usdcToUSD + btcToUSD;
    }

    /*
    @dev Retrieves the latest ETH/USD price from the Chainlink feed, checking for staleness and validity.
    @return ethUSDPrice_ The current ETH price in USD (8 decimals).
    @custom:error KipuBank_OracleCompromised Thrown if the price is zero. 
    @custom:error KipuBank_StalePrice Thrown if the price is stale.
    */
    function _chainlinkFeedETH() internal view returns (uint256 ethUSDPrice_) {
        (, int256 ethUSDPrice,, uint256 updatedAt,) = s_ethFeed.latestRoundData();
        if (ethUSDPrice == 0) revert KipuBank_OracleCompromised();
        if (block.timestamp - updatedAt > ORACLE_HEARTBEAT) revert KipuBank_StalePrice();
        ethUSDPrice_ = uint256(ethUSDPrice);
    }

    /*
    @dev Converts an amount of Ether to its equivalent value in 8-decimal USD using the Chainlink feed.
    @param _ethAmount The amount of Ether (1e18) to convert. 
    @return convertedAmount_ The USD value (8 decimals).
    */
    function _convertEthToUSD(uint256 _ethAmount) internal view returns (uint256 convertedAmount_) {
        convertedAmount_ = (_ethAmount * _chainlinkFeedETH()) / DECIMAL_FACTOR_ETH;
    }

    /*
    @dev Converts an amount of USDC (1e6) to its equivalent value in 8-decimal USD (1e8).
    @param _usdcAmount The amount of USDC (1e6) to convert.
    @return convertedAmount_ The USD value (8 decimals).
    */
    function _convertUsdcToUSD(uint256 _usdcAmount) internal pure returns (uint256 convertedAmount_) {
        convertedAmount_ = _usdcAmount * DECIMAL_FACTOR_USDC;
    }

    /*
    @dev Retrieves the latest BTC/USD price from the Chainlink feed, checking for staleness and validity.
    @return btcUSDPrice_ The current BTC price in USD (8 decimals).
    @custom:error KipuBank_OracleCompromised Thrown if the price is zero.
    @custom:error KipuBank_StalePrice Thrown if the price is stale.
    */
    function _chainlinkFeedBTC() internal view returns (uint256 btcUSDPrice_) {
        (, int256 btcUSDPrice,, uint256 updatedAt,) = s_btcFeed.latestRoundData();
        if (btcUSDPrice == 0) revert KipuBank_OracleCompromised();
        if (block.timestamp - updatedAt > ORACLE_HEARTBEAT) revert KipuBank_StalePrice();
        btcUSDPrice_ = uint256(btcUSDPrice);
    }

    /*
    @dev Converts an amount of BTC (1e8) to its equivalent value in 8-decimal USD using the Chainlink feed.
    @param _btcAmount The amount of BTC (1e8) to convert.
    @return convertedAmount_ The USD value (8 decimals).
    */
    function _convertBtcToUSD(uint256 _btcAmount) internal view returns (uint256 convertedAmount_) {
        convertedAmount_ = (_btcAmount * _chainlinkFeedBTC()) / DECIMAL_FACTOR_BTC;
    }

    /*
    @dev Routes the conversion of a token amount (ETH, USDC, or BTC) to its equivalent value in 8-decimal USD.
    @param _amount The amount of the token to convert.
    @param _token The address of the token (address(0) for Ether).
    @return convertedAmount_ The USD value (8 decimals).
    @custom:error KipuBank_NotSupportedToken Thrown if the token is not recognized.
    */
    function _convertToUSD(uint256 _amount, address _token) internal view returns (uint256 convertedAmount_) 
    {
        if (_token == address(0)) {
            convertedAmount_ = _convertEthToUSD(_amount);
        } else if (_token == address(i_usdc)) {
            convertedAmount_ = _convertUsdcToUSD(_amount);
        } else if (_token == address(i_btc)) {
            convertedAmount_ = _convertBtcToUSD(_amount);
        }else {
            revert KipuBank_NotSupportedToken(_token); 
    }
        return convertedAmount_;
    }
}