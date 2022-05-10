
// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.9.0;

contract RockPonziScissors {  //RPS with escalating time-bound stakes for draws

    struct Player {
        address addr;
        bytes32 commit;  // hash value of move they want to play
        uint bet;  // amount of ether they want to bet
        bool updated;  //sidegame only: have they updated their bet
        int revealed_action;  // action in cleartest as integer   
        bool revealed;
        uint nonce;  // secret randomness
    }

    event PlayOut(address winner, uint pot);
    event Sidegame(uint locktime);

    Player player1 = Player(address(0), 0, 0, false, 999, false, 0);
    Player player2 = Player(address(0), 0, 0, false, 999, false, 0);

    // list of players
    Player[2] players;

    // players by address
    mapping(address => Player) players_by_addr;

    // win table
    mapping(int => int) win_table;

    // state vars
    bool sidegame;
    uint locktime;
    uint balance;
    address payable owner;

    constructor() payable {
    // what happens when contract is first deployed
    owner = payable(msg.sender);

    // rock = 0, paper = 1, scissors = 2; integer encoding

    // rock vs paper        0 - 1 = -1      loses
    // rock vs scissors     0 - 2 = -2      wins
    // paper vs rock        1 - 0 = 1       wins
    // paper vs scissors    1 - 2 = -1      loses
    // scissors vs rock     2 - 0 = 2       loses
    // scissors vs paper    2 - 1 = 1       wins
    // draws                x - x = 0       draw


    win_table[-2] = 1;
    win_table[-1] = -1;
    win_table[0] = 0;
    win_table[1] = 1;
    win_table[2] = -1;

    sidegame = false;
    }   
    
    function play(bytes32 commit) public payable {
        // SIDEGAME tree for recursion
        if (sidegame == true){
            //still in time?
            if (block.timestamp > locktime + 10 minutes){
                sidegame = false;
                delete player1; //safe? data just zeroed? Enough?
                delete player2;

                owner.transfer(address(this).balance);  // cause i'm a greedy bastard :-)

                // todo: refund first player if applicable 
                // and convert call into new game

                return;  // end function here

            } else {
                //update bets


                // lock players
                require(msg.sender == player1.addr || msg.sender == player2.addr);

                // bets must match pot
                require(msg.value >= balance);  // same for both players

                //update bets
                if (msg.sender == player1.addr){
                    player1.commit = commit;
                    player1.updated = true;
                    player1.bet = msg.value;
                    players_by_addr[player1.addr] = player1;
                } else {
                    player2.commit = commit;  //alright since we excluded arbitrary addresses with prior require
                    player2.updated = true;
                    player2.bet = msg.value;
                    players_by_addr[player2.addr] = player2;
                }

                // check if both player updated their bets, otherwise wait
                if (player1.updated == false || player2.updated == false) {
                    // event: "Both bets are in. Time to reveal."
                    return;
                } else {
                    sidegame = false;

                }
                // end sidegame and continue with function
                
            }
        } else {// only happens if not sidegame
        // REGULAR GAME
            // register player and bets
            // first player submits
            if (player1.addr == address(0)) {
                player1 = Player(msg.sender, commit, msg.value, false, 999, false, 0); 
                //update mapping for later convenience
                players_by_addr[player1.addr] = player1;
            // second player submits
            } else if (player1.addr != address(0) && player2.addr == address(0)) {
                require(msg.value >= player1.bet, 
                        "Bet must be matched or exceeded."); //bet2 must at least match bet1
                player2 = Player(msg.sender, commit, msg.value, false, 999, false, 0);        
                players_by_addr[player2.addr] = player2;
                locktime = block.timestamp;  // set timelock after second player submitted commit
            } else {
                revert(); // lock players into game so other players can't sneak in before
            }
        }
    }

    function reveal(int message, uint nonce) public { 
        //emit Hash(sha256(abi.encodePacked(message, nonce)));
        require(sha256(abi.encodePacked(message, nonce)) == players_by_addr[msg.sender].commit);  //recalculate hash; i.e. valid reveal

        // sligthly confusing use of the mapping; original player1/2 instances are NOT updated! Keep in mind!
        players_by_addr[msg.sender].revealed_action = message;
        players_by_addr[msg.sender].revealed = true;
        players_by_addr[msg.sender].nonce = nonce;

        // check time
        if (block.timestamp > locktime + 10 minutes) {
            return;  // do nothing or refund
            // check for refund
        
        } else {
            // just one player has revealed, wait; XOR values 
            if (players_by_addr[player1.addr].revealed != players_by_addr[player2.addr].revealed) {  // use mapping structs instead of orig player instances here
                return;
            } else {
                // compare and payout
                ////////////////////////

                uint pot;  // define here otherwise compiler error
                // random lottery to decide whether to play out pot
                // XOR hashed nonces (might differ in length), and use rightmost byte
                bytes32 rand_bytes = sha256(abi.encodePacked(players_by_addr[player1.addr].nonce, players_by_addr[player2.addr].nonce));
                uint rand_uint = uint(rand_bytes);        

                // PLAY GAME
                // reveal commits, compare, decide winner and payout winnings or continue with sidegame
                // probability that pot is played out
                if (address(this).balance > player1.bet + player2.bet &&
                    rand_uint <= 15792089237316195423570985008687907853269984665640564039457584007913129639935) {  // hardcode some probablity for play-out of pot. MAX_VALUE of uint256 / 10 ~= 10% chance of playing out pot; to probabilistically prevent frontrunning
                    pot = address(this).balance;
                } else {
                    pot = player1.bet + player2.bet;
                }
                
                int result = players_by_addr[player1.addr].revealed_action - players_by_addr[player2.addr].revealed_action;

                // Player1 wins
                if (win_table[result] == 1) {
                    address payable payout_addr = payable(player1.addr);
                    resetGame();
                    payout_addr.transfer(pot);
                    delete payout_addr;
                    emit PlayOut(payout_addr, pot);
                

                // Player2 wins
                } else if (win_table[result] == -1) {
                    address payable payout_addr = payable(player2.addr);
                    resetGame();
                    payout_addr.transfer(pot);
                    emit PlayOut(payout_addr, pot);
                
                // Draw and move to sidegame
                } else if (win_table[result] == 0) {
                    sidegame = true;
                    locktime = block.timestamp;
                    balance = address(this).balance;
                    emit Sidegame(locktime);

                    // clear player structs for next round
                    player1.commit = 0;  //0x000000 or something ???
                    player1.bet = 0;
                    players_by_addr[player1.addr].revealed = false;
                    players_by_addr[player1.addr].revealed_action = -1;

                    player2.commit = 0;  //0x000000 or something ???
                    player2.bet = 0;
                    players_by_addr[player2.addr].revealed = false;
                    players_by_addr[player2.addr].revealed_action = -1;
                    // play sidegame, i.e. lock players for locktime and wait for new play calls from them; requires new actions from players
                    // that is: no recursion since we need fresh inputs from players
                } else {
                    return;  //do nothing, i.e. not throw error. Wrongly specified actions equals donation to contract :-)
                }
            }
        }
    }


    function resetGame() internal {
        delete players_by_addr[player1.addr];
        delete players_by_addr[player2.addr];
        delete player1;
        delete player2;
        delete balance;
    }

    function getState() public view returns(Player memory, Player memory) {
        return (player1, player2);
    }

    function getContractBalance() public view returns (uint) {
        return address(this).balance;
    }

    //fallback
    fallback() external payable {}
}
