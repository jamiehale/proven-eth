pragma solidity ^0.4.18;

import "zeppelin-solidity/contracts/ownership/Ownable.sol";
import "./VerifierRegistry.sol";
import "./VerifierDb.sol";
import "./Proven.sol";
import "./BondHolder.sol";


contract Verifier is Ownable {

  VerifierRegistry public registry;
  uint public fee;
  uint public timeoutBlockCount;
  uint public requiredBondAmount;

  event DepositionPublished(bytes32 deposition, address deponent, bytes ipfsHash, uint bounty);
  event DepositionVerified(bytes32 deposition, address verifier);
  event DepositionProven(bytes32 deposition, address verifier);
  event DepositionChallenged(bytes32 deposition, address challenger);
  event DepositionDisproven(bytes32 deposition, address challenger);
  event DepositionContested(bytes32 deposition, address contestor);

  modifier onlyWithFee() {
    require(msg.value == fee);
    _;
  }

  function Verifier(address _registry, uint _fee, uint _timeoutBlockCount, uint _requiredBondAmount) public {
    registry = VerifierRegistry(_registry);
    fee = _fee;
    timeoutBlockCount = _timeoutBlockCount;
    requiredBondAmount = _requiredBondAmount;
  }

  function setRegistry(address _registry) public onlyOwner {
    registry = VerifierRegistry(_registry);
  }

  function setFee(uint _fee) public onlyOwner {
    fee = _fee;
  }

  function setTimeoutBlockCount(uint _timeoutBlockCount) public onlyOwner {
    timeoutBlockCount = _timeoutBlockCount;
  }

  function setRequiredBondAmount(uint _requiredBondAmount) public onlyOwner {
    requiredBondAmount = _requiredBondAmount;
  }

  function withdraw(uint _amount) public onlyOwner {
    require(_amount <= this.balance);

    assert(msg.sender.send(_amount));
  }

  // Called by the verifier when it is directly creating a new deposition,
  // instead of mining one that's already in the chain's logs
  // (like those created from Proven.publishDeposition). Requires a fee
  // which is paid as a bounty to the verifier.
  function publishDeposition(bytes _ipfsHash) public payable onlyWithFee returns (bytes32) {

    Proven proven = Proven(registry.proven());

    bytes32 id = proven.publishDeposition(msg.sender, _ipfsHash);

    VerifierDb db = VerifierDb(registry.db());

    db.initialize(id, _ipfsHash, msg.value);

    DepositionPublished(id, msg.sender, _ipfsHash, msg.value);

    return id;
  }

  // This is called to verify a published deposition that already exists.
  // If the IPFS hash is not provided the verification won't be retrievable
  // by a smart contract or by a user who wants to check its verification without
  // downloading the full blockchain and scanning the logs, etc. It's not a great
  // idea but it does save some gas.
  function verifyDeposition(bytes32 _deposition) public {

    verifyDeposition(_deposition, "");
  }

  // This is called to verify a published deposition that already exists, either
  // from publishDeposition() above or Proven.publishDeposition.
  function verifyDeposition(bytes32 _deposition, bytes _ipfsHash) public {

    BondHolder bondHolder = BondHolder(registry.bondHolder());

    require(bondHolder.isBonded(msg.sender));
    require((bondHolder.availableBond(msg.sender) - requiredBondAmount) >= 0);

    VerifierDb db = VerifierDb(registry.db());

    var (state,,,,,,,) = db.getDetails(_deposition);
    require(state == VerifierDb.State.Initialized);

    db.verify(_deposition, _ipfsHash, msg.sender, requiredBondAmount);

    bondHolder.lockBond(msg.sender, requiredBondAmount);

    DepositionVerified(_deposition, msg.sender);
  }

  function getDepositionFromIPFSHash(bytes _ipfsHash) public view returns (bytes32) {
    VerifierDb db = VerifierDb(registry.db());
    return db.getDepositionFromIPFSHash(_ipfsHash);
  }

  function claimVerificationReward(bytes32 _deposition) public {

    VerifierDb db = VerifierDb(registry.db());

    var (state, bounty, verifier, verifiedInBlock,,, bondAmount,) = db.getDetails(_deposition);
    require(state == VerifierDb.State.Verified);
    require(block.number >= verifiedInBlock + timeoutBlockCount);
    require(verifier == msg.sender);

    db.prove(_deposition);

    BondHolder bondHolder = BondHolder(registry.bondHolder());

    bondHolder.unlockBond(msg.sender, bondAmount);

    assert(msg.sender.send(bounty));

    DepositionProven(_deposition, msg.sender);
  }

  function challengeDeposition(bytes32 _deposition) public {

    BondHolder bondHolder = BondHolder(registry.bondHolder());

    require(bondHolder.isBonded(msg.sender));

    VerifierDb db = VerifierDb(registry.db());

    var (state,,,,,,,) = db.getDetails(_deposition);
    require(state == VerifierDb.State.Initialized);

    db.challenge(_deposition, msg.sender, requiredBondAmount);

    bondHolder.lockBond(msg.sender, requiredBondAmount);

    DepositionChallenged(_deposition, msg.sender);
  }

  function claimChallengeReward(bytes32 _deposition) public {

    VerifierDb db = VerifierDb(registry.db());

    var (state, bounty,,, challenger, challengedInBlock, bondAmount,) = db.getDetails(_deposition);
    require(state == VerifierDb.State.Challenged);
    require(block.number >= challengedInBlock + timeoutBlockCount);
    require(challenger == msg.sender);

    db.disprove(_deposition);
    
    BondHolder bondHolder = BondHolder(registry.bondHolder());

    bondHolder.unlockBond(msg.sender, bondAmount);

    assert(msg.sender.send(bounty));

    DepositionDisproven(_deposition, msg.sender);
  }

  function contestVerification(bytes32 _deposition) public {

    VerifierDb db = VerifierDb(registry.db());

    var (state,,,,,, bondAmount,) = db.getDetails(_deposition);
    require(state == VerifierDb.State.Verified);

    BondHolder bondHolder = BondHolder(registry.bondHolder());

    // does the caller have enough bond on deposit?
    require(bondHolder.availableBond(msg.sender) >= bondAmount);

    contest(db, bondHolder, bondAmount, _deposition, msg.sender);
  }

  function contestChallenge(bytes32 _deposition) public {

    VerifierDb db = VerifierDb(registry.db());

    var (state,,,,,, bondAmount,) = db.getDetails(_deposition);
    require(state == VerifierDb.State.Challenged);

    BondHolder bondHolder = BondHolder(registry.bondHolder());

    // does the caller have enough bond on deposit?
    require(bondHolder.availableBond(msg.sender) >= bondAmount);

    contest(db, bondHolder, bondAmount, _deposition, msg.sender);
  }

  function decideChallenge(bytes32 _deposition, bool _proven) public {

    address oracle = registry.oracle();
    require(msg.sender == oracle);

    VerifierDb db = VerifierDb(registry.db());
    var (state,, verifier,,,, bondAmount, contestor) = db.getDetails(_deposition);
    require(state == VerifierDb.State.Contested);

    if (_proven) {
      db.prove(_deposition);
      distributeContestReward(verifier, bondAmount, contestor, oracle);
      DepositionProven(_deposition, verifier);
    } else {
      db.disprove(_deposition);
      distributeContestReward(contestor, bondAmount, verifier, oracle);
      DepositionDisproven(_deposition, contestor);
    }
  }

  function contest(VerifierDb _db, BondHolder _bondHolder, uint bondAmount, bytes32 _deposition, address _contestor) internal {

    _db.contest(_deposition, _contestor);

    _bondHolder.lockBond(_contestor, bondAmount);

    DepositionContested(_deposition, _contestor);
  }

  function distributeContestReward(address _winner, uint _bondAmount, address _loser, address _oracle) internal {

    BondHolder bondHolder = BondHolder(registry.bondHolder());

    bondHolder.distributeBond(_loser, _bondAmount, _winner, _oracle);
  }
}
