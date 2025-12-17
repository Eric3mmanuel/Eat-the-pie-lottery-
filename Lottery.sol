
//address at -0x86510c295644D1214Dc62112E15ec314076AcF2c
// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "witnet-solidity-bridge/contracts/interfaces/IWitnetRandomness.sol";
import "./NFTPrize.sol";

/**
    ███████╗ █████╗ ████████╗    ████████╗██╗  ██╗███████╗    ██████╗ ██╗███████╗
    ██╔════╝██╔══██╗╚══██╔══╝    ╚══██╔══╝██║  ██║██╔════╝    ██╔══██╗██║██╔════╝
    █████╗  ███████║   ██║          ██║   ███████║█████╗      ██████╔╝██║█████╗
    ██╔══╝  ██╔══██║   ██║          ██║   ██╔══██║██╔══╝      ██╔═══╝ ██║██╔══╝
    ███████╗██║  ██║   ██║          ██║   ██║  ██║███████╗    ██║     ██║███████╗
    ╚══════╝╚═╝  ╚═╝   ╚═╝          ╚═╝   ╚═╝  ╚═╝╚══════╝    ╚═╝     ╚═╝╚══════╝

 * @title EatThePie Layer 2 Lottery V2
 * @dev Implements a decentralized lottery system with witnet randomness and NFT prizes
 *
 */

// Permit2 interfaces
interface IPermit2 {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}

contract Lottery is Ownable, ReentrancyGuard {
    // Enums
    enum Difficulty { Easy, Medium, Hard }
    enum GameStatus { InPlay, Drawing, Completed }

    /**
     * @dev Struct containing basic game information
     */
    struct GameBasicInfo {
        uint256 gameId;
        GameStatus status;
        uint256 prizePool;
        uint256 numberOfWinners;
        uint256[4] winningNumbers;
    }

    /**
     * @dev Struct containing detailed game information
     */
    struct GameDetailedInfo {
        uint256 gameId;
        GameStatus status;
        uint256 prizePool;
        uint256 numberOfWinners;
        uint256 goldWinners;
        uint256 silverWinners;
        uint256 bronzeWinners;
        uint256[4] winningNumbers;
        Difficulty difficulty;
        uint256 drawInitiatedBlock;
        uint256 randomSeed;
        uint256[3] payouts;
    }

    // L2 Specific - ERC20 token for payments
    IERC20 public immutable paymentToken;
    IPermit2 public immutable permit2;
    address public constant PERMIT2_ADDRESS = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Contracts
    NFTPrize public immutable nftPrize;

    // Constants
    uint256 private constant BASIS_POINTS = 10000;
    uint256 public constant GOLD_PERCENTAGE = 6000;
    uint256 public constant SILVER_PLACE_PERCENTAGE = 2500;
    uint256 public constant BRONZE_PLACE_PERCENTAGE = 1400;
    uint256 public constant FEE_PERCENTAGE = 100;
    uint256 public constant FEE_MAX_IN_TOKENS = 1000000 * 1e18;
    uint256 public constant EASY_MAX = 25;
    uint256 public constant EASY_ETHERBALL_MAX = 10;
    uint256 public constant MEDIUM_MAX = 50;
    uint256 public constant MEDIUM_ETHERBALL_MAX = 10;
    uint256 public constant HARD_MAX = 75;
    uint256 public constant HARD_ETHERBALL_MAX = 10;
    uint256 public constant DRAW_MIN_TIME_PERIOD = 4 days;

    // State variables
    address public feeRecipient;
    uint256 public ticketPrice;
    uint256 public currentGameNumber;
    uint256 public lastDrawTime;
    uint256 public consecutiveJackpotGames;
    uint256 public consecutiveNonJackpotGames;
    Difficulty public newDifficulty;
    uint256 public newDifficultyGame;
    uint256 public newTicketPrice;
    uint256 public newTicketPriceGameNumber;
    bool public gameStopped;

    // Witnet randomness
    IWitnetRandomness public immutable witnet;
    mapping(uint256 => uint256) public gameRandomizingBlock;

    // Mappings
    mapping(uint256 => uint256) public gameStartBlock;
    mapping(uint256 => Difficulty) public gameDifficulty;
    mapping(uint256 => uint256) public gamePrizePool;
    mapping(uint256 => uint256[4]) public gameWinningNumbers;
    mapping(uint256 => uint256[3]) public gamePayouts;
    mapping(address => mapping(uint256 => uint256)) public playerTicketCount;
    mapping(uint256 => mapping(uint32 => uint256)) public ticketCounts;
    mapping(uint256 => mapping(uint32 => mapping(address => bool))) public ticketOwners;

    mapping(uint256 => bool) public gameDrawInitiated;
    mapping(uint256 => bytes32) public gameRandomSeed;
    mapping(uint256 => uint256) public gameRandomBlock;
    mapping(uint256 => bool) public gameDrawCompleted;
    mapping(uint256 => mapping(address => bool)) public prizesClaimed;
    mapping(uint256 => uint256) public gameDrawnBlock;
    mapping(uint256 => mapping(address => bool)) public hasClaimedNFT;

    mapping(uint256 => bool) public gameRefundsEnabled;
    mapping(uint256 => mapping(address => bool)) public hasRefunded;

    // Events
    event TicketPurchased(address indexed player, uint256 gameNumber, uint256[3] numbers, uint256 etherball);
    event TicketsPurchased(address indexed player, uint256 gameNumber, uint256 ticketCount);
    event DrawInitiated(uint256 gameNumber);
    event RandomSet(uint256 gameNumber, uint256 random);
    event WinningNumbersSet(uint256 indexed gameNumber, uint256 number1, uint256 number2, uint256 number3, uint256 etherball);
    event DifficultyChanged(uint256 gameNumber, Difficulty newDifficulty);
    event TicketPriceChangeScheduled(uint256 newPrice, uint256 effectiveGameNumber);
    event ExcessPrizePoolTransferred(uint256 fromGame, uint256 toGame, uint256 amount);
    event GamePrizePayoutInfo(uint256 gameNumber, uint256 goldPrize, uint256 silverPrize, uint256 bronzePrize);
    event FeeRecipientChanged(address newFeeRecipient);
    event PrizeClaimed(uint256 gameNumber, address player, uint256 amount);
    event NFTMinted(address indexed winner, uint256 indexed tokenId, uint256 indexed gameNumber);
    event GameStopped(uint256 gameNumber);
    event GameRefundsEnabled(uint256 gameNumber);
    event TicketsRefunded(address player, uint256 gameNumber, uint256 amount);

    /**
     * @dev Constructor to initialize the Lottery contract
     * @param _witnetRandomness Address of the WitnetRandomness contract
     * @param _nftPrizeAddress Address of the NFTPrize contract
     * @param _feeRecipient Address to receive fees
     * @param _paymentToken Address of the payment token
     */
    constructor(IWitnetRandomness _witnetRandomness, address _nftPrizeAddress, address _feeRecipient, address _paymentToken) Ownable(msg.sender) {
        require(address(_witnetRandomness) != address(0), "Invalid Witnet address");
        witnet = _witnetRandomness;
        nftPrize = NFTPrize(_nftPrizeAddress);
        ticketPrice = 1 * 1e18; // 1 token
        currentGameNumber = 1;
        gameDifficulty[currentGameNumber] = Difficulty.Easy;
        gameStartBlock[currentGameNumber] = block.number;
        lastDrawTime = block.timestamp;
        feeRecipient = _feeRecipient;
        paymentToken = IERC20(_paymentToken);
        permit2 = IPermit2(PERMIT2_ADDRESS);
    }

    /**
     * @dev Allows users to buy multiple lottery tickets using Permit2 (100 max)
     * @param tickets Array of ticket numbers (4 numbers per ticket)
     * @param permit The Permit2 permission structure
     * @param signature The signature for the Permit2 transfer
     */
    function buyTickets(uint256[4][] calldata tickets, IPermit2.PermitTransferFrom calldata permit, bytes calldata signature) external nonReentrant {
        require(!gameStopped, "Game is stopped");
        uint256 ticketCount = tickets.length;
        require(ticketCount > 0 && ticketCount <= 100, "Invalid ticket count");

        uint256 totalCost = ticketPrice * ticketCount;
        require(permit.permitted.amount >= totalCost, "Insufficient permit amount");

        // Execute the Permit2 transfer
        permit2.permitTransferFrom(
            permit,
            IPermit2.SignatureTransferDetails({
                to: address(this),
                requestedAmount: totalCost
            }),
            msg.sender,
            signature
        );

        uint256 gameNum = currentGameNumber;
        address player = msg.sender;

        unchecked {
            gamePrizePool[gameNum] += totalCost;
            playerTicketCount[player][gameNum] += ticketCount;
        }

        for (uint256 i = 0; i < ticketCount;) {
            _processSingleTicketPurchase(
                tickets[i],
                gameNum,
                player
            );
            unchecked { ++i; }
        }

        emit TicketsPurchased(player, gameNum, ticketCount);
    }

    /**
     * @dev Process a single ticket purchase
     * @param ticketData Array of ticket numbers (3 numbers + 1 etherball)
     * @param gameNum The game number to purchase the ticket for
     */
    function _processSingleTicketPurchase(
        uint256[4] calldata ticketData,
        uint256 gameNum,
        address player
    ) internal {
        (bool valid, uint32 packedNumbers) = _validateAndPackNumbers(ticketData);
        require(valid, "Invalid numbers");

        uint32 goldTicket = packedNumbers;                    // All numbers
        uint32 silverTicket = packedNumbers & 0xFFFFFF00;     // First 3 numbers
        uint32 bronzeTicket = packedNumbers & 0xFFFF0000;     // First 2 numbers

        _updateTicketState(
            goldTicket,
            silverTicket,
            bronzeTicket,
            gameNum,
            player
        );

        emit TicketPurchased(
            player,
            gameNum,
            [ticketData[0], ticketData[1], ticketData[2]],
            ticketData[3]
        );
    }

    /**
    * @dev Validate and pack numbers into uint32
    * @param numbers Array of 4 numbers (3 main numbers + 1 etherball)
    */
    function _validateAndPackNumbers(uint256[4] calldata numbers) internal view returns (bool, uint32) {
        Difficulty difficulty = gameDifficulty[currentGameNumber];
        (uint256 maxNumber, uint256 maxEtherball) = _getDifficultyParams(difficulty);

        for (uint256 i = 0; i < 3; i++) {
            if (numbers[i] < 1 || numbers[i] > maxNumber) {
                return (false, 0);
            }
        }
        
        if (numbers[3] < 1 || numbers[3] > maxEtherball) {
            return (false, 0);
        }

        uint32 packed = uint32(
            (numbers[0] << 24) |
            (numbers[1] << 16) |
            (numbers[2] << 8) |
            numbers[3]
        );

        return (true, packed);
    }

    /**
    * @dev Update ticket state for all ticket types
    * @param goldTicket The gold ticket number
    * @param silverTicket The silver ticket number
    * @param bronzeTicket The bronze ticket number
    * @param gameNum The game number
    * @param player The player address
    */
    function _updateTicketState(
        uint32 goldTicket,
        uint32 silverTicket,
        uint32 bronzeTicket,
        uint256 gameNum,
        address player
    ) internal {
        if (!ticketOwners[gameNum][goldTicket][player]) {
            ticketOwners[gameNum][goldTicket][player] = true;
            unchecked {
                ticketCounts[gameNum][goldTicket]++;
            }
        }

        if (!ticketOwners[gameNum][silverTicket][player]) {
            ticketOwners[gameNum][silverTicket][player] = true;
            unchecked {
                ticketCounts[gameNum][silverTicket]++;
            }
        }

        if (!ticketOwners[gameNum][bronzeTicket][player]) {
            ticketOwners[gameNum][bronzeTicket][player] = true;
            unchecked {
                ticketCounts[gameNum][bronzeTicket]++;
            }
        }
    }

    /**
     * @dev Initiates the lottery draw process
     */
    function initiateDraw() external payable nonReentrant {
        require(!gameDrawInitiated[currentGameNumber], "Draw already initiated for current game");
        require(block.timestamp >= lastDrawTime + DRAW_MIN_TIME_PERIOD, "Time interval not passed");

        lastDrawTime = block.timestamp;
        gameDrawInitiated[currentGameNumber] = true;

        // Request randomness from Witnet
        gameRandomizingBlock[currentGameNumber] = block.number;
        uint256 usedFunds = witnet.randomize{value: msg.value}();

        // Refund excess payment
        if (usedFunds < msg.value) {
            payable(msg.sender).transfer(msg.value - usedFunds);
        }

        _startNextGame();

        emit DrawInitiated(currentGameNumber - 1);
    }

    /**
     * @dev Starts the next game and updates game parameters
     */
    function _startNextGame() internal {
        Difficulty currentDifficulty = gameDifficulty[currentGameNumber];

        ++currentGameNumber;
        gameStartBlock[currentGameNumber] = block.number;

        if (newDifficulty != currentDifficulty && newDifficultyGame == currentGameNumber) {
            gameDifficulty[currentGameNumber] = newDifficulty;
        } else {
            gameDifficulty[currentGameNumber] = gameDifficulty[currentGameNumber - 1];
        }

        if (newTicketPrice != 0 && newTicketPriceGameNumber == currentGameNumber) {
            require(newTicketPrice > 0, "Invalid new ticket price");
            ticketPrice = newTicketPrice;
            newTicketPrice = 0;
        }
    }

    /**
     * @dev Sets the random value for a given game
     * @param gameNumber The game number to set the random value for
     */
    function setRandomAndWinningNumbers(uint256 gameNumber) external {
        require(gameDrawInitiated[gameNumber], "Draw not initiated for this game");
        require(gameRandomSeed[gameNumber] == 0, "Random has already been set");
        require(gameRandomizingBlock[gameNumber] > 0, "Randomization not requested");

        // Fetch randomness from Witnet
        bytes32 randomness = witnet.fetchRandomnessAfter(gameRandomizingBlock[gameNumber]);
        gameRandomSeed[gameNumber] = randomness;

        _setWinningNumbers(gameNumber, randomness);
    }

    /**
     * @dev Sets the winning numbers for a given game based on randomness
     * @param gameNumber The game number to set winning numbers for
     * @param randomness The randomness value from Witnet
     */
    function _setWinningNumbers(uint256 gameNumber, bytes32 randomness) internal {
        Difficulty difficulty = gameDifficulty[gameNumber];
        (uint256 maxNumber, uint256 maxEtherball) = _getDifficultyParams(difficulty);

        uint256[4] memory winningNumbers;

        for (uint256 i = 0; i < 4; i++) {
            uint256 maxValue = i < 3 ? maxNumber : maxEtherball;
            winningNumbers[i] = _generateUnbiasedRandomNumber(randomness, i, maxValue);
        }

        gameWinningNumbers[gameNumber] = winningNumbers;
        emit WinningNumbersSet(gameNumber, winningNumbers[0], winningNumbers[1], winningNumbers[2], winningNumbers[3]);
    }

    /**
     * @dev Generates an unbiased random number within a given range
     * @param seed The seed for randomness
     * @param nonce A nonce to ensure uniqueness
     * @param maxValue The maximum value (inclusive) of the random number
     * @return A random number between 1 and maxValue
     */
    function _generateUnbiasedRandomNumber(bytes32 seed, uint256 nonce, uint256 maxValue) internal pure returns (uint256) {
        uint256 maxAllowed = type(uint256).max - (type(uint256).max % maxValue);

        while (true) {
            uint256 randomNumber = uint256(keccak256(abi.encodePacked(seed, nonce)));
            if (randomNumber < maxAllowed) {
                return (randomNumber % maxValue) + 1;
            }
            nonce++;
        }

        revert("Failed to generate unbiased random number");
    }

    /**
     * @dev Calculates and sets the payouts for a given game
     * @param gameNumber The game number to calculate payouts for
     */
    function calculatePayouts(uint256 gameNumber) external nonReentrant {
        require(gameDrawCompleted[gameNumber] != true, "Payouts already calculated for this game");
        require(gameWinningNumbers[gameNumber][0] != 0, "Winning numbers not set");

        uint256 prizePool = gamePrizePool[gameNumber];
        require(prizePool > 0, "No prize pool exists for this game");

        (uint256 goldPrize, uint256 silverPrize, uint256 bronzePrize, uint256 fee) = _calculatePrizes(prizePool);

        fee = _handleExcessFee(fee);

        (uint256 goldWinnerCount, uint256 silverWinnerCount, uint256 bronzeWinnerCount) = _getWinnerCounts(gameNumber);

        (uint256 goldPrizePerWinner, uint256 silverPrizePerWinner, uint256 bronzePrizePerWinner) = _calculatePrizesPerWinner(goldPrize, silverPrize, bronzePrize, goldWinnerCount, silverWinnerCount, bronzeWinnerCount);

        _storeGameOutcomes(gameNumber, goldPrizePerWinner, silverPrizePerWinner, bronzePrizePerWinner, goldWinnerCount);

        _handleExcessPrizePool(prizePool, goldPrizePerWinner, silverPrizePerWinner, bronzePrizePerWinner, goldWinnerCount, silverWinnerCount, bronzeWinnerCount, fee, gameNumber);

        gameDrawCompleted[gameNumber] = true;
        emit GamePrizePayoutInfo(gameNumber, goldPrizePerWinner, silverPrizePerWinner, bronzePrizePerWinner);

        _sendFee(fee);
    }

    /**
     * @dev Calculates the prizes for gold, silver, bronze, and fee
     * @param prizePool The total prize pool
     * @return goldPrize The gold prize amount
     * @return silverPrize The silver prize amount
     * @return bronzePrize The bronze prize amount
     * @return fee The fee amount
     */
    function _calculatePrizes(uint256 prizePool) internal pure returns (uint256 goldPrize, uint256 silverPrize, uint256 bronzePrize, uint256 fee) {
        goldPrize = (prizePool * GOLD_PERCENTAGE) / BASIS_POINTS;
        silverPrize = (prizePool * SILVER_PLACE_PERCENTAGE) / BASIS_POINTS;
        bronzePrize = (prizePool * BRONZE_PLACE_PERCENTAGE) / BASIS_POINTS;
        fee = (prizePool * FEE_PERCENTAGE) / BASIS_POINTS;
    }

    /**
     * @dev Handles excess fee by transferring it to the current game's prize pool
     * @param fee The calculated fee
     * @return The adjusted fee amount
     */
    function _handleExcessFee(uint256 fee) internal returns (uint256) {
        if (fee > FEE_MAX_IN_TOKENS) {
            uint256 excessFee = fee - FEE_MAX_IN_TOKENS;
            fee = FEE_MAX_IN_TOKENS;
            gamePrizePool[currentGameNumber] += excessFee;
        }
        return fee;
    }

    /**
     * @dev Gets the count of winners for each prize tier
     * @param gameNumber The game number to get winner counts for
     * @return goldWinnerCount The number of gold winners
     * @return silverWinnerCount The number of silver winners
     * @return bronzeWinnerCount The number of bronze winners
     */
    function _getWinnerCounts(uint256 gameNumber) internal view returns (
        uint256 goldWinnerCount,
        uint256 silverWinnerCount,
        uint256 bronzeWinnerCount
    ) {
        uint256[4] memory winningNumbers = gameWinningNumbers[gameNumber];
        
        uint32 packedWinning = uint32(
            (winningNumbers[0] << 24) |
            (winningNumbers[1] << 16) |
            (winningNumbers[2] << 8) |
            winningNumbers[3]
        );
        
        goldWinnerCount = ticketCounts[gameNumber][packedWinning];
        silverWinnerCount = ticketCounts[gameNumber][packedWinning & 0xFFFFFF00];
        bronzeWinnerCount = ticketCounts[gameNumber][packedWinning & 0xFFFF0000];
    }


    /**
     * @dev Calculates the prize amount per winner for each tier
     * @param goldPrize Total gold prize
     * @param silverPrize Total silver prize
     * @param bronzePrize Total bronze prize
     * @param goldWinnerCount Number of gold winners
     * @param silverWinnerCount Number of silver winners
     * @param 
