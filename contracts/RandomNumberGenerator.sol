// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import "./interfaces/ITetradLottery.sol";

// Beta version

contract RandomNumberGenerator is VRFConsumerBaseV2Plus {
    event RequestSent(uint256 requestId, uint32 numWords);
    event RequestFulfilled(uint256 requestId, uint256[] randomWords);

    struct RequestStatus {
        bool fulfilled;
        bool exists;
        uint256[] randomWords;
        uint256 lotteryId;
    }

    mapping(uint256 => RequestStatus) public requests;
    ITetradLottery lottery;

    uint256 subscriptionId;

    // https://docs.chain.link/docs/vrf/v2/subscription/supported-networks/#configurations
    bytes32 keyHash =
        0x9e9e46732b32662b9adc6f3abdf6c5e926a666d174a4d6b8e39c4cca76a38897;
    uint32 callbackGasLimit = 500000;
    uint16 requestConfirmations = 1;
    bool public nativePayment = false;

    modifier onlyLottery() {
        if (msg.sender != address(lottery)) revert();
        _;
    }

    constructor(uint256 _subscriptionId, address _coordinator, address _lottery)
        VRFConsumerBaseV2Plus(_coordinator)
    {
        lottery = ITetradLottery(_lottery);
        subscriptionId = _subscriptionId;
    }

    function generate(uint256 _id) external onlyLottery() returns (uint256 requestId) {
        requestId = s_vrfCoordinator.requestRandomWords(
    VRFV2PlusClient.RandomWordsRequest({
        keyHash: keyHash,
        subId: subscriptionId,
        requestConfirmations: requestConfirmations,
        callbackGasLimit: callbackGasLimit,
        numWords: 1,
        extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: nativePayment}))
    })
);
        requests[requestId] = RequestStatus({
            randomWords: new uint256[](0),
            exists: true,
            fulfilled: false,
            lotteryId: _id
        });
        emit RequestSent(requestId, 1);
        return requestId;
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) internal override {
        require(requests[requestId].exists, "request not found");
        uint256 lotteryId = requests[requestId].lotteryId;
        lottery.makeLotteryClaimable(lotteryId, randomWords[0]);
        emit RequestFulfilled(requestId, randomWords);
    }

    function updateLotteryAddress(address _lottery) external onlyOwner() {
        lottery = ITetradLottery(_lottery);
    }

    function updateKeyHash(bytes32 _keyHash) external onlyOwner() {
        keyHash = _keyHash;
    }

    function updateCallbackGasLimit(uint32 _callbackGasLimit) external onlyOwner() {
        callbackGasLimit = _callbackGasLimit;
    }

    function updateConfirmations(uint16 _confirmations) external onlyOwner() {
        requestConfirmations = _confirmations;
    }

    function updateSubscriptionId(uint256 _subscriptionId) external onlyOwner() {
        subscriptionId = _subscriptionId;
    }

     function updateNativePayment(bool _nativePayment) external onlyOwner() {
        nativePayment = _nativePayment;
    }
}