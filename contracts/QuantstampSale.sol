// Quantstamp Technologies Inc. (info@quantstamp.com)

pragma solidity ^0.4.15;

import './lifecycle/Pausable.sol';
import './math/SafeMath.sol';
import './QuantstampToken.sol';

/**
 * The QuantstampSale smart contract is used for selling QuantstampToken
 * tokens (QSP). It does so by converting ETH received into a quantity of
 * tokens that are transferred to the contributor via the ERC20-compatible
 * transferFrom() function.
 */
contract QuantstampSale is Pausable {

    using SafeMath for uint256;

    // The beneficiary is the future recipient of the funds
    address public beneficiary;

    // The crowdsale has a funding goal, cap, deadline, and minimum contribution
    uint public fundingGoal;
    uint public fundingCap;
    uint public minContribution;
    bool public fundingGoalReached = false;
    bool public fundingCapReached = false;
    bool public saleClosed = false;

    // Time period of sale (UNIX timestamps)
    uint public startTime;
    uint public endTime;

    // Keeps track of the amount of wei raised
    uint public amountRaised;

    // Refund amount, should it be required
    uint public refundAmount;

    // prevent certain functions from being recursively called
    bool private rentrancy_lock = false;

    // The token being sold
    QuantstampToken public tokenReward;

    // A map that tracks the amount of wei contributed by address
    mapping(address => uint256) public balanceOf;

    // A map that tracks contributions that occurred off the blockchain.
    // This is tracked during whitelist registration.
    mapping(address => uint256) public offchainBalanceOf;

    // Maps that maintain information on registered contributors
    mapping(address=>bool) public registered;
    mapping(address=>uint) public userCapInWei;
    mapping(address=>uint) public userRateQspToEther;


    // Events
    event GoalReached(address _beneficiary, uint _amountRaised);
    event CapReached(address _beneficiary, uint _amountRaised);
    event FundTransfer(address _backer, uint _amount, bool _isContribution);
    event RegistrationStatusChanged(address target, bool isRegistered, uint capInWei, uint rateQspToEther);


    // Modifiers
    modifier beforeDeadline()   { require (currentTime() < endTime); _; }
    modifier afterDeadline()    { require (currentTime() >= endTime); _; }
    modifier afterStartTime()    { require (currentTime() >= startTime); _; }

    modifier saleNotClosed()    { require (!saleClosed); _; }

    modifier nonReentrant() {
        require(!rentrancy_lock);
        rentrancy_lock = true;
        _;
        rentrancy_lock = false;
    }

    /**
     * Constructor for a crowdsale of QuantstampToken tokens.
     *
     * @param ifSuccessfulSendTo            the beneficiary of the fund
     * @param fundingGoalInEthers           the minimum goal to be reached
     * @param fundingCapInEthers            the cap (maximum) size of the fund
     * @param minimumContributionInWei      minimum contribution (in wei)
     * @param start                         the start time (UNIX timestamp)
     * @param durationInMinutes             the duration of the crowdsale in minutes
     * @param addressOfTokenUsedAsReward    address of the token being sold
     */
    function QuantstampSale(
        address ifSuccessfulSendTo,
        uint fundingGoalInEthers,
        uint fundingCapInEthers,
        uint minimumContributionInWei,
        uint start,
        uint durationInMinutes,
        address addressOfTokenUsedAsReward
    ) {
        require(ifSuccessfulSendTo != address(0) && ifSuccessfulSendTo != address(this));
        require(addressOfTokenUsedAsReward != address(0) && addressOfTokenUsedAsReward != address(this));
        require(fundingGoalInEthers <= fundingCapInEthers);
        require(durationInMinutes > 0);
        beneficiary = ifSuccessfulSendTo;
        fundingGoal = fundingGoalInEthers * 1 ether;
        fundingCap = fundingCapInEthers * 1 ether;
        minContribution = minimumContributionInWei;
        startTime = start;
        endTime = start + durationInMinutes * 1 minutes; // TODO double check
        tokenReward = QuantstampToken(addressOfTokenUsedAsReward);
    }

    /**
     * This fallback function is called whenever Ether is sent to the
     * smart contract. It can only be executed when the crowdsale is
     * not paused, not closed, and before the deadline has been reached.
     *
     * This function will update state variables for whether or not the
     * funding goal or cap have been reached. It also ensures that the
     * tokens are transferred to the sender, and that the correct
     * number of tokens are sent according to the current rate.
     */
    function () payable whenNotPaused beforeDeadline afterStartTime saleNotClosed nonReentrant {
        require(msg.value >= minContribution);

        uint amount = msg.value;
        uint totalBalance = balanceOf[msg.sender].add(offchainBalanceOf[msg.sender]);

        // ensure that the user adheres to whitelist restrictions
        require(registered[msg.sender]);
        require(totalBalance.add(amount) <= userCapInWei[msg.sender]);


        // Update the sender's balance of wei contributed and the amount raised
        balanceOf[msg.sender] = balanceOf[msg.sender].add(amount);
        amountRaised = amountRaised.add(amount);

        // Compute the number of tokens to be rewarded to the sender
        // Note: it's important for this calculation that both wei
        // and QSP have the same number of decimal places (18)
        uint rate = userRateQspToEther[msg.sender];
        uint numTokens = amount.mul(rate);

        // Transfer the tokens from the crowdsale supply to the sender
        if (tokenReward.transferFrom(tokenReward.owner(), msg.sender, numTokens)) {
            FundTransfer(msg.sender, amount, true);
            // Check if the funding goal or cap have been reached
            // TODO check impact on gas cost
            checkFundingGoal();
            checkFundingCap();
        }
        else {
            revert();
        }
    }


    /**
     * @dev Changes registration status of an address for participation.
     * @param target Address that will be registered/deregistered.
     * @param isRegistered New registration status of address.
     * @param capInWei The maximum amount of wei that the user can contribute.
     * @param rateQspToEther The rate at which the user will QSP for Ether contributions.
     * @param initialContributionInWei The amount of wei contributed before the crowdsale.
     */
    function changeRegistrationStatus(address target,
                                      bool isRegistered,
                                      uint capInWei,
                                      uint rateQspToEther,
                                      uint initialContributionInWei)
        public
        onlyOwner
        //only24HBeforeSale // TODO do we want this?
    {
        require(!isRegistered || capInWei > 0);
        require(!isRegistered || rateQspToEther > 0);
        require(isRegistered  || capInWei == 0);
        require(isRegistered  || rateQspToEther == 0);
        require(initialContributionInWei <= capInWei);


        registered[target] = isRegistered;
        userCapInWei[target] = capInWei;
        userRateQspToEther[target] = rateQspToEther;
        RegistrationStatusChanged(target, isRegistered, capInWei, rateQspToEther);

        if(initialContributionInWei > 0){
            offchainBalanceOf[target] = initialContributionInWei;
            uint numTokens = initialContributionInWei.mul(rateQspToEther);
            // if the user somehow already has a balance, don't double-issue tokens
            numTokens = numTokens.sub(tokenReward.balanceOf(target));

            // Transfer the tokens from the crowdsale supply to the sender
            if (tokenReward.transferFrom(tokenReward.owner(), target, numTokens)) {
                // TODO: is this actually a FundTransfer?
                // FundTransfer(target, initialContributionInWei, true);
                // Check if the funding goal or cap have been reached
                checkFundingGoal();
                checkFundingCap();
            }
            else {
                revert();
            }
        }
    }


    /**
     * @dev Changes registration statuses of addresses for participation.
     * @param targets Addresses that will be registered/deregistered.
     * @param isRegistered New registration status of addresses.
     * @param caps The maximum amount of wei that each user can contribute.
     * @param rates The rates at which each user will QSP for Ether contributions.
     * @param initialContributionsInWei The amount of wei contributed by each user before the crowdsale.
     * TODO: Is there any scenario where we'd have to unregister a user that has an initial balance?
     * TODO: I'm imagining this is just used once before the sale goes live, and we never have to call again.
     *       If we would need to periodically update contributions, this would need to change.
     */
    function changeRegistrationStatuses(address[] targets,
                                        bool isRegistered,
                                        uint[] caps,
                                        uint[] rates,
                                        uint[] initialContributionsInWei)
        public
        onlyOwner
        //only24HBeforeSale // TODO do we want this?
    {
        // check that all arrays have the same length
        require(targets.length == caps.length);
        require(caps.length == rates.length);
        require(rates.length == initialContributionsInWei.length);

        for (uint i = 0; i < targets.length; i++) {
            changeRegistrationStatus(targets[i], isRegistered, caps[i], rates[i], initialContributionsInWei[i]);
        }
    }


    /**
     * The owner can terminate the crowdsale at any time.
     */
    function terminate() external onlyOwner {
        saleClosed = true;
    }

    /**
     * The owner can allocate the specified amount of tokens from the
     * crowdsale allowance to the recipient (_to).
     *
     * NOTE: be extremely careful to get the amounts correct, which
     * are in units of wei and mini-QSP. Every digit counts.
     *
     * @param _to            the recipient of the tokens
     * @param amountWei     the amount contributed in wei
     * @param amountMiniQsp the amount of tokens transferred in mini-QSP
     */
    function ownerAllocateTokens(address _to, uint amountWei, uint amountMiniQsp) external
            onlyOwner nonReentrant
    {
        if (!tokenReward.transferFrom(tokenReward.owner(), _to, amountMiniQsp)) {
            revert();
        }
        balanceOf[_to] = balanceOf[_to].add(amountWei);
        amountRaised = amountRaised.add(amountWei);
        FundTransfer(_to, amountWei, true);
        checkFundingGoal();
        checkFundingCap();
    }

    /**
     * The owner can call this function to withdraw the funds that
     * have been sent to this contract for the crowdsale subject to
     * the funding goal having been reached. The funds will be sent
     * to the beneficiary specified when the crowdsale was created.
     */
    function ownerSafeWithdrawal() external onlyOwner nonReentrant {
        require(fundingGoalReached);
        uint balanceToSend = this.balance;
        beneficiary.transfer(balanceToSend);
        FundTransfer(beneficiary, balanceToSend, false);
    }

    /**
     * The owner can unlock the fund with this function. The use-
     * case for this is when the owner decides after the deadline
     * to allow contributors to be refunded their contributions.
     * Note that the fund would be automatically unlocked if the
     * minimum funding goal were not reached.
     */
    function ownerUnlockFund() external afterDeadline onlyOwner {
        fundingGoalReached = false;
    }

    /**
     * This function permits anybody to withdraw the funds they have
     * contributed if and only if the deadline has passed and the
     * funding goal was not reached.
     */
    function safeWithdrawal() external afterDeadline nonReentrant {
        if (!fundingGoalReached) {
            uint amount = balanceOf[msg.sender];
            balanceOf[msg.sender] = 0;
            if (amount > 0) {
                msg.sender.transfer(amount);
                FundTransfer(msg.sender, amount, false);
                refundAmount = refundAmount.add(amount);
            }
        }
    }

    /**
     * Checks if the funding goal has been reached. If it has, then
     * the GoalReached event is triggered.
     */
    function checkFundingGoal() internal {
        if (!fundingGoalReached) {
            if (amountRaised >= fundingGoal) {
                fundingGoalReached = true;
                GoalReached(beneficiary, amountRaised);
            }
        }
    }

    /**
     * Checks if the funding cap has been reached. If it has, then
     * the CapReached event is triggered.
     */
    function checkFundingCap() internal {
        if (!fundingCapReached) {
            if (amountRaised >= fundingCap) {
                fundingCapReached = true;
                saleClosed = true;
                CapReached(beneficiary, amountRaised);
            }
        }
    }

    /**
     * Returns the current time.
     * Useful to abstract calls to "now" for tests.
    */
    function currentTime() constant returns (uint _currentTime) {
        return now;
    }


    /**
     * Given an amount in QSP, this method returns the equivalent amount
     * in mini-QSP.
     *
     * @param amount    an amount expressed in units of QSP
     */
    function convertToMiniQsp(uint amount) internal constant returns (uint) {
        return amount * (10 ** uint(tokenReward.decimals()));
    }



}
