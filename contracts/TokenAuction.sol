pragma solidity ^0.4.23;

import "./HypeToken.sol";

contract TokenAuction is HypeToken {
  
  struct Auction {
    address seller;
    address artist;
    address promoter;
    address topBidder;
    uint256 startPrice;
    uint256 endPrice;
    uint64 auctionStart;
    uint64 auctionClose;
    uint8 royaltyPercentage;
  }

  // Open Auctions
  mapping (uint256 => Auction) public tokenIdToAuction;

  // Completed auctions
  Auction[] public completedAuctions;
  
  // Auction value storage
  mapping (uint256 => uint256) internal auctionStore;
  
  // Address value storage
  mapping (address => uint256) internal pendingWithdraw;
  
  // Promo code storage
  mapping (bytes32 => address) public promoCodeToPromoter;
  mapping (address => bytes32) public promoterToPromoCode;

  event AuctionCreated(uint256 tokenId, address artist, uint256 startPrice, uint64 auctionStart, uint64 auctionClose);
  event AuctionBidIncreased(uint256 tokenId, address artist, address bidder, address promoter, uint256 startPrice, uint256 endPrice);
  event AuctionSuccessful(uint256 tokenId, address artist, uint256 endPrice, address winner, address promoter);
  event AuctionCancelled(uint256 tokenId);

  // escrow the NFT assigns ownership to contract
  function _escrow(address _owner, uint256 _tokenId) internal {
    // clear approvals
    clearApproval(_owner, _tokenId);
    
    // remove token from   
    super.removeTokenFrom(_owner, _tokenId);
    
    // transfer ownership
    super.addTokenTo(this, _tokenId);
    tokenOwner[_tokenId] = this;
    
    emit Transfer(_owner, this, _tokenId);
  }

  // transfer NFT owned by contract to another address
  function _transfer(address _receiver, uint256 _tokenId) internal {
    // clear approvals
    clearApproval(this, _tokenId);
    
    // remove token from   
    super.removeTokenFrom(this, _tokenId);
    
    // transfer ownership
    addTokenTo(_receiver, _tokenId);
    tokenOwner[_tokenId] = _receiver;
    
    emit Transfer(this, _receiver, _tokenId);
  }

  // check if the auction is on
  function _isOnAuction(Auction storage _auction) internal view returns (bool) {
    return (_auction.auctionStart > 0);
  }

  // creates an Auction
  function createAuction(uint256 _tokenId, 
                         uint256 _startPrice,
                         uint64 _duration) public onlyOwnerOf(_tokenId) {
    // require non-zero start price
    require(_startPrice >= 100);
    // transfer token to this contract
    _escrow(msg.sender, _tokenId);
    
    // get values from inherited contract ArtistToken
    address _artist = getArtistAddress(_tokenId);
    uint8 _royaltyPercentage = getRoyaltyPercentage(_tokenId);
    
    uint64 _auctionStart = uint64(now);
    uint64 _auctionEnd = _auctionStart + _duration;

    // set msg.sender as topBidder initially. 
    // Incase no one bids, token is returned to creator of auction
    // set msg.sender as promoter initially. So if no one promotes
    // creator of auction will get full cut
    Auction memory _auction = Auction(
      msg.sender,
      _artist,
      msg.sender, // msg.sender is promoter initially
      msg.sender, // msg.sender is topBidder initally. Token will return back to auction crao
      _startPrice,
      _startPrice,
      _auctionStart,
      _auctionEnd,
      _royaltyPercentage
    );

    // create mapping
    tokenIdToAuction[_tokenId] = _auction;

    // broadcast event
    emit AuctionCreated(
      uint256(_tokenId),
      address(_auction.artist),
      uint256(_auction.startPrice),
      uint64(_auction.auctionStart),
      uint64(_auction.auctionClose)
    );
  }

  function cancelAuction(uint256 _tokenId) public {
    Auction storage auction = tokenIdToAuction[_tokenId];
    require(msg.sender == auction.seller);
    require(_isOnAuction(auction));
    require(auction.auctionClose >= now);
    
    // return token back to seller
    _transfer(auction.seller, _tokenId);
    
    // return funds back to top bidder
    pendingWithdraw[auction.topBidder] += auctionStore[_tokenId];
    
    // delete mappings
    delete auctionStore[_tokenId];
    delete tokenIdToAuction[_tokenId];
    emit AuctionCancelled(_tokenId);
  }
  
  /**
   * @dev Register as a promoter
   * @dev use a mapping instead of filling address directly during bid
   *      to prevent people from losing eth
   * @dev This can potentially be a payable function *to discuss*
   */
  function becomePromoter() public returns(bytes32) {
    // hash sender's eth address
    bytes32 _promoCode = keccak256(abi.encodePacked(msg.sender));
    promoCodeToPromoter[_promoCode] = msg.sender;
    promoterToPromoCode[msg.sender] = _promoCode;
    
    return _promoCode;
  }

  function bid(uint256 _tokenId, bytes32 _promoCode) public payable {
    Auction storage auction = tokenIdToAuction[_tokenId];
    require(_isOnAuction(auction));
    require(now <= auction.auctionClose);
    require(msg.value > auction.endPrice);

    // return money to previous top bidder
    pendingWithdraw[auction.topBidder] += auctionStore[_tokenId];
    
    // update auctionStore
    auctionStore[_tokenId] = msg.value;
    
    // get promoter addr via hash
    address _promoter = promoCodeToPromoter[_promoCode];
    // if no valid promo code is used _promoter goes back to auction.seller 
    if(_promoter == address(0)){
        _promoter = auction.seller;
    }
    
    // update mapping
    Auction memory _auction = Auction(
      auction.seller,
      auction.artist,
      _promoter,
      msg.sender,
      auction.startPrice,
      msg.value,
      auction.auctionStart,
      auction.auctionClose,
      auction.royaltyPercentage
    );

    tokenIdToAuction[_tokenId] = _auction;

    emit AuctionBidIncreased(_tokenId, 
                             auction.artist, 
                             msg.sender,
                             _promoter,
                             auction.startPrice, 
                             msg.value);
  }

  function closeAuction(uint256 _tokenId) public {
    Auction storage auction = tokenIdToAuction[_tokenId];
    require(now > auction.auctionClose);
    require(_isOnAuction(auction));
    
    // add to completedAuctions
    completedAuctions.push(auction);
    
    // transfer token
    _transfer(auction.topBidder, _tokenId);
    
    // calculate payout
    uint256 amount = auctionStore[_tokenId];
    uint256 artistCut =  amount * auction.royaltyPercentage/100;
    uint256 promoterCut = amount * auction.royaltyPercentage/100;
    uint256 sellerProceeds = amount - artistCut - promoterCut;

    // transfer as accordingly
    pendingWithdraw[auction.artist] += artistCut ;
    pendingWithdraw[auction.promoter] += promoterCut;
    pendingWithdraw[auction.seller] += sellerProceeds;

    // delete auction
    delete tokenIdToAuction[_tokenId];

    // delete auctionStore mapping
    delete auctionStore[_tokenId];

    // announce event
    emit AuctionSuccessful(_tokenId, 
                            auction.artist, 
                            auction.endPrice, 
                            auction.topBidder,
                            auction.promoter);
  }
  
  function getWithdraw(address _to) public view returns (uint256) {
    uint256 amount = pendingWithdraw[_to];
    return amount;
  }
  
  function withdraw() public {
      uint256 amount = pendingWithdraw[msg.sender];
      pendingWithdraw[msg.sender] = 0;
      msg.sender.transfer(amount);
  }
  
  function getOpenAuction(uint256 _tokenId)
    public
    view
    returns
  (
    address,
    address,
    address,
    address,
    uint256,
    uint256,
    uint64,
    uint64,
    uint8
  ) {
    Auction storage auction = tokenIdToAuction[_tokenId];
    require(_isOnAuction(auction));
    return (
        auction.seller,
        auction.artist,
        auction.promoter,
        auction.topBidder,
        auction.startPrice,
        auction.endPrice,
        auction.auctionStart,
        auction.auctionClose,
        auction.royaltyPercentage
    );
  }
  
  /**
   * @dev get details of completed aucion
   * @param _completedAuctionIndex refers to the n th number of
   *    auction completed
   *
   */
  function getCompletedAuction(uint256 _completedAuctionIndex)
    public
    view
    returns
  (
    address,
    address,
    address,
    address,
    uint256,
    uint256,
    uint64,
    uint64,
    uint8
  ) {
    Auction storage auction = completedAuctions[_completedAuctionIndex];
    return (
        auction.seller,
        auction.artist,
        auction.promoter,
        auction.topBidder,
        auction.startPrice,
        auction.endPrice,
        auction.auctionStart,
        auction.auctionClose,
        auction.royaltyPercentage
    );
  }
}
