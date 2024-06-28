// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IRandomNumberGenerator.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import "./interfaces/IWETH.sol";

contract TetradLottery is CCIPReceiver, Ownable {
    struct Lottery {
        uint256[6] rewardsPerBracket;
        uint256[6] countWinnersPerBracket;
        uint256 firstTicketId;
        uint256 lastTicketId;
        uint256 amountCollected;
        uint256 totalAmountCollected;
        uint32 finalNumber;
    }

    struct Ticket {
        uint32 number;
        address owner;
    }

    struct CCIPData {
        address user;
        uint256 call;
        uint32[] tickets;
        uint256[] ticketIds;
        uint256 id;
        uint32[] brackets;
    }

    mapping(uint256 => Lottery) lotteries;
    mapping(address => uint256[]) roundsJoined;
    mapping(uint256 => Ticket) public tickets;
    mapping(uint256 => uint256) rewardsBreakdown; // 0: 1 matching number // 5: 6 matching numbers

    uint256 public price = 500000000000000;
    uint256 currentTicketId;
    uint256 lastLotteryPurchased;
    address public treasury;
    uint256 public treasuryFees = 1;

    mapping(uint256 => mapping(uint32 => uint256))
        private _numberTicketsPerLotteryId;
    mapping(address => mapping(uint256 => uint256[]))
        private _userTicketIdsPerLotteryId;
    mapping(uint32 => uint32) private bracketCalculator;

    IRandomNumberGenerator internal randomNumberGenerator;

    error NotRandomNumberGenerator();
    error InvalidTickets();
    error InsufficientPayment();
    error LotteryNotDrawn();
    error LotteryDrawn();
    error TransferFailed();
    error FutureLottery();
    error PreviousLotteryNotDrawn();
    error SourceChainNotAllowlisted(uint64 sourceChainSelector);
    error SenderNotAllowlisted(address sender);

    modifier onlyRandomNumberGenerator() {
        if (msg.sender != address(randomNumberGenerator))
            revert NotRandomNumberGenerator();
        _;
    }

    event LotteryNumberDrawn(
        uint256 indexed lotteryId,
        uint256 finalNumber,
        uint256 countWinningTickets
    );
    event TicketsPurchase(
        address indexed buyer,
        uint256 indexed lotteryId,
        uint256 numberTickets
    );
    event TicketsClaim(
        address indexed claimer,
        uint256 amount,
        uint256 indexed lotteryId,
        uint256 numberTickets
    );

    IWETH public WETH;

    constructor(
        address _randomNumberGenerator,
        address _router,
        address _WETH,
        address _treasury
    ) CCIPReceiver(_router) {
        treasury = _treasury;
        randomNumberGenerator = IRandomNumberGenerator(_randomNumberGenerator);

        bracketCalculator[0] = 1;
        bracketCalculator[1] = 11;
        bracketCalculator[2] = 111;
        bracketCalculator[3] = 1111;
        bracketCalculator[4] = 11111;
        bracketCalculator[5] = 111111;

        rewardsBreakdown[0] = 1500;
        rewardsBreakdown[1] = 1750;
        rewardsBreakdown[2] = 2000;
        rewardsBreakdown[3] = 2250;
        rewardsBreakdown[4] = 1000;
        rewardsBreakdown[5] = 1500;

        WETH = IWETH(_WETH);
        lotteries[(block.timestamp / 24 hours) - 1].finalNumber = 1; //so the real first round can be called
    }

    function buyTicketsWithEther(uint32[] memory _numbers, address _user)
        external
        payable
    {
        uint256 payment = _numbers.length * price;

        WETH.deposit{value: payment}();

        buyTickets(_numbers, _user, payment);
    }

    function buyTicketsWithWETH(uint32[] memory _numbers, address _user)
        external
    {
        uint256 payment = _numbers.length * price;
        bool sent = WETH.transferFrom(_user, address(this), payment);
        if (!sent) revert("Insufficient payment");

        buyTickets(_numbers, _user, payment);
    }

    function buyTickets(
        uint32[] memory _numbers,
        address _user,
        uint256 _payment
    ) internal {
        if (_numbers.length == 0) revert InvalidTickets();
        uint256 id = block.timestamp / 24 hours;

        if (lotteries[id].amountCollected == 0) {
            lotteries[id].firstTicketId = currentTicketId;
            if (
                lotteries[id - 1].amountCollected != 0 &&
                lotteries[id - 1].lastTicketId == 0
            ) {
                lotteries[id - 1].lastTicketId = currentTicketId - 1;
            }
        }

        for (uint256 i = 0; i < _numbers.length; i++) {
            uint32 thisTicketNumber = _numbers[i];

            if (thisTicketNumber < 1000000 || thisTicketNumber > 1999999)
                revert InvalidTickets();

            _numberTicketsPerLotteryId[id][1 + (thisTicketNumber % 10)]++;
            _numberTicketsPerLotteryId[id][11 + (thisTicketNumber % 100)]++;
            _numberTicketsPerLotteryId[id][111 + (thisTicketNumber % 1000)]++;
            _numberTicketsPerLotteryId[id][1111 + (thisTicketNumber % 10000)]++;
            _numberTicketsPerLotteryId[id][
                11111 + (thisTicketNumber % 100000)
            ]++;
            _numberTicketsPerLotteryId[id][
                111111 + (thisTicketNumber % 1000000)
            ]++;

            _userTicketIdsPerLotteryId[_user][id].push(currentTicketId);

            tickets[currentTicketId] = Ticket({
                number: thisTicketNumber,
                owner: _user
            });

            currentTicketId++;
        }

        if (
            roundsJoined[_user].length == 0 ||
            roundsJoined[_user][roundsJoined[_user].length - 1] != id
        ) {
            roundsJoined[_user].push(id);
        }

        lotteries[id].amountCollected += (_payment);
        lotteries[id].totalAmountCollected += (_payment);

        emit TicketsPurchase(_user, id, _numbers.length);
    }

    function claimTickets(
        uint256 _id,
        uint256[] calldata _ticketIds,
        uint32[] calldata _brackets
    ) external {
        if (_ticketIds.length != _brackets.length) revert InvalidTickets();
        if (_ticketIds.length == 0) revert InvalidTickets();
        if (lotteries[_id].finalNumber == 0) revert LotteryNotDrawn();

        uint256 rewardToTransfer;

        for (uint256 i = 0; i < _ticketIds.length; i++) {
            require(_brackets[i] < 6, "Bracket out of range");

            uint256 thisTicketId = _ticketIds[i];

            require(
                lotteries[_id].lastTicketId >= thisTicketId,
                "TicketId too high"
            );
            require(
                lotteries[_id].firstTicketId <= thisTicketId,
                "TicketId too low"
            );
            require(msg.sender == tickets[thisTicketId].owner, "Not the owner");

            // Update the lottery ticket owner to 0x address
            tickets[thisTicketId].owner = address(0);

            uint256 rewardForTicketId = calculateRewardsForTicketId(
                _id,
                thisTicketId,
                _brackets[i]
            );

            // Check user is claiming the correct bracket
            require(rewardForTicketId != 0, "No prize for this bracket");

            if (_brackets[i] != 5) {
                require(
                    calculateRewardsForTicketId(
                        _id,
                        thisTicketId,
                        _brackets[i] + 1
                    ) == 0,
                    "Bracket must be higher"
                );
            }
            rewardToTransfer += rewardForTicketId;
        }
        bool sent = WETH.transfer(msg.sender, (rewardToTransfer * (10000 - treasuryFees)) / 10000);
        bool _sent = WETH.transfer(treasury, (rewardToTransfer * treasuryFees) / 10000);
        if (!sent || !_sent) revert TransferFailed();

        emit TicketsClaim(msg.sender, (rewardToTransfer * (10000 - treasuryFees)) / 10000, _id, _ticketIds.length);
    }

    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage)
        internal
        override
    {
        CCIPData memory data = abi.decode(any2EvmMessage.data, (CCIPData));
        if (data.call == 0) {
            require(
                any2EvmMessage.destTokenAmounts[0].token == address(WETH),
                "Not WETH"
            );

            uint256 payment = data.tickets.length * price;
            if (payment > any2EvmMessage.destTokenAmounts[0].amount)
                revert InsufficientPayment();

            buyTickets(data.tickets, data.user, payment);
        } else {
            if (data.call == 1) {
                claimTicketsCrossChain(
                    data.id,
                    data.ticketIds,
                    data.brackets,
                    data.user,
                    any2EvmMessage.sourceChainSelector
                );
            }
        }
    }

    function claimTicketsCrossChain(
        uint256 _id,
        uint256[] memory _ticketIds,
        uint32[] memory _brackets,
        address _user,
        uint64 _sourceChain
    ) internal {
        if (_ticketIds.length != _brackets.length) revert InvalidTickets();
        if (_ticketIds.length == 0) revert InvalidTickets();
        if (lotteries[_id].finalNumber == 0) revert LotteryNotDrawn();

        uint256 rewardToTransfer;

        for (uint256 i = 0; i < _ticketIds.length; i++) {
            require(_brackets[i] < 6, "Bracket out of range");

            uint256 thisTicketId = _ticketIds[i];

            require(
                lotteries[_id].lastTicketId >= thisTicketId,
                "TicketId too high"
            );
            require(
                lotteries[_id].firstTicketId <= thisTicketId,
                "TicketId too low"
            );
            require(_user == tickets[thisTicketId].owner, "Not the owner");

            // Update the lottery ticket owner to 0x address
            tickets[thisTicketId].owner = address(0);

            uint256 rewardForTicketId = calculateRewardsForTicketId(
                _id,
                thisTicketId,
                _brackets[i]
            );

            // Check user is claiming the correct bracket
            require(rewardForTicketId != 0, "No prize for this bracket");

            if (_brackets[i] != 5) {
                require(
                    calculateRewardsForTicketId(
                        _id,
                        thisTicketId,
                        _brackets[i] + 1
                    ) == 0,
                    "Bracket must be higher"
                );
            }
            rewardToTransfer += rewardForTicketId;
        }

        bool sent = WETH.transfer(treasury, (rewardToTransfer * treasuryFees) / 10000);
        if (!sent) revert TransferFailed();
        transferFundsCrossChain((rewardToTransfer * (10000 - treasuryFees)) / 10000, _user, _sourceChain);

        emit TicketsClaim(_user, (rewardToTransfer * (10000 - treasuryFees)) / 10000, _id, _ticketIds.length);
    }

    function transferFundsCrossChain(
        uint256 _amount,
        address _address,
        uint64 _to
    ) internal {
        IRouterClient router = IRouterClient(this.getRouter());

        uint256 fees = router.getFee(
            _to,
            createEVM2AnyMessage(_amount, _address)
        );

        if (_amount <= fees) revert("Insufficent rewards");
        _amount -= fees;

        WETH.approve(address(router), _amount);

        WETH.withdraw(fees);

        router.ccipSend{value: fees}(
            _to,
            createEVM2AnyMessage(_amount, _address)
        );
    }

    function createEVM2AnyMessage(uint256 amount, address receiver)
        internal
        view
        returns (Client.EVM2AnyMessage memory)
    {
        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: address(WETH),
            amount: amount
        });

        return
            Client.EVM2AnyMessage({
                receiver: abi.encode(receiver),
                data: "",
                tokenAmounts: tokenAmounts,
                extraArgs: Client._argsToBytes(
                    Client.EVMExtraArgsV1({gasLimit: 0})
                ),
                feeToken: address(0)
            });
    }

    function calculateRewardsForTicketId(
        uint256 _id,
        uint256 _ticketId,
        uint32 _bracket
    ) internal view returns (uint256) {
        uint32 winningTicketNumber = lotteries[_id].finalNumber;
        uint32 userNumber = tickets[_ticketId].number;

        uint32 transformedWinningNumber = bracketCalculator[_bracket] +
            (winningTicketNumber % (uint32(10)**(_bracket + 1)));

        uint32 transformedUserNumber = bracketCalculator[_bracket] +
            (userNumber % (uint32(10)**(_bracket + 1)));

        if (transformedWinningNumber == transformedUserNumber) {
            return lotteries[_id].rewardsPerBracket[_bracket];
        } else {
            return 0;
        }
    }

    function drawLottery(uint256 _id) external {
        if ((block.timestamp / 24 hours) <= _id) revert FutureLottery();
        if (lotteries[_id].finalNumber != 0) revert LotteryDrawn();
        if (lotteries[_id - 1].finalNumber == 0)
            revert PreviousLotteryNotDrawn();

        lotteries[_id].lastTicketId = currentTicketId - 1;
        randomNumberGenerator.generate(_id);
    }

    function makeLotteryClaimable(uint256 _id, uint256 _result)
        external
        onlyRandomNumberGenerator
    {
        uint32 finalNumber = uint32(1000000 + (_result % 1000000));

        uint256 numberAddressesInPreviousBracket;

        for (uint32 i = 0; i < 6; i++) {
            uint32 j = 5 - i;
            uint32 transformedWinningNumber = bracketCalculator[j] +
                (finalNumber % (uint32(10)**(j + 1)));

            lotteries[_id].countWinnersPerBracket[j] =
                _numberTicketsPerLotteryId[_id][transformedWinningNumber] -
                numberAddressesInPreviousBracket;

            // A. If number of users for this _bracket number is superior to 0
            if (
                (_numberTicketsPerLotteryId[_id][transformedWinningNumber] -
                    numberAddressesInPreviousBracket) != 0
            ) {
                // B. If rewards at this bracket are > 0, calculate, else, report the numberAddresses from previous bracket
                if (rewardsBreakdown[j] != 0) {
                    lotteries[_id].rewardsPerBracket[j] +=
                        ((rewardsBreakdown[j] *
                            lotteries[_id].amountCollected) /
                            (_numberTicketsPerLotteryId[_id][
                                transformedWinningNumber
                            ] - numberAddressesInPreviousBracket)) /
                        10000;

                    numberAddressesInPreviousBracket = _numberTicketsPerLotteryId[
                        _id
                    ][transformedWinningNumber];
                }
            } else {
                lotteries[_id + 1].totalAmountCollected +=
                    (rewardsBreakdown[j] * lotteries[_id].amountCollected) /
                    10000;
                lotteries[_id + 1].rewardsPerBracket[j] +=
                    (rewardsBreakdown[j] * lotteries[_id].amountCollected) /
                    10000 +
                    lotteries[_id].rewardsPerBracket[j];
            }
        }

        lotteries[_id].finalNumber = finalNumber;

        emit LotteryNumberDrawn(
            _id,
            finalNumber,
            numberAddressesInPreviousBracket
        );
    }

    function viewUserInfoForLotteryId(
        address _user,
        uint256 _lotteryId,
        uint256 _cursor,
        uint256 _size
    )
        external
        view
        returns (
            uint256[] memory,
            uint32[] memory,
            bool[] memory,
            uint256
        )
    {
        uint256 length = _size;
        uint256 numberTicketsBoughtAtLotteryId = _userTicketIdsPerLotteryId[_user][_lotteryId].length;

        if (length > (numberTicketsBoughtAtLotteryId - _cursor)) {
            length = numberTicketsBoughtAtLotteryId - _cursor;
        }

        uint256[] memory lotteryTicketIds = new uint256[](length);
        uint32[] memory ticketNumbers = new uint32[](length);
        bool[] memory ticketStatuses = new bool[](length);

        for (uint256 i = 0; i < length; i++) {
            lotteryTicketIds[i] = _userTicketIdsPerLotteryId[_user][_lotteryId][i + _cursor];
            ticketNumbers[i] = tickets[lotteryTicketIds[i]].number;

            // True = ticket claimed
            if (tickets[lotteryTicketIds[i]].owner == address(0)) {
                ticketStatuses[i] = true;
            } else {
                // ticket not claimed (includes the ones that cannot be claimed)
                ticketStatuses[i] = false;
            }
        }

        return (lotteryTicketIds, ticketNumbers, ticketStatuses, _cursor + length);
    }

    function viewCurrentLotteryId() external view returns (uint256) {
        return (block.timestamp / 24 hours);
    }

    function changeRandomNumberGenerator(address _newRandomNumberGenerator)
        external
        onlyOwner
    {
        randomNumberGenerator = IRandomNumberGenerator(
            _newRandomNumberGenerator
        );
    }

    function changeRewardsBreakdown(uint256 _index, uint256 _distribution)
        external
        onlyOwner
    {
        rewardsBreakdown[_index] = _distribution;
    }

    function viewLottery(uint256 _lotteryId)
        external
        view
        returns (Lottery memory)
    {
        return lotteries[_lotteryId];
    }

    function viewRoundsJoined(address _user)
        external
        view
        returns (uint256[] memory)
    {
        return (roundsJoined[_user]);
    }

    function setTreasury(address _treasury) onlyOwner() external {
        treasury = _treasury;
    }
    function setTreasuryFees(uint256 _fees) onlyOwner() external {
        treasuryFees = _fees;
    }
    function setPrice(uint256 _price) onlyOwner() external {
        price = _price;
    }
}
