// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

abstract contract getTx {
  struct tpCall {
    string func;
    uint256[] args;
  }
  struct tpSig {
    bytes raw;
    uint256 timestamp;
    bytes pubkey;
    bytes rawkey;
    bytes signature;
  }
  struct tpPayload {
    uint256 purpose;
    string cur;
    uint256 amount;
  }

  struct tpTx {
    uint256 kind;
    address from;
    address to;
    uint256 t;
    uint256 seq;
    tpCall[] call;
    tpPayload[] payload;
    tpSig[] signatures;
  }
  function get() virtual public returns (tpTx memory);
}

contract BronKerbosch {
  struct node_info {
    uint256 node_id;
    uint256[] nodes;
  }
  struct node_info2 {
    uint256 src_node;
    uint256 dst_node;
  }
  function max_clique(node_info[] calldata) public pure virtual returns (uint256[] memory) {}
  function max_clique_list(uint256[2][] calldata) public pure virtual returns (uint256[] memory) {}
}

contract ChainFee {
  ChainState cs;
  uint256 pre_age_balance;
  uint256 age;
  bool epoch_payed;

  constructor(address _cs) {
    cs=ChainState(_cs);
  }

  receive() external payable {}

  function new_epoch(uint256 _age) public returns (uint256 ret) {
    //require(msg.sender==address(cs),"Only ChainState can call this");
    require(_age>age,"epoch must be really new");
    pre_age_balance=address(this).balance;
    ret=age;
    age=_age;
    epoch_payed=false;
  }
  event CantSend(address,uint256);
  event Payed(address,uint256);
  event Burned(uint256);
  event TryPayout(uint256,uint256,uint256);
  event NotBurned(bytes);
  function payout(address[] calldata _payto, uint256 _toburn) public returns (uint256 payed,
                                                                              uint256 burned) {
    //require(msg.sender==address(cs),"Only ChainState can call this");
    require(epoch_payed==false,"Epoch already payed");
    uint256 parts=_payto.length+_toburn;
    uint256 part=pre_age_balance/parts;
    emit TryPayout(pre_age_balance,parts,_toburn);

    // Call returns a boolean value indicating success or failure.
    // This is the current recommended method to use.
    for(uint256 i=0;i<_payto.length;i++){
      (bool sent, ) = _payto[i].call{value: part}("");
      if (!sent) {
        emit CantSend(_payto[i],part);
        _toburn+=1;
      }else{
        payed+=part;
        emit Payed(_payto[i],part);
      }
    }
    if(_toburn>0){
      uint256 burnsum=part*_toburn;
      address bad=address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
      (bool ok, bytes memory data) = bad.call{value: burnsum}("");
      burned=burnsum;
      if(ok)
        emit Burned(burnsum);
      else
        emit NotBurned(data);
    }
    epoch_payed=true;

  }

}

contract ChainState {
  struct blockSig {
    bytes node_id;
    bytes signature;
    bytes extradata;
    uint256 timestamp;
  }
  struct hashSig {
    uint256 from;
    uint256 to;
    uint256 timestamp;
  }

  uint256 public next_block_on;
  uint256 public next_report_blk;
  uint256 public epoch;
  uint256 public epoch_start_blk;
  uint256 public epoch_last_start_blk;
  uint256 public epoch_end_blk;
  uint256 public epoch_end_time;
  bool    public epoch_payed;
  bool    public self_registration;

  mapping ( bytes pubkey => uint256 ) public node_ids;
  mapping ( uint256 id => bytes ) public node_keys;
  uint256 nodes;

  bytes32[] public active_nodes;
  bytes32[] public inactive_nodes;
  bytes32[] public seed_nodes;
  
  mapping ( uint256 height => uint256 ) public block_timestamp;
  mapping ( uint256 node_id => uint256 ) public last_height;
  mapping ( uint256 node_id => mapping (uint256 => uint256) ) public attrib;
  mapping ( uint256 height => hashSig[] ) public signatures;
  mapping ( uint256 height => uint256 ) public block_clique;

  uint256 public calc_till;

  uint256 public constant MAX_BLOCK_TIME = 3600; //1 hour - maximum block interval
  uint256 public constant MAX_EPOCH_TIME = 3600*2; //2 hours - maximum epoch duration
  uint256 public constant EPOCH_BLOCKS = 100;
  uint256 public constant REPORT_BLOCKS = 10;
  uint256 public constant CALC_DELAY = REPORT_BLOCKS+2; //give 2 blocks extra time
  uint256 public constant STORE_CLIQUE_BLOCKS = 500;

  ChainFee public chainfee;

  event NewEpoch (uint256,uint256,uint256,uint256);
  event Blk (uint256 indexed,uint256 indexed);

  constructor(bool _selfreg) {
    self_registration=_selfreg;
  }
  function set_chainfee(address payable _new) public {
    chainfee=ChainFee(_new);
  }

  function allow_self_registration(bool allow) public {
    self_registration=allow;
  }
  function newEpoch() public {
    epoch+=1;
    epoch_last_start_blk=epoch_start_blk;
    epoch_start_blk = block.number+1;
    epoch_end_blk = epoch_start_blk+EPOCH_BLOCKS;
    uint256 timestamp = (block.timestamp / 1000);
    epoch_end_time = timestamp+MAX_EPOCH_TIME;
    epoch_payed=false;
    emit NewEpoch(epoch_start_blk, epoch_end_blk, timestamp, epoch_end_time);
    if (address(chainfee) != address(0)){
      chainfee.new_epoch(epoch);
    }
  }

  function info() public view returns (uint256 current_epoch, uint256 start_blk, uint256 end_blk,
                                       uint256 end_time,uint256 block_number){
    current_epoch=epoch;
    start_blk=epoch_start_blk;
    end_blk=epoch_end_blk;
    end_time=epoch_end_time;
    block_number=block.number;
  }

  event Sigs(uint256, bytes32, uint256, int256);
  event AB(uint256);
  event Calc(uint256, uint256);

  function afterBlock() public returns (uint256) {

    next_block_on=(block.timestamp / 1000)+MAX_BLOCK_TIME;
    if(next_report_blk<=block.number){
      next_report_blk=block.number+REPORT_BLOCKS;
    }

    {
      uint256 blk=block.number-CALC_DELAY;
      uint256 mask=calc_block(blk);
      emit Calc(blk,mask);
      block_clique[blk]=mask;
      clean_block(blk);
      calc_till=block.number-CALC_DELAY;
      if(blk>STORE_CLIQUE_BLOCKS){ //cleanup after X blocks
        block_clique[blk-STORE_CLIQUE_BLOCKS]=0;
      }
    }
    if(calc_till>=epoch_start_blk && !epoch_payed){
      return _payout();
    }
    if(block.number>=epoch_end_blk){
      newEpoch();
      return 2;
    }
    return 0;
  }

  function clean_block(uint256 number) public returns(uint256) {
    uint sl=signatures[number].length;
    for(uint i=0;i<sl;i++){
      signatures[number].pop();
    }
    return sl;
  }
  function calc_block(uint256 number) public view returns(uint256) {
    uint sl=signatures[number].length;
    uint256[2][] memory n=new uint256[2][](sl);
    for(uint i=0;i<sl;i++){
      n[i][0]=signatures[number][i].from;
      n[i][1]=signatures[number][i].to;
    }
    uint256[] memory res=BronKerbosch(address(0xAFFFFFFFFF000007)).max_clique_list(n);
    uint256 mask=0;
    for(uint i=0;i<res.length;i++){
      mask+=(1<<res[i]);
    }
    return mask;
  }

  event Payout(uint256 blk0, uint256 blk1, uint256 and_mask, uint256 or_mask);
  event PayoutRes(uint256 payed, uint256 burned);
  function _payout() public returns (uint256) {
    uint blkn;
    uint cc_or=0;
    uint cc_and=0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    for(blkn=epoch_last_start_blk;blkn<epoch_start_blk;blkn++){
        emit Blk(blkn,block_clique[blkn]);
        cc_or|=block_clique[blkn];
        cc_and&=block_clique[blkn];
    }
    emit Payout(epoch_last_start_blk,epoch_start_blk-1,cc_or,cc_and);
    if (address(chainfee) != address(0)){
      //function payout(address[] calldata _payto, uint256 _toburn) public returns (uint256 payed,
      address[] memory a=new address[](0);
      (uint256 payed, uint256 burned) = chainfee.payout(a,3);
      emit PayoutRes(payed,burned);
    }
    epoch_payed=true;
    return 1;
  }
  event Debug(uint256 indexed,uint256 indexed);
  /*
  function median(uint256[] memory data) public returns (uint256) {
    emit Debug(data.length,0);
    for(uint i = 0;i < data.length-1;i++) {
      emit Debug(i,data.length);
      uint w_min = i;
      for(uint j = i;j < data.length-1;j++) {
        if(data[j] < data[w_min]) {
          w_min = j;
        }
      }
      if(w_min == i) continue;
      uint256 tmp = data[i];
      data[i] = data[w_min];
      data[w_min] = tmp;
    }
    if(data.length % 2 == 1){
      return data[data.length / 2];
    }else{
      return (data[(data.length / 2)-1]+data[data.length / 2])/2;
    }
  }
  */
  event Debug(bytes,uint256);
  function set_attrib(uint256[2][] calldata attribs) public returns(uint256) {
    bytes memory nodekey = getTx(address(0xAFFFFFFFFF000002)).get().signatures[0].pubkey;
    bytes memory shortkey=_slice(nodekey,nodekey.length-32,32);
    uint256 nodeid=node_ids[shortkey];
    _set_attr(nodeid, attribs);
    return 1;
  }

  function _set_attr(uint256 nodeid, uint256[2][] calldata attribs) internal {
    require(nodeid>0,"unknown node");
    for(uint256 i=0;i<attribs.length;i++){
      attrib[nodeid][attribs[i][0]]=attribs[i][1];
    }
  }

  function register() public returns (uint256) {
    bytes memory nodekey = getTx(address(0xAFFFFFFFFF000002)).get().signatures[0].pubkey;
    bytes memory shortkey=_slice(nodekey,nodekey.length-32,32);
    return _register(shortkey);
  }

  event RegisterNode(uint256,bytes);
  function _register(bytes memory shortkey) internal returns (uint256) {
    if(node_ids[shortkey]==0){
      require(nodes<254,"maximum number of nodes reached");
      node_ids[shortkey]=nodes;
      node_keys[nodes]=shortkey;
      emit RegisterNode(nodes,shortkey);
      nodes++;
    }
    return node_ids[shortkey];
  }

  function register(bytes calldata nodekey) public returns (uint256) {
    uint256 slice=nodekey.length-32;
    return _register(nodekey[slice:]);
  }

  function node_id(bytes calldata nodekey) public view returns (uint256) {
    uint256 slice=nodekey.length-32;
    return node_ids[nodekey[slice:]];
  }
  
  struct hSig {
    bytes pubkey;
    uint256 created;
    uint256 seen;
  }
  struct hUpd {
    bytes32 hash;
    uint256 height;
    uint256 mean_time;
    uint256 install_time;
    hSig[] sigs;
  }
  function updateData(hUpd[] calldata data) public returns (bool[] memory res) {
    bytes memory nodekey = getTx(address(0xAFFFFFFFFF000002)).get().signatures[0].rawkey;
    uint256 nodeid=node_ids[nodekey];
    require(nodeid>0,"unknown node");
    res=new bool[](data.length);
    for(uint i=0;i<data.length;i++){
      res[i]=_updateData(nodeid, data[i]);
    }
  }
  function updateData(hUpd[] calldata data, uint256[2][] calldata attribs) public returns (bool[] memory res) {
    bytes memory nodekey = getTx(address(0xAFFFFFFFFF000002)).get().signatures[0].rawkey;
    uint256 nodeid=node_ids[nodekey];
    require(nodeid>0,"unknown node");
    res=new bool[](data.length);
    for(uint i=0;i<data.length;i++){
      res[i]=_updateData(nodeid, data[i]);
    }
    _set_attr(nodeid, attribs);
  }
  function node_height(bytes calldata pubkey) public view returns (uint256) {
    uint256 from=node_ids[pubkey];
    return last_height[from];
  }

  function _updateData(uint256 from, hUpd calldata data) public returns (bool) {
    if(data.height<=calc_till) return false;
    if(block.number > epoch_start_blk+1)
      if(data.height<epoch_start_blk) return false;
    else
      if(data.height<epoch_last_start_blk) return false;
    uint i=0;
    for(i=0;i<data.sigs.length;i++){
      hashSig memory hs;
      hs.from = from;
      hs.to = node_ids[data.sigs[i].pubkey];
      hs.timestamp = data.sigs[i].seen;
      signatures[data.height].push(hs);
    }
    last_height[from]=data.height;
    return true;
  }


  function _slice(
        bytes memory _bytes,
        uint256 _start,
        uint256 _length
    )
        internal
        pure
        returns (bytes memory)
        {
          require(_length + 31 >= _length, "slice_overflow");
          require(_bytes.length >= _start + _length, "slice_outOfBounds");

          bytes memory tempBytes;

          assembly {
            switch iszero(_length)
            case 0 {
              // Get a location of some free memory and store it in tempBytes as
              // Solidity does for memory variables.
              tempBytes := mload(0x40)

              // The first word of the slice result is potentially a partial
              // word read from the original array. To read it, we calculate
              // the length of that partial word and start copying that many
              // bytes into the array. The first word we copy will start with
              // data we don't care about, but the last `lengthmod` bytes will
              // land at the beginning of the contents of the new array. When
              // we're done copying, we overwrite the full first word with
              // the actual length of the slice.
              let lengthmod := and(_length, 31)

              // The multiplication in the next line is necessary
              // because when slicing multiples of 32 bytes (lengthmod == 0)
              // the following copy loop was copying the origin's length
              // and then ending prematurely not copying everything it should.
              let mc := add(add(tempBytes, lengthmod), mul(0x20, iszero(lengthmod)))
              let end := add(mc, _length)

              for {
                // The multiplication in the next line has the same exact purpose
                // as the one above.
                let cc := add(add(add(_bytes, lengthmod), mul(0x20, iszero(lengthmod))), _start)
              } lt(mc, end) {
                mc := add(mc, 0x20)
                cc := add(cc, 0x20)
              } {
                mstore(mc, mload(cc))
              }

              mstore(tempBytes, _length)

              //update free-memory pointer
              //allocating the array padded to 32 bytes like the compiler does now
              mstore(0x40, and(add(mc, 31), not(31)))
            }
            //if we want a zero-length slice let's just return a zero-length array
            default {
              tempBytes := mload(0x40)
              //zero out the 32 bytes slice we are about to return
              //we need to do it because Solidity does not garbage collect
              mstore(tempBytes, 0)

              mstore(0x40, add(tempBytes, 0x20))
            }
          }

          return tempBytes;
        }
}

contract BronKerbosch_sol {
  // Graph is represented as an adjacency list where the key is the node and the value is the list of neighbors.
  mapping(uint256 => mapping(uint256 => bool)) public adjMatrix;
  uint256 public numVertices;

  event CliqueFound(uint256[] clique);

  /**
   * @dev Entry function to start the Bron-Kerbosch algorithm without pivoting.
   * Emits a CliqueFound event for each maximal clique found.
   */
  function findMaximalCliques() public {
    uint256[] memory R = new uint256[](numVertices);
    uint256[] memory P = new uint256[](numVertices);
    uint256[] memory X = new uint256[](numVertices);
    for (uint256 i = 0; i < numVertices; i++) {
      P[i] = i;
    }
    _bronKerbosch(R, P, X);
  }

  /**
   * @dev Private function to execute the recursive Bron-Kerbosch algorithm.
   * @param R A currently growing clique.
   * @param P Nodes that can be added to R to create a larger clique.
   * @param X Nodes that should be skipped (already processed in other cliques).
   */
  function _bronKerbosch(uint256[] memory R, uint256[] memory P, uint256[] memory X) private {
    if (_isEmpty(P) && _isEmpty(X)) {
      emit CliqueFound(_compact(R));
      return;
    }

    uint256[] memory P_copy = _copyArray(P);
    for (uint256 i = 0; i < P_copy.length; i++) {
      if (P_copy[i] == numVertices) continue;

      uint256 v = P_copy[i];
      R = _addToSet(R, v);
      _bronKerbosch(
        R,
        _intersect(P, _neighbors(v)),
        _intersect(X, _neighbors(v))
      );
      R = _removeFromSet(R, v);
      P = _removeFromSet(P, v);
      X = _addToSet(X, v);
    }
  }

     /**
     * @dev Checks if a set is empty.
     * @param set The set to check.
     * @return True if the set is empty, false otherwise.
     */
    function _isEmpty(uint256[] memory set) internal pure returns (bool) {
        for (uint256 i = 0; i < set.length; i++) {
            if (set[i] != type(uint256).max) {
                return false;
            }
        }
        return true;
    }

    /**
     * @dev Adds an element to a set.
     * @param set The set.
     * @param element The element to add.
     * @return The updated set.
     */
    function _addToSet(uint256[] memory set, uint256 element) internal pure returns (uint256[] memory) {
        for (uint256 i = 0; i < set.length; i++) {
            if (set[i] == type(uint256).max) {
                set[i] = element;
                break;
            }
        }
        return set;
    }

    /**
     * @dev Removes an element from a set.
     * @param set The set.
     * @param element The element to remove.
     * @return The updated set.
     */
    function _removeFromSet(uint256[] memory set, uint256 element) internal pure returns (uint256[] memory) {
        for (uint256 i = 0; i < set.length; i++) {
            if (set[i] == element) {
                set[i] = type(uint256).max;
                break;
            }
        }
        return set;
    }

  /**
     * @dev Intersects two sets.
     * @param setA The first set.
     * @param setB The second set.
     * @return The intersection of the two sets.
     */
    function _intersect(uint256[] memory setA, uint256[] memory setB) internal pure returns (uint256[] memory) {
        uint256[] memory result = new uint256[](setA.length);
        for (uint256 i = 0; i < setA.length; i++) {
            result[i] = type(uint256).max;
            for (uint256 j = 0; j < setB.length; j++) {
                if (setA[i] == setB[j]) {
                    result[i] = setA[i];
                    break;
                }
            }
        }
        return result;
    }

    /**
     * @dev Finds the neighbors of a vertex.
     * @param v The vertex.
     * @return The neighbors of the vertex.
     */
    function _neighbors(uint256 v) internal view returns (uint256[] memory) {
        uint256[] memory neighbors = new uint256[](numVertices);
        for (uint256 i = 0; i < numVertices; i++) {
            neighbors[i] = type(uint256).max;
            if (adjMatrix[v][i]) {
                neighbors[i] = i;
            }
        }
        return neighbors;
    }

    /**
     * @dev Compacts a set by removing the default max values.
     * @param set The set to compact.
     * @return The compacted set.
     */
    function _compact(uint256[] memory set) internal pure returns (uint256[] memory) {
        uint256 count;
        for (uint256 i = 0; i < set.length; i++) {
            if (set[i] != type(uint256).max) {
                count++;
            }
        }
        uint256[] memory compacted = new uint256[](count);
        count = 0;
        for (uint256 i = 0; i < set.length; i++) {
            if (set[i] != type(uint256).max) {
                compacted[count] = set[i];
                count++;
            }
        }
        return compacted;
    }

    /**
     * @dev Copies an array.
     * @param array The array to copy.
     * @return The copied array.
     */
    function _copyArray(uint256[] memory array) internal pure returns (uint256[] memory) {
        uint256[] memory copy = new uint256[](array.length);
        for (uint256 i = 0; i < array.length; i++) {
            copy[i] = array[i];
        }
        return copy;
    }
}
  
